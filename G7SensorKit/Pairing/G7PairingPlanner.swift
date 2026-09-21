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
    /// It answered our challenge with something our key did not produce, so
    /// the code entered is not its code.
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
    /// Failed attempts so far. Not reset when the candidate is ruled out.
    public var attempts: Int
    public var status: G7PairingCandidateStatus

    public var model: G7SensorModel? {
        G7SensorModel(advertisedName: name)
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
/// a sensor another display used in the last ~15 minutes only advertises in a
/// brief window around each 5-minute reading. So the planner asks to keep
/// scanning instead, and a sensor arriving later takes its turn behind the
/// ones already ruled out.
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
            attempts: 0,
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

    /// Records a fresh advertisement from a known candidate. A held slot
    /// frees up after ~15 minutes of silence, so a candidate deferred earlier
    /// can become preferable. A candidate already ruled out is never
    /// reordered: it is out of the running whatever its slot says now.
    ///
    /// Returns whether anything changed.
    @discardableResult
    mutating func updateSlot(id: UUID, isPhoneSlotHeld: Bool) -> Bool {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              candidates[index].isPhoneSlotHeld != isPhoneSlotHeld,
              candidates[index].status.ruleOutReason == nil
        else {
            return false
        }
        candidates[index].isPhoneSlotHeld = isPhoneSlotHeld

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

    /// The current candidate cannot succeed (it rejected us, or it proved it
    /// does not belong to this code): drop it without retrying, for the rest
    /// of the run.
    mutating func ruleOutCurrent(_ reason: G7PairingRuleOutReason) -> Action {
        guard currentIndex < candidates.count else {
            return .waitForNewCandidates
        }
        candidates[currentIndex].status = .ruledOut(reason)
        currentIndex += 1
        return currentCandidate != nil ? .advanceToNext : .waitForNewCandidates
    }
}
