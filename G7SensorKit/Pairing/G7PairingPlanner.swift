//
//  G7PairingPlanner.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit):
//  candidate planning follows its G7PairingPlanner.
//

import Foundation

/// Why a sensor was ruled out for the rest of the run.
public enum G7PairingRuleOutReason: Equatable {
    /// It answered our challenge with something our key did not produce.
    ///
    /// On its own that is not proof the code is wrong — a sensor whose slot
    /// another display holds answers identically — so this is only reached
    /// once the advertisement has ruled that out. See `settledReason`.
    case wrongPairingCode
    /// Its one display slot belongs to another phone or app.
    case inUseElsewhere
    /// It finished the key exchange and refused the session anyway, for a
    /// reason of its own.
    case refused
    /// It never got far enough to answer: every attempt ended in a dropped
    /// link or a timeout.
    case unreachable

    public var localizedDescription: String {
        switch self {
        case .wrongPairingCode:
            return LocalizedString("Not this sensor's code", comment: "Reason a G7 sensor was ruled out during pairing: its challenge response did not match the entered code")
        case .inUseElsewhere:
            return LocalizedString("In use by another phone", comment: "Reason a G7 sensor was ruled out during pairing: another display holds its slot")
        case .refused:
            return LocalizedString("Refused the connection", comment: "Reason a G7 sensor was ruled out during pairing: it rejected the session")
        case .unreachable:
            return LocalizedString("Did not respond", comment: "Reason a G7 sensor was ruled out during pairing: it never completed a handshake")
        }
    }
}

/// How far a discovered sensor has got in the run.
public enum G7PairingCandidateStatus: Equatable {
    /// Found, waiting its turn.
    case waiting
    /// Being connected to, or being waited on to become ready.
    case connecting
    /// Under handshake; `attempt` is 1-based.
    case pairing(attempt: Int)
    /// Out of the running, for good: a ruled-out sensor is never tried again
    /// in this run, not even if it advertises anew.
    case ruledOut(G7PairingRuleOutReason)
    case paired

    /// Whether this is the sensor the run is working on right now.
    public var isActive: Bool {
        switch self {
        case .connecting, .pairing:
            return true
        case .waiting, .ruledOut, .paired:
            return false
        }
    }

    public var ruleOutReason: G7PairingRuleOutReason? {
        guard case .ruledOut(let reason) = self else {
            return nil
        }
        return reason
    }

    /// Whether this candidate's run is over, either way. A settled status is
    /// never walked back: the run keeps the planner around after it ends, and
    /// a late callback must not turn a verdict back into a connection.
    public var isSettled: Bool {
        switch self {
        case .ruledOut, .paired:
            return true
        case .waiting, .connecting, .pairing:
            return false
        }
    }
}

/// One sensor the run has heard from, and what became of it.
public struct G7PairingCandidate: Identifiable, Equatable {
    /// Ordinary failures (a dropped link, a timeout) tolerated per sensor
    /// before it is ruled out as unreachable.
    public static let maximumAttempts = 3

    public let id: UUID
    /// The advertised name, "DXCM01" and the like.
    public let name: String
    /// Whether the sensor was last heard advertising its display slot as
    /// taken. It may be our own hold on it, so it is a reason to defer the
    /// sensor, never to drop it.
    public var isPhoneSlotHeld: Bool
    /// How many separate advertising cycles announced the slot as taken.
    /// Read from the advertisement's types-in-use byte, so it costs no
    /// connection and keeps counting after the sensor is ruled out.
    public var heldSlotCycles: Int
    /// When the last counted cycle was, to tell one cycle from the next.
    public var lastHeldSlotCycle: Date?
    /// Whether another display was announced as connected to this sensor
    /// before the run ever touched it.
    ///
    /// Only counted from advertisements heard while the sensor was still
    /// waiting its turn: once we are connecting, the held slot is our own
    /// and says nothing about anyone else. It stays true afterwards, because
    /// it is the one piece of evidence that survives a failed handshake.
    public var wasHeldByAnotherDisplay: Bool
    /// Failed attempts so far, within the current turn. Not reset when the
    /// candidate is ruled out, but reset when it is let back in: a sensor
    /// whose slot has freed is a fresh trial, not a continuation of the one
    /// that failed while it was busy.
    public var attempts: Int
    /// How many times this sensor has been let back into the queue after
    /// being ruled out as busy.
    public var readmissions: Int
    /// Since when it has been announcing its slot as free, for a sensor
    /// waiting to be let back in. Cleared the moment it says held again, and
    /// when it is ruled out, so the wait always starts after the refusal.
    public var freeSince: Date?
    /// Whether this sensor has had the one turn it is owed after outlasting
    /// any possible lease, whatever its advertisement still says.
    public var hasHadFinalAttempt: Bool
    public var status: G7PairingCandidateStatus

