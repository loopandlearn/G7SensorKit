//
//  G7PairingPlannerTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

class G7PairingPlannerTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func testFirstCandidateBecomesCurrent() {
        var planner = G7PairingPlanner()
        XCTAssertNil(planner.currentCandidate)
        XCTAssertTrue(planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false))
        XCTAssertEqual(planner.currentCandidate?.id, a)
        XCTAssertEqual(planner.currentCandidate?.status, .waiting)
        XCTAssertEqual(planner.nextAttemptNumber, 1)
    }

    func testDuplicateDiscoveryIsIgnored() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false)
        XCTAssertFalse(planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false))
        XCTAssertEqual(planner.candidates.count, 1)
    }

    /// A sensor another phone is using will reject us, and rejections count
    /// toward a lockout, so free sensors are tried first.
    func testFreeSensorsAreTriedBeforeHeldOnes() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "held", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "free", isPhoneSlotHeld: false)
        // `a` was already current when `b` arrived, so it keeps its turn...
        XCTAssertEqual(planner.currentCandidate?.name, "held")

        // ...but among the untried tail, free ones jump ahead of held ones.
        planner.addCandidate(id: c, name: "held2", isPhoneSlotHeld: true)
        let d = UUID()
        planner.addCandidate(id: d, name: "free2", isPhoneSlotHeld: false)
        XCTAssertEqual(planner.candidates.map(\.name), ["held", "free", "free2", "held2"])
    }

    func testHeldCandidateIsDeferredNotDropped() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "free", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "held", isPhoneSlotHeld: true)
        XCTAssertEqual(planner.ruleOutCurrent(.wrongPairingCode), .advanceToNext)
        XCTAssertEqual(planner.currentCandidate?.name, "held", "a held sensor may be our own; it still gets a turn")
    }

    func testOrdinaryFailuresRetryThenRuleOutAsUnreachable() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "B", isPhoneSlotHeld: false)

        for attempt in 1 ..< G7PairingCandidate.maximumAttempts {
            XCTAssertEqual(planner.nextAttemptNumber, attempt)
            XCTAssertEqual(planner.beginAttempt(), attempt)
            XCTAssertEqual(planner.currentCandidate?.status, .pairing(attempt: attempt))
            XCTAssertEqual(planner.recordFailure(), .retryCurrent)
        }
        XCTAssertEqual(planner.recordFailure(), .advanceToNext)
        XCTAssertEqual(planner.candidates.first?.status, .ruledOut(.unreachable))
        XCTAssertEqual(planner.currentCandidate?.id, b)
        XCTAssertEqual(planner.nextAttemptNumber, 1, "attempts are counted per candidate")
    }

    /// A rejection is terminal for that sensor, and retrying it invites the
    /// lockout, so it is dropped on the first one.
    func testRuleOutAbandonsImmediately() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "B", isPhoneSlotHeld: false)

        XCTAssertEqual(planner.ruleOutCurrent(.inUseElsewhere), .advanceToNext)
        XCTAssertEqual(planner.candidates.first?.status, .ruledOut(.inUseElsewhere))
        XCTAssertEqual(planner.currentCandidate?.id, b)
    }

    /// Running out of candidates is not the end of the run: the sensor that
    /// will pair may not have advertised yet.
    func testExhaustedCandidatesKeepTheRunScanning() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)

        XCTAssertEqual(planner.ruleOutCurrent(.wrongPairingCode), .waitForNewCandidates)
        XCTAssertNil(planner.currentCandidate)
        XCTAssertEqual(planner.recordFailure(), .waitForNewCandidates, "with nothing under trial there is nothing to score")

        // A sensor arriving later takes its turn behind the ruled-out one,
        // which keeps its verdict on screen.
        XCTAssertTrue(planner.addCandidate(id: b, name: "B", isPhoneSlotHeld: false))
        XCTAssertEqual(planner.currentCandidate?.id, b)
        XCTAssertEqual(planner.candidates.map(\.status), [.ruledOut(.wrongPairingCode), .waiting])
    }

    /// A sensor that has been ruled out stays ruled out: it advertises every
    /// few seconds, and trying it again would cost the next candidate its turn.
    func testRuledOutCandidateIsNeverReadmitted() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        _ = planner.ruleOutCurrent(.wrongPairingCode)

        XCTAssertFalse(planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false))
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: true)
        XCTAssertEqual(planner.status(of: a), .ruledOut(.wrongPairingCode))
        XCTAssertNil(planner.currentCandidate, "a ruled-out sensor is not re-queued by a change of slot")
    }

    /// A ruled-out sensor is still listened to, so what it says about its slot
    /// is still worth recording: the row on screen shows it, and a value
    /// frozen at the verdict makes every later held reading look like a fresh
    /// transition.
    func testARuledOutSensorStillRecordsWhatItSaysAboutItsSlot() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "B", isPhoneSlotHeld: false)
        _ = planner.ruleOutCurrent(.wrongPairingCode)

        XCTAssertTrue(planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start))
        XCTAssertEqual(planner.candidates.first?.isPhoneSlotHeld, true)

        // The same reading again is not a transition, so the run has nothing
        // new to say about it.
        XCTAssertFalse(planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + 1))
        XCTAssertTrue(planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start + 2))
        XCTAssertEqual(planner.candidates.first?.isPhoneSlotHeld, false)

        XCTAssertEqual(planner.currentCandidate?.id, b, "recording a slot does not disturb the queue")
        XCTAssertEqual(planner.candidates.map(\.id), [a, b])
    }

    /// The slot in the advertisement is the only evidence a stuck run has, so
    /// it keeps being read after the sensor is out of the running.
    func testHeldSlotCyclesCountOncePerAdvertisingWindow() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: true)

        XCTAssertTrue(planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start))
        XCTAssertEqual(planner.candidates.first?.heldSlotCycles, 1)

        // Still the same burst: a leased sensor advertises for about two
        // seconds around each reading.
        XCTAssertFalse(planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + 2))
        XCTAssertEqual(planner.candidates.first?.heldSlotCycles, 1)

        // The next reading, five minutes on.
        XCTAssertTrue(planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + 300))
        XCTAssertEqual(planner.candidates.first?.heldSlotCycles, 2)

        // A freed slot is news, but it is not another cycle of a held one.
        XCTAssertTrue(planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start + 600))
        XCTAssertEqual(planner.candidates.first?.heldSlotCycles, 2)
        XCTAssertEqual(planner.candidates.first?.isPhoneSlotHeld, false)
    }

    /// Something that keeps renewing the sensor's lease will not stop because
    /// we waited longer, so the run says so instead of scanning on.
    func testTheRunIsBlockedByASensorHeldAcrossEveryCycle() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "DXCM01", isPhoneSlotHeld: false)

        _ = planner.ruleOutCurrent(.inUseElsewhere)
        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
        }
        XCTAssertNil(planner.heldSlotBlocker, "the other sensor has not had its turn yet")

        _ = planner.ruleOutCurrent(.wrongPairingCode)
        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertEqual(planner.heldSlotBlocker?.id, a)
    }

    func testTheBlockerNeedsEveryCycle() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            XCTAssertFalse(planner.admitBlockerForFinalAttempt(), "gave up after \(cycle) cycles")
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
        }
        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertEqual(planner.heldSlotBlocker?.id, a)
    }

    /// The worst case the count has to survive: a display took the slot just
    /// before the run started, so the lease has its full ~15 minutes left.
    /// Giving up at ten minutes ends the run five minutes short of the lease
    /// lapsing, and giving up at fifteen lands on the very moment it does —
    /// neither is a margin. Only the twentieth minute is past any lease.
    func testTheBlockerOutlastsALeaseTakenJustBeforeTheRun() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        // A leased sensor speaks up around each five-minute reading.
        for minutes in stride(from: 0.0, through: 20.0, by: 5.0) {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + minutes * 60)
            if minutes < 20 {
                XCTAssertFalse(planner.admitBlockerForFinalAttempt(), "gave up at minute \(minutes), before the lease was certainly over")
            }
        }
        XCTAssertTrue(planner.admitBlockerForFinalAttempt(), "a slot still held past any lease earns a last turn")
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertEqual(planner.heldSlotBlocker?.id, a, "and refusing that turn is what settles it")
    }

    /// Everything the run knows about a busy sensor comes off its
    /// advertisement. Before saying so out loud, ask the sensor: the lease it
    /// was announcing cannot still be alive, so a refusal now is measured
    /// interference rather than a bit read off the air.
    func testTheBlockerGetsOneLastTurnBeforeTheRunGivesUp() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
        }

        // Held past any lease, but not yet asked, so not yet a blocker.
        XCTAssertNil(planner.heldSlotBlocker)
        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        XCTAssertEqual(planner.currentCandidate?.id, a)
        XCTAssertEqual(planner.currentCandidate?.status, .waiting)
        XCTAssertEqual(planner.currentCandidate?.attempts, 0, "the last turn is a whole one")
        XCTAssertNil(planner.heldSlotBlocker, "a sensor under trial is not blocking anything")

        // It refused. Now the run has something to tell the user.
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertEqual(planner.heldSlotBlocker?.id, a)
    }

    /// Two busy sensors, one of which may be the one the code belongs to.
    /// The run must not give up while either still has a turn owed.
    func testEveryStuckSensorGetsALastTurn() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "busy1", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "busy2", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            let at = start + Double(cycle) * 300
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: at)
            planner.recordAdvertisement(id: b, isPhoneSlotHeld: true, at: at)
        }

        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        let first = planner.currentCandidate?.id
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertNil(planner.heldSlotBlocker, "gave up with the other sensor still owed a turn")

        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        XCTAssertNotEqual(planner.currentCandidate?.id, first, "gave the same sensor two last turns")
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        XCTAssertNotNil(planner.heldSlotBlocker)
        XCTAssertEqual(planner.heldSlotBlockerCount, 2)
        XCTAssertFalse(planner.admitBlockerForFinalAttempt())
    }

    /// A sensor that answered still counts itself out, so it neither earns a
    /// last turn nor holds the run open.
    func testASensorThatRejectedTheCodeNeitherBlocksNorGetsALastTurn() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "wrong", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        _ = planner.ruleOutCurrent(.wrongPairingCode)

        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            let at = start + Double(cycle) * 300
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: at)
            planner.recordAdvertisement(id: b, isPhoneSlotHeld: true, at: at)
        }

        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        XCTAssertEqual(planner.currentCandidate?.id, a)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        XCTAssertEqual(planner.heldSlotBlocker?.id, a)
        XCTAssertEqual(planner.heldSlotBlockerCount, 1, "the sensor that answered is not holding anything up")
    }

    func testTheLastTurnIsOnlyOfferedOnce() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
        }

        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertFalse(planner.admitBlockerForFinalAttempt(), "a second last turn would spend the cooldown budget")
    }

    /// Asking costs a rejection, so it is only worth asking once the lease it
    /// was announcing can no longer be alive.
    func testNoLastTurnBeforeTheSensorHasOutlastedALease() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp - 1 {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
            XCTAssertFalse(planner.admitBlockerForFinalAttempt(), "asked after \(cycle + 1) cycles")
        }
    }

    /// The last turn can be the one that works, which is the whole reason for
    /// offering it.
    func testTheLastTurnCanStillPair() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "DX0217", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        for cycle in 0 ..< G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
        }

        XCTAssertTrue(planner.admitBlockerForFinalAttempt())
        planner.beginAttempt()
        planner.markCurrentPaired()

        XCTAssertEqual(planner.currentCandidate?.status, .paired)
        XCTAssertNil(planner.heldSlotBlocker)
    }

    /// A sensor that answered with proof the code is not its own has already
    /// explained itself; its slot is beside the point.
    func testASensorThatRejectedTheCodeIsNeverTheBlocker() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.wrongPairingCode)

        for cycle in 0 ... G7PairingPlanner.heldSlotCyclesBeforeGivingUp {
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + Double(cycle) * 300)
        }
        XCTAssertNil(planner.heldSlotBlocker, "held past the threshold and still not the blocker")
    }

    func testASensorFoundWithItsSlotTakenIsRemembered() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "held", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "free", isPhoneSlotHeld: false)

        XCTAssertTrue(planner.candidates.first { $0.id == a }?.wasHeldByAnotherDisplay ?? false)
        XCTAssertFalse(planner.candidates.first { $0.id == b }?.wasHeldByAnotherDisplay ?? true)
    }

    /// The slot can free up and be taken again between one advertisement and
    /// the next, so a sensor heard as busy at any point before its turn keeps
    /// that against it: it is what explains a handshake that goes nowhere.
    func testASlotTakenWhileWaitingIsRemembered() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "waiting", isPhoneSlotHeld: false)

        planner.recordAdvertisement(id: b, isPhoneSlotHeld: true)
        planner.recordAdvertisement(id: b, isPhoneSlotHeld: false)

        XCTAssertTrue(planner.candidates.first { $0.id == b }?.wasHeldByAnotherDisplay ?? false)
    }

    /// Once the run is connected, the held slot is its own doing.
    func testOurOwnHoldIsNotEvidenceOfAnotherDisplay() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.markConnecting()
        planner.beginAttempt()

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: true)

        XCTAssertFalse(planner.candidates.first { $0.id == a }?.wasHeldByAnotherDisplay ?? true)
    }

    /// Busy is a state, not a verdict: the lease lapses and the sensor
    /// becomes pairable again inside the same run.
    /// A lapsed lease shows itself in the advertising: bursts every ~60 s
    /// instead of every ~300 s.
    func testABusySensorIsLetBackInOnceFreeHolds() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertNil(planner.currentCandidate)

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start)
        XCTAssertTrue(planner.recordAdvertisement(
            id: a,
            isPhoneSlotHeld: false,
            at: start + G7PairingPlanner.readmissionFreeDebounce
        ))

        XCTAssertEqual(planner.currentCandidate?.id, a)
        XCTAssertEqual(planner.currentCandidate?.status, .waiting)
        XCTAssertEqual(planner.currentCandidate?.readmissions, 1)
    }

    func testOneFreeReadingIsNotEnoughToBeLetBackIn() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false)

        XCTAssertNil(planner.currentCandidate)
        XCTAssertEqual(planner.candidates.first?.readmissions, 0)
    }

    /// A slot that frees and is taken again inside one burst is the lease
    /// being renewed, not released.
    func testSayingHeldAgainRestartsTheWait() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: true, at: start + 1)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start + 2)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start + G7PairingPlanner.readmissionFreeDebounce)

        XCTAssertNil(planner.currentCandidate, "let back in on a wait that had been interrupted")
    }

    /// An advertisement without the types-in-use byte says nothing. Reading
    /// it as a free slot would undo what the sensor really said.
    func testAnUnreadableAdvertisementChangesNothing() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        for _ in 0 ..< 10 {
            XCTAssertFalse(planner.recordAdvertisement(id: a, isPhoneSlotHeld: nil))
        }

        XCTAssertNil(planner.currentCandidate)
        XCTAssertNil(planner.candidates.first?.freeSince)
        XCTAssertEqual(planner.candidates.first?.status, .ruledOut(.inUseElsewhere))
    }

    func testAReadmittedSensorWaitsBehindTheUntriedOnes() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "untried", isPhoneSlotHeld: false)
        _ = planner.ruleOutCurrent(.inUseElsewhere)
        XCTAssertEqual(planner.currentCandidate?.id, b)

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start + G7PairingPlanner.readmissionFreeDebounce)

        XCTAssertEqual(planner.currentCandidate?.id, b, "the untried sensor keeps its turn")
        XCTAssertEqual(planner.candidates.last?.id, a)
    }

    /// Every attempt that ends in a rejection counts toward the sensor's own
    /// cooldown, so the retrying has to stop somewhere.
    func testReadmissionIsCapped() {
        var planner = G7PairingPlanner()
        var now = Date()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)

        for round in 1 ... G7PairingPlanner.maximumReadmissions {
            _ = planner.ruleOutCurrent(.inUseElsewhere)
            planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: now)
            now += G7PairingPlanner.readmissionFreeDebounce
            XCTAssertTrue(planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: now), "round \(round)")
            XCTAssertEqual(planner.currentCandidate?.readmissions, round)
        }

        _ = planner.ruleOutCurrent(.inUseElsewhere)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: now)
        now += G7PairingPlanner.readmissionFreeDebounce
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: now)
        XCTAssertNil(planner.currentCandidate, "a fourth re-admission would spend the cooldown budget")
    }

    /// Attempts count dropped links within a turn. A sensor let back in gets
    /// a whole turn, and the attempts it spent while its slot was taken say
    /// nothing about reaching it now: carried over, one stray disconnect
    /// would rule it out as unreachable and cost it the re-admissions it had
    /// left.
    func testAReadmittedSensorStartsItsAttemptsOver() {
        var planner = G7PairingPlanner()
        var now = Date()
        planner.addCandidate(id: a, name: "busy", isPhoneSlotHeld: true)

        for _ in 1 ..< G7PairingCandidate.maximumAttempts {
            planner.beginAttempt()
            XCTAssertEqual(planner.recordFailure(), .retryCurrent)
        }
        _ = planner.ruleOutCurrent(.inUseElsewhere)

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: now)
        now += G7PairingPlanner.readmissionFreeDebounce
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: now)

        XCTAssertEqual(planner.currentCandidate?.id, a)
        XCTAssertEqual(planner.currentCandidate?.attempts, 0)
        XCTAssertEqual(planner.nextAttemptNumber, 1)
        planner.beginAttempt()
        XCTAssertEqual(planner.recordFailure(), .retryCurrent, "ruled out as unreachable on its first dropped link")
    }

    func testASensorThatRejectedTheCodeIsNeverLetBackIn() {
        var planner = G7PairingPlanner()
        let start = Date()
        planner.addCandidate(id: a, name: "wrong", isPhoneSlotHeld: false)
        _ = planner.ruleOutCurrent(.wrongPairingCode)

        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: false, at: start + 3600)

        XCTAssertNil(planner.currentCandidate)
        XCTAssertEqual(planner.candidates.first?.status, .ruledOut(.wrongPairingCode))
    }

    func testPairedCandidateIsMarked() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.beginAttempt()
        planner.markCurrentPaired()
        XCTAssertEqual(planner.status(of: a), .paired)
    }

    func testConnectingIsReportedOnce() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        XCTAssertTrue(planner.markConnecting())
        XCTAssertFalse(planner.markConnecting(), "an unchanged run should not republish")
        XCTAssertEqual(planner.status(of: a), .connecting)
    }

    /// The held slot expires after ~15 minutes of silence, so a repeat
    /// advertisement can move a deferred candidate forward.
    func testSlotUpdateReordersUntriedCandidates() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "held", isPhoneSlotHeld: true)
        planner.addCandidate(id: c, name: "free", isPhoneSlotHeld: false)
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "free", "held"])

        XCTAssertTrue(planner.recordAdvertisement(id: b, isPhoneSlotHeld: false))
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "free", "held"], "discovery order holds within a class")

        XCTAssertTrue(planner.recordAdvertisement(id: c, isPhoneSlotHeld: true))
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "held", "free"])

        XCTAssertFalse(planner.recordAdvertisement(id: c, isPhoneSlotHeld: true), "no change reports no change")
    }

    func testSlotUpdateNeverMovesTheCurrentCandidate() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "other", isPhoneSlotHeld: false)
        planner.recordAdvertisement(id: a, isPhoneSlotHeld: true)
        XCTAssertEqual(planner.currentCandidate?.id, a, "a candidate mid-handshake must stay put")
    }

    func testModelComesFromTheAdvertisedName() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "DX0212", isPhoneSlotHeld: false)
        planner.addCandidate(id: c, name: "DX0134", isPhoneSlotHeld: false)
        XCTAssertEqual(planner.candidates.map(\.model), [.g7, .onePlus, .stelo])
    }
}
