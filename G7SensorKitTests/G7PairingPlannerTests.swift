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
        XCTAssertFalse(planner.updateSlot(id: a, isPhoneSlotHeld: true), "a ruled-out sensor is not re-queued by a change of slot")
        XCTAssertEqual(planner.status(of: a), .ruledOut(.wrongPairingCode))
        XCTAssertNil(planner.currentCandidate)
    }

    /// The held slot expires after ~15 minutes of silence, so a repeat
    /// advertisement can move a deferred candidate forward.
    func testSlotUpdateReordersUntriedCandidates() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "held", isPhoneSlotHeld: true)
        planner.addCandidate(id: c, name: "free", isPhoneSlotHeld: false)
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "free", "held"])

        XCTAssertTrue(planner.updateSlot(id: b, isPhoneSlotHeld: false))
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "free", "held"], "discovery order holds within a class")

        XCTAssertTrue(planner.updateSlot(id: c, isPhoneSlotHeld: true))
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "held", "free"])

        XCTAssertFalse(planner.updateSlot(id: c, isPhoneSlotHeld: true), "no change reports no change")
    }

    func testSlotUpdateNeverMovesTheCurrentCandidate() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "other", isPhoneSlotHeld: false)
        planner.updateSlot(id: a, isPhoneSlotHeld: true)
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