    public var model: G7SensorModel? {
        G7SensorModel(advertisedName: name)
    }

    /// Turns a busy sensor may have in all: its first, plus one for each time
    /// its slot frees up again.
    public static let maximumTurns = G7PairingPlanner.maximumReadmissions + 1

    /// Which turn this sensor is on, 1-based.
    public var turn: Int {
        readmissions + 1
    }

    /// Whether the run has set this sensor aside as busy but is still
    /// listening to it, ready to give it another turn if its slot frees. Not
    /// out of the running, however the row reads.
    public var isAwaitingASlotToFree: Bool {
        status.ruleOutReason == .inUseElsewhere
            && readmissions < G7PairingPlanner.maximumReadmissions
    }
}

/// Decides which sensor to try next.
///
/// A pairing code does not identify a sensor over the air (the advertised
/// name suffix is unrelated to it), so pairing may have to try several
/// sensors in range. The order matters: a sensor whose display slot is held
/// by another phone will reject us, and four rejections in a row make a
/// sensor stop accepting connections for a while. So unheld sensors go
/// first, a sensor that rejects us is dropped rather than retried, and
/// ordinary failures (a dropped link, a timeout) get a bounded number of
/// retries before moving on.
///
/// Running out of candidates is not a failure: an expired sensor, a spent
/// applicator in a drawer and the sensor on the user's arm all advertise, and
/// a sensor another display used in the last ~15 minutes advertises only once
/// every ~5 minutes rather than the ~1 minute of a free one. So the planner
/// asks to keep scanning instead, and a sensor arriving later takes its turn
/// behind the ones already ruled out.
///
/// Pure bookkeeping with no Bluetooth of its own, so the policy is testable
/// in isolation.
struct G7PairingPlanner {

    enum Action: Equatable {
        /// Try the current candidate again.
        case retryCurrent
        /// Move on to the next candidate.
        case advanceToNext
        /// Everything found so far is ruled out; keep scanning for a sensor
        /// that has not been heard from yet.
        case waitForNewCandidates
    }

    /// Advertisements closer together than this are one burst, not two
    /// cycles.
    ///
    /// Measured off the air: a sensor whose slot is leased advertises in a
    /// burst every ~300 s, and the packets inside one burst span up to ~5 s.
    /// Sixty seconds sits clear of both.
    static let heldSlotCycleInterval: TimeInterval = 60

    /// How many cycles of "a display is connected to me" settle it.
    ///
    /// A sensor whose slot is leased speaks up only around each five-minute
    /// reading, and the lease itself lapses after ~15 minutes of the holder
    /// being silent. When we first hear a held sensor we have no idea how
    /// much of that has already run, so the count has to cover the whole of
    /// it — and the first cycle is the one counted at discovery, which puts
    /// the nth at (n - 1) five-minute readings:
    ///
    ///     3 cycles → 10 minutes    a lease taken just before we started
    ///                              still has five minutes to run
    ///     4 cycles → 15 minutes    exactly when that lease lapses; a
    ///                              coin toss, not a margin
    ///     5 cycles → 20 minutes    past any lease, whenever it was taken
    ///
    /// So five. A slot still held there is being refreshed by something that
    /// is still talking to the sensor, and no amount of waiting will free it.
    static let heldSlotCyclesBeforeGivingUp = 5

    /// How many times a sensor ruled out as busy may be let back in after it
    /// says its display slot is free again.
    ///
    /// Being busy is not being the wrong sensor: the lease another display
    /// holds expires after about 15 minutes of silence, so a sensor that
    /// cannot take us now may take us later in the same run.
    ///
    /// What bounds the retrying is the sensor itself — four rejections in a
    /// row put it into a cooldown where it accepts no connections at all, and
    /// one first try plus three re-admissions spends exactly that budget. It
    /// is deliberately the whole of it: a re-admission only happens after the
    /// sensor has said its slot is free, which is the one condition under
    /// which the next attempt has any reason to go differently, so there is
    /// nothing to be gained by stopping short of the fourth.
    static let maximumReadmissions = 3

    /// How long a sensor has to keep announcing its slot as free before it is
    /// let back in.
    ///
    /// This is not a guess at when the lease expires. The sensor says that
    /// itself, by how it advertises: measured off the air, a leased slot means
    /// a burst every ~300 s, and a free one a burst every ~60 s. Each burst
    /// spans only a second or two, so ten seconds cannot be served inside one
    /// and always costs a second burst — about a minute in practice. That is
    /// the point: a stray packet or a slot renewed inside a burst cannot buy
    /// a sensor its way back in.
    static let readmissionFreeDebounce: TimeInterval = 10

    /// Every sensor found, in the order they are tried: ruled-out ones first
    /// (oldest first), then the one under trial, then those still waiting.
    private(set) var candidates: [G7PairingCandidate] = []
    private(set) var currentIndex = 0

    var currentCandidate: G7PairingCandidate? {
        currentIndex < candidates.count ? candidates[currentIndex] : nil
    }

    /// The attempt number the next try will be, 1-based.
    var nextAttemptNumber: Int {
        (currentCandidate?.attempts ?? 0) + 1
    }

    func status(of id: UUID) -> G7PairingCandidateStatus? {
        candidates.first { $0.id == id }?.status
    }

    /// The sensor holding the run up, if there is one: everything found has
    /// been ruled out, and this one has kept announcing that a display is
    /// connected to it for longer than a lease can last. Something is
    /// refreshing it, so the run cannot get anywhere until the user stops
    /// whatever that is, and scanning on would only keep the screen busy.
    ///
    /// A sensor that answered with proof the code is not its own is never
    /// the one: it said something definite about itself, while this one
    /// never gave us the chance to find out.
    ///
    /// Only a candidate that has already had its final attempt qualifies.
    /// Until then it is a sensor owed one more turn, not a blocker.
    /// Every one of them has to have had it: a busy sensor is one we never
    /// got an answer out of, so with two in the room either could be the one
    /// the code belongs to.
    var heldSlotBlocker: G7PairingCandidate? {
        let stuck = stuckCandidates
        guard !stuck.isEmpty, stuck.allSatisfy(\.hasHadFinalAttempt) else {
            return nil
        }
        return stuck.max { $0.heldSlotCycles < $1.heldSlotCycles }
    }

    /// How many sensors are holding the run up. More than one, and the
    /// message can only name the worst of them.
    var heldSlotBlockerCount: Int {
        heldSlotBlocker == nil ? 0 : stuckCandidates.count
    }

    /// Every sensor the run could be stuck behind, whether or not each has
    /// had its last turn yet.
    private var stuckCandidates: [G7PairingCandidate] {
        guard !candidates.isEmpty,
              candidates.allSatisfy({ $0.status.ruleOutReason != nil })
        else {
            return []
        }
        return candidates.filter {
            $0.status.ruleOutReason != .wrongPairingCode
                && $0.heldSlotCycles >= G7PairingPlanner.heldSlotCyclesBeforeGivingUp
        }
    }

    /// Gives a sensor the run is stuck behind one turn before the run gives
    /// up on it, and reports whether one took it. Called until it says no, so
    /// every stuck sensor gets a turn.
    ///
    /// Everything else about a busy sensor is read off its advertisement, and
    /// the run's most alarming message, go and stop whatever else is using
    /// this sensor, would otherwise rest on that one bit. It was last checked
    /// against the sensor itself twenty minutes earlier, when the lease was
    /// certainly still alive. By now it cannot be. So try, whatever the
    /// advertisement says: either the sensor pairs and the advertisement was
    /// not to be trusted, or it refuses and the interference is measured
    /// rather than inferred.
    ///
    /// Not bounded by `maximumReadmissions`, and it does not spend one. This
    /// is the run's last act either way, so the only budget that matters is
    /// the sensor's own four-rejection cooldown, and a run that got here has
    /// spent one rejection on this sensor rather than four.
    mutating func admitBlockerForFinalAttempt() -> Bool {
        guard let next = stuckCandidates.first(where: { !$0.hasHadFinalAttempt }),
              let index = candidates.firstIndex(where: { $0.id == next.id })
        else {
            return false
        }

        var candidate = candidates.remove(at: index)
        candidate.hasHadFinalAttempt = true
        candidate.attempts = 0
        candidate.freeSince = nil
        candidate.status = .waiting
        if index < currentIndex {
            currentIndex -= 1
        }
        candidates.append(candidate)
        return true
    }

    /// Adds a newly discovered sensor. Returns false if it was already known,
    /// including when it was ruled out earlier.
    ///
    /// New candidates go behind everything already tried, and behind
    /// untried candidates of a better class: an unheld newcomer is queued
    /// ahead of untried held candidates, since those are likely to reject us.
    @discardableResult
    mutating func addCandidate(id: UUID, name: String, isPhoneSlotHeld: Bool) -> Bool {
        guard !candidates.contains(where: { $0.id == id }) else {
            return false
        }
        let candidate = G7PairingCandidate(
            id: id,
            name: name,
            isPhoneSlotHeld: isPhoneSlotHeld,
            heldSlotCycles: 0,
            lastHeldSlotCycle: nil,
            wasHeldByAnotherDisplay: isPhoneSlotHeld,
            attempts: 0,
            readmissions: 0,
            freeSince: nil,
            hasHadFinalAttempt: false,
            status: .waiting
        )

        // Never reorder anything at or before the current index: the current
        // candidate may be mid-handshake.
        let untried = candidates.indices.filter { $0 > currentIndex }
        if !isPhoneSlotHeld, let firstHeld = untried.first(where: { candidates[$0].isPhoneSlotHeld }) {
            candidates.insert(candidate, at: firstHeld)
        } else {
            candidates.append(candidate)
        }
        return true
    }

    /// Records a fresh advertisement from a known candidate: which slots it
    /// says are in use, and whether that is another cycle of a slot still
    /// held. A held slot frees up after ~15 minutes of silence, so a
    /// candidate deferred earlier can become preferable; a slot that stays
    /// held instead is evidence that something else keeps connecting to the
    /// sensor, which is worth counting even for a candidate already ruled
    /// out (it is the only thing that explains a run getting nowhere).
    ///
    /// Returns whether anything changed.
    @discardableResult
    mutating func recordAdvertisement(id: UUID, isPhoneSlotHeld: Bool?, at date: Date = Date()) -> Bool {
        // Nil is "the advertisement did not say", which is not "the slot is
        // free": a packet arriving without usable manufacturer data would
        // otherwise read as the sensor having been let go, and one of those
        // is enough to undo everything its real advertisements said.
        guard let isPhoneSlotHeld = isPhoneSlotHeld,
              let index = candidates.firstIndex(where: { $0.id == id })
        else {
            return false
        }

        var changed = false
        if isPhoneSlotHeld {
            candidates[index].freeSince = nil

            // Before its turn comes, a held slot can only be someone else's.
            if candidates[index].status == .waiting, !candidates[index].wasHeldByAnotherDisplay {
                candidates[index].wasHeldByAnotherDisplay = true
                changed = true
            }

            let last = candidates[index].lastHeldSlotCycle
            if last == nil || date.timeIntervalSince(last!) >= G7PairingPlanner.heldSlotCycleInterval {
                candidates[index].heldSlotCycles += 1
                candidates[index].lastHeldSlotCycle = date
                changed = true
            }
        } else if candidates[index].freeSince == nil {
            candidates[index].freeSince = date
        } else if readmit(at: index, at: date) {
            return true
        }

        // Record what it said whatever became of it. A ruled-out sensor is
        // not re-queued by a change of slot, but it is still listened to, and
        // leaving the last value frozen at the verdict left the row on screen
        // stale and the log reporting "slot is now held" every cycle with no
        // "free" in between, as though the slot were flapping.
        guard candidates[index].isPhoneSlotHeld != isPhoneSlotHeld else {
            return changed
        }
        candidates[index].isPhoneSlotHeld = isPhoneSlotHeld
        guard candidates[index].status.ruleOutReason == nil else {
            return true
        }

        // Re-sort only the untried tail, preserving discovery order within
        // each class.
        let tailStart = currentIndex + 1
        guard tailStart < candidates.count else {
            return true
        }
        let tail = candidates[tailStart...]
        candidates.replaceSubrange(tailStart..., with: tail.filter { !$0.isPhoneSlotHeld } + tail.filter { $0.isPhoneSlotHeld })
        return true
    }

    /// The current candidate is being connected to. Returns whether that was
    /// news, so the caller can skip republishing an unchanged run.
    @discardableResult
    mutating func markConnecting() -> Bool {
        guard currentIndex < candidates.count,
              !candidates[currentIndex].status.isSettled,
              candidates[currentIndex].status != .connecting
        else {
            return false
        }
        candidates[currentIndex].status = .connecting
        return true
    }

    /// Opens an attempt on the current candidate, returning its 1-based
    /// number. Attempts are counted as they fail, not as they start: a
    /// candidate that never gets far enough to open one is still on its way
    /// to being ruled out as unreachable.
    @discardableResult
    mutating func beginAttempt() -> Int {
        let attempt = nextAttemptNumber
        if currentIndex < candidates.count, !candidates[currentIndex].status.isSettled {
            candidates[currentIndex].status = .pairing(attempt: attempt)
        }
        return attempt
    }

    mutating func markCurrentPaired() {
        guard currentIndex < candidates.count else {
            return
        }
        candidates[currentIndex].status = .paired
    }

    /// An ordinary failure on the current candidate: retry it, or rule it out
    /// as unreachable once it has used up its attempts.
    mutating func recordFailure() -> Action {
        guard currentIndex < candidates.count else {
            return .waitForNewCandidates
        }
        candidates[currentIndex].attempts += 1
        if candidates[currentIndex].attempts < G7PairingCandidate.maximumAttempts {
            candidates[currentIndex].status = .connecting
            return .retryCurrent
        }
        return ruleOutCurrent(.unreachable)
    }

    /// Lets a sensor ruled out as busy back into the queue, now that it says
    /// its display slot is free.
    ///
    /// It goes to the back, behind everything not yet tried: a sensor that
    /// has already refused us once is the last one worth spending a turn on.
    /// Nothing at or before the current index moves, so a handshake in
    /// flight is undisturbed.
    ///
    /// The turn it gets is a whole one. Attempts count dropped links and
    /// timeouts within a turn, and the ones it spent while its slot was taken
    /// say nothing about reaching it now; carrying them over would let a
    /// single stray disconnect rule it out as unreachable and cost it every
    /// re-admission it had left.
    private mutating func readmit(at index: Int, at date: Date) -> Bool {
        guard candidates[index].status == .ruledOut(.inUseElsewhere),
              candidates[index].readmissions < G7PairingPlanner.maximumReadmissions,
              let freeSince = candidates[index].freeSince,
              date.timeIntervalSince(freeSince) >= G7PairingPlanner.readmissionFreeDebounce
        else {
            return false
        }

        var candidate = candidates.remove(at: index)
        candidate.readmissions += 1
        candidate.attempts = 0
        candidate.isPhoneSlotHeld = false
        candidate.freeSince = nil
        candidate.status = .waiting
        // Taking it out from behind the cursor shifts everything after it
        // down one, the cursor included.
        if index < currentIndex {
            currentIndex -= 1
        }
        candidates.append(candidate)
        return true
    }

    /// The current candidate cannot succeed (it rejected us, or it proved it
    /// does not belong to this code): drop it without retrying.
    ///
    /// Final, with one exception: a sensor ruled out as busy is let back in
    /// if its slot frees up again, up to `maximumReadmissions` times.
    mutating func ruleOutCurrent(_ reason: G7PairingRuleOutReason) -> Action {
        guard currentIndex < candidates.count else {
            return .waitForNewCandidates
        }
        candidates[currentIndex].status = .ruledOut(reason)
        // Whatever it said about its slot before the refusal is spent; only
        // what it says from here counts toward being let back in.
        candidates[currentIndex].freeSince = nil
        currentIndex += 1
        return currentCandidate != nil ? .advanceToNext : .waitForNewCandidates
    }
}
