//
//  G7PairingService.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit):
//  the pairing run follows its G7PairingRunner.
//

import CoreBluetooth
import Foundation
import os.log

public enum G7PairingState: Equatable {
    case idle
    /// A run in progress: every sensor heard from so far, in the order they
    /// are tried, each carrying how far it got. Empty while the scan has
    /// found nothing yet.
    case running(candidates: [G7PairingCandidate])
    /// Paired. `sharedKey` must be persisted: it is what lets reconnects skip
    /// the key exchange.
    case succeeded(peripheralIdentifier: UUID, sharedKey: Data, deviceName: String?)
    case failed(reason: String)

    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed:
            return true
        case .idle, .running:
            return false
        }
    }

}

/// What a successful pairing run leaves for the session to take over: the
/// central it used and the connection it authenticated on.
public struct G7PairingHandoff {
    let bluetoothManager: G7BluetoothManager
    let peripheralManager: G7PeripheralManager
}

/// Pairs with a sensor: scan, connect to each plausible candidate in turn,
/// run the handshake, and hand back the key.
///
/// Runs on the session's own Bluetooth central when there is one (re-pairing
/// from settings), borrowing its delegate for the duration and giving it
/// back when done. There is exactly one central per app: a second could not
/// share the state-restoration identifier, and only the same central can
/// carry the authenticated connection straight into the session.
///
/// State changes are published on the main queue through `onStateChange`.
/// All of the service's own bookkeeping happens on the main queue too;
/// Bluetooth callbacks hop there first. That is not only for the UI's
/// benefit: `G7BluetoothManager.disconnectAll()` traps if called from the
/// Bluetooth queue, and the callbacks arrive on exactly that queue.
public final class G7PairingService {

    /// How long to look for a first candidate before giving up. Only a run
    /// that has never heard a sensor at all ever gives up: once one has been
    /// found the screen can show what became of it, so the scan keeps going
    /// until the user stops it. A sensor another display used within the last
    /// ~15 minutes advertises only in a brief window around each 5-minute
    /// reading until that lease lapses, so the wait has to outlast the lease
    /// with room to spare. The screen shows the elapsed time and offers a way
    /// out throughout.
    public static let scanTimeout: TimeInterval = 20 * 60

    /// Connect-to-ready deadline for the candidate under trial.
    static let candidateTimeout: TimeInterval = 20

    /// Cap on one whole handshake attempt. The per-step deadline inside the
    /// authenticator is generous; this bounds the sum.
    static let authenticationTimeout: TimeInterval = 90

    private let log = OSLog(category: "G7PairingService")

    private let lockedState = Locked<G7PairingState>(.idle)

    public var state: G7PairingState {
        lockedState.value
    }

    /// Called on the main queue after every state change.
    public var onStateChange: ((G7PairingState) -> Void)?

    /// The radio's state, published on the main queue whenever it changes
    /// during a run. Pairing cannot proceed while Bluetooth is off or the
    /// app is not allowed to use it, and the run keeps waiting rather than
    /// failing, so the screen has to say why nothing is happening.
    public var onBluetoothStateChange: ((CBManagerState) -> Void)?

    public var bluetoothState: CBManagerState {
        bluetoothManager?.centralState ?? .unknown
    }

    /// Receives the handshake's step-by-step narration, for a device log or
    /// a diagnostics view. Never carries the code or key.
    public var onLog: ((String) -> Void)?

    private var pairingCode = ""
    private var expectedSerial: String?
    /// The sensor a session is already paired with, when re-pairing. It is
    /// never the one being replaced, and trying it costs a handshake that
    /// ends in a rejection.
    private var excludedPeripheralIdentifier: UUID?

    /// The session's central, when re-pairing; nil during first-time setup,
    /// where the run creates the central the new session will adopt.
    private let borrowedBluetoothManager: G7BluetoothManager?

    /// The slot this client takes on the sensor; also which slot's lease in
    /// an advertisement matters when ordering candidates.
    let displayType: G7DisplayType
    private weak var previousDelegate: G7BluetoothManagerDelegate?
    /// The sensor the borrowed central was following, to hand back if the
    /// run does not replace it.
    private var previousActiveIdentifier: UUID?

    /// When scanning began, for the elapsed time on screen.
    public private(set) var scanStartedAt: Date?

    private var bluetoothManager: G7BluetoothManager?
    /// The candidate that authenticated, kept connected for the hand-off.
    private var authenticatedPeripheralManager: G7PeripheralManager?
    private var planner = G7PairingPlanner()
    private var readyManagers: [UUID: G7PeripheralManager] = [:]

    /// The sensors ruled out so far. Read from the Bluetooth queue to turn
    /// their advertisements away, so a ruled-out sensor is never connected to
    /// again, and written on main as the planner drops them.
    private let ruledOutIdentifiers = Locked<Set<UUID>>([])

    /// Sensors the scanned serial has turned away, so each is only logged
    /// once. Kept on the Bluetooth queue's side of the fence.
    private let skippedBySerial = Locked<Set<UUID>>([])

    private var authenticationInFlight = false
    /// Bumped whenever an in-flight handshake is disowned, so its late
    /// completion is ignored.
    private var authenticationGeneration = 0

    private var scanWatchdog: DispatchWorkItem?
    private var candidateWatchdog: DispatchWorkItem?
    private var authenticationWatchdog: DispatchWorkItem?

    /// - Parameter cgmManager: the manager being re-paired, if any. Its
    ///   session's central is borrowed for the run; with none, the run
    ///   creates the central the new session will adopt.
    public convenience init(cgmManager: G7CGMManager?, displayType: G7DisplayType = .phone) {
        self.init(bluetoothManager: cgmManager?.sensor.bluetoothManager, displayType: cgmManager?.displayType ?? displayType)
    }

    init(bluetoothManager: G7BluetoothManager?, displayType: G7DisplayType = .phone) {
        borrowedBluetoothManager = bluetoothManager
        self.displayType = displayType
    }

    /// After `.succeeded`: the central and connection for the session to take
    /// over. Clears the service's own claim on them, so a later `cancel()`
    /// does not tear down what the session is now using. Nil in the
    /// simulator, where nothing was connected.
    public func handOff() -> G7PairingHandoff? {
        guard case .succeeded = state,
              let bluetoothManager = bluetoothManager,
              let peripheralManager = authenticatedPeripheralManager
        else {
            return nil
        }
        self.bluetoothManager = nil
        authenticatedPeripheralManager = nil
        readyManagers.removeAll()
        return G7PairingHandoff(bluetoothManager: bluetoothManager, peripheralManager: peripheralManager)
    }

    private func setState(_ newState: G7PairingState) {
        lockedState.value = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    /// Republishes the run from the planner. Called after every change to a
    /// candidate, so the screen can narrate what pairing is doing rather than
    /// only that it is busy.
    private func publishProgress() {
        guard !state.isFinished else {
            return
        }
        setState(.running(candidates: planner.candidates))
    }

    private var isRunActive: Bool {
        bluetoothManager != nil && !state.isFinished
    }

    /// Always asynchronous, never inline: `scanForPeripheral()` runs the
    /// manager's queue synchronously on the calling (main) thread, so a
    /// callback arriving inside it is on the main thread but on the manager
    /// queue, and running work inline there trips the manager's
    /// not-on-queue preconditions.
    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    // MARK: - Control

    /// Whether `code` has the shape of a G7 pairing code.
    public static func isValidPairingCode(_ code: String) -> Bool {
        code.count == 4 && code.allSatisfy(\.isNumber)
    }

    /// Whether a scanned `serial` can narrow the scan.
    ///
    /// A sensor advertises a CRC16 of its serial's digits, never the serial
    /// itself, so knowing the serial lets the run skip every sensor whose
    /// advertisement cannot produce that CRC. A serial that is not plain
    /// ASCII digits has no CRC to compare and narrows nothing, and the
    /// screen must not claim a filter that is not running. Narrowing is all
    /// it is: a CRC collision is possible, and an advertisement without
    /// manufacturer data is kept either way, so the handshake still decides.
    public static func canFilterBySerial(_ serial: String) -> Bool {
        G7Advertisement.serialChecksum(for: serial) != nil
    }

    /// Starts pairing with `pairingCode`. `serial` is the package serial when
    /// the code came from a scan; candidates that cannot have that serial
    /// are then skipped rather than tried.
    public func start(pairingCode: String, serial: String? = nil, excludingPeripheral excluded: UUID? = nil) {
        cancel()

        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard G7PairingService.isValidPairingCode(code) else {
            setState(.failed(reason: LocalizedString(
                "The pairing code is the 4-digit number printed on the sensor applicator.",
                comment: "Pairing failure reason for a malformed G7 pairing code"
            )))
            return
        }
        self.pairingCode = code
        expectedSerial = serial
        excludedPeripheralIdentifier = excluded

        #if targetEnvironment(simulator)
        startSimulatedRun()
        #else
        let manager = borrowedBluetoothManager ?? G7BluetoothManager()
        if manager === borrowedBluetoothManager {
            previousDelegate = manager.delegate
            previousActiveIdentifier = manager.activePeripheralIdentifier
            // Whatever the session was following is not what we are pairing,
            // and the central only scans while it has no active peripheral:
            // with one still held, disconnecting alone left it neither
            // retrieving nor scanning, and every re-pair "found no sensor".
            manager.disconnectAll()
            manager.forgetPeripheral()
        }
        manager.delegate = self
        manager.setActivePeripheralIdentifier(nil)
        bluetoothManager = manager

        scanStartedAt = Date()
        setState(.running(candidates: []))
        onBluetoothStateChange?(manager.centralState)
        manager.scanForPeripheral()

        // Only a run that has never heard a sensor at all gives up. Once one
        // has been found, the screen shows what happened to it and the scan
        // keeps going until the user stops it: the sensor that will pair may
        // be one that has not advertised yet.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, case .running(let candidates) = self.state, candidates.isEmpty else {
                return
            }
            self.fail(LocalizedString(
                "No sensor was found in 20 minutes. Make sure the sensor is inserted and within range, and that no other phone or app is using it.",
                comment: "Pairing failure reason when the scan for a G7 sensor times out"
            ))
        }
        scanWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + G7PairingService.scanTimeout, execute: watchdog)
        #endif
    }

    public func cancel() {
        scanWatchdog?.cancel()
        scanWatchdog = nil
        candidateWatchdog?.cancel()
        candidateWatchdog = nil
        authenticationWatchdog?.cancel()
        authenticationWatchdog = nil
        authenticationGeneration += 1
        authenticationInFlight = false

        releaseBluetoothManager()
        planner = G7PairingPlanner()
        ruledOutIdentifiers.value = []
        skippedBySerial.value = []
        expectedSerial = nil
        excludedPeripheralIdentifier = nil
        setState(.idle)
    }

    /// Lets go of the central after a run that did not hand off: a borrowed
    /// one goes back to the session (which resumes on its next scan), an
    /// owned one is dropped. Either way every candidate is disconnected.
    private func releaseBluetoothManager() {
        guard let manager = bluetoothManager else {
            return
        }
        manager.disconnectAll()
        if manager === borrowedBluetoothManager {
            // Hand the central back to the session and re-arm it on its own
            // sensor; otherwise readings stop until something else prompts a
            // scan.
            manager.delegate = previousDelegate
            manager.setActivePeripheralIdentifier(previousActiveIdentifier)
            manager.scanForPeripheral()
        } else {
            manager.delegate = nil
        }
        bluetoothManager = nil
        authenticatedPeripheralManager = nil
        readyManagers.removeAll()
        scanStartedAt = nil
    }

    private func fail(_ reason: String) {
        setState(.failed(reason: reason))
        releaseBluetoothManager()
    }

    // MARK: - Simulator

    #if targetEnvironment(simulator)
    /// CoreBluetooth reports `.unsupported` in the simulator. Walk the same
    /// states with a stand-in sensor so onboarding can be exercised.
    private func startSimulatedRun() {
        scanStartedAt = Date()
        setState(.running(candidates: []))
        // The stand-in's model follows the code's last digit, so the art for
        // all three products can be walked without owning all three: 0 and 3
        // a G7, 1 and 4 a ONE+, 2 and 5 a Stelo.
        let models = G7SensorModel.allCases
        let model = models[(pairingCode.last?.wholeNumberValue ?? 0) % models.count]
        let name = model.advertisedPrefix + pairingCode.suffix(2)
        let authenticate = DispatchWorkItem { [weak self] in
            guard let self = self, !self.state.isFinished else { return }
            // A stand-in ruled-out sensor too: the screen's job is to show
            // both outcomes, so both have to be walkable without hardware.
            self.planner.addCandidate(id: UUID(), name: "DX0299", isPhoneSlotHeld: true)
            _ = self.planner.ruleOutCurrent(.inUseElsewhere)
            self.planner.addCandidate(id: UUID(), name: name, isPhoneSlotHeld: false)
            self.planner.beginAttempt()
            self.publishProgress()
            let succeed = DispatchWorkItem { [weak self] in
                guard let self = self, !self.state.isFinished else { return }
                self.planner.markCurrentPaired()
                self.publishProgress()
                self.setState(.succeeded(
                    peripheralIdentifier: UUID(),
                    sharedKey: G7JPAKE.secureRandomBytes(16),
                    deviceName: "Dexcom" + self.pairingCode.suffix(2)
                ))
            }
            self.scanWatchdog = succeed
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: succeed)
        }
        scanWatchdog = authenticate
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: authenticate)
    }
    #endif

    // MARK: - Candidate handling

    private func armCandidateWatchdog() {
        guard candidateWatchdog == nil,
              !authenticationInFlight,
              let candidate = planner.currentCandidate,
              readyManagers[candidate.id] == nil
        else {
            return
        }
        if planner.markConnecting() {
            publishProgress()
        }

        let id = candidate.id
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.candidateWatchdog = nil
            guard self.isRunActive,
                  !self.authenticationInFlight,
                  self.planner.currentCandidate?.id == id,
                  self.readyManagers[id] == nil
            else {
                return
            }
            self.log.default("Candidate %{public}@ did not become ready in time", id.uuidString)
            self.report("Candidate \(candidate.name) did not connect in time")
            self.handleCandidateFailure()
        }
        candidateWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + G7PairingService.candidateTimeout, execute: watchdog)
    }

    private func cancelCandidateWatchdog() {
        candidateWatchdog?.cancel()
        candidateWatchdog = nil
    }

    private func authenticateCurrentCandidate() {
        guard isRunActive,
              !authenticationInFlight,
              let candidate = planner.currentCandidate,
              let peripheralManager = readyManagers[candidate.id]
        else {
            return
        }

        authenticationInFlight = true
        let attempt = planner.beginAttempt()
        publishProgress()
        report("Trying \(candidate.name), attempt \(attempt)")

        cancelCandidateWatchdog()
        authenticationWatchdog?.cancel()
        authenticationGeneration += 1
        let generation = authenticationGeneration

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.authenticationWatchdog = nil
            guard self.isRunActive,
                  self.authenticationInFlight,
                  generation == self.authenticationGeneration,
                  self.planner.currentCandidate?.id == candidate.id
            else {
                return
            }
            self.report("\(candidate.name) attempt \(attempt) exceeded the time limit")
            self.authenticationGeneration += 1
            self.authenticationInFlight = false
            self.readyManagers.removeValue(forKey: candidate.id)
            self.bluetoothManager?.disconnectAll()
            self.handleCandidateFailure()
        }
        authenticationWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + G7PairingService.authenticationTimeout, execute: watchdog)

        let authenticator = G7Authenticator(
            pairingCode: pairingCode,
            storedSharedKey: nil,
            stepTimeout: G7Authenticator.pairingStepTimeout,
            displayType: displayType
        )
        authenticator.logHandler = { [weak self] message in
            self?.onMain { self?.onLog?(message) }
        }

        authenticator.authenticate(peripheralManager: peripheralManager) { [weak self] result in
            self?.onMain {
                guard let self = self, self.isRunActive, generation == self.authenticationGeneration else {
                    return
                }
                self.authenticationWatchdog?.cancel()
                self.authenticationWatchdog = nil
                self.authenticationInFlight = false

                switch result {
                case .success(let authResult):
                    // The connection stays up for the session to adopt; only
                    // the other candidates are let go. Terminal state first,
                    // so their disconnects are not scored as failures.
                    self.authenticatedPeripheralManager = peripheralManager
                    self.planner.markCurrentPaired()
                    self.publishProgress()
                    self.setState(.succeeded(
                        peripheralIdentifier: candidate.id,
                        sharedKey: authResult.sharedKey,
                        deviceName: authResult.deviceName
                    ))
                    self.bluetoothManager?.adoptAsActive(peripheralManager)
                case .failure(let error):
                    self.report("\(candidate.name) attempt \(attempt) failed: \(error)")
                    self.handleCandidateFailure(error: error)
                }
            }
        }
    }

    /// Why this candidate is out of the running for good, or nil for an
    /// ordinary failure that another attempt might get past.
    private func ruleOutReason(for error: Error?) -> G7PairingRuleOutReason? {
        guard let error = error as? G7AuthenticatorError else {
            return nil
        }
        switch error {
        case .challengeMismatch:
            // Our own verification failing, not the sensor's verdict: it
            // answered, and the answer was not one our key produces. A busy
            // sensor answers exactly the same way, which is what
            // `settledReason` is for.
            return .wrongPairingCode
        case .rejected(_, let failureCode):
            // The sensor refusing outright, with a reason. Never yet seen on
            // the air: across every capture, a sensor that will not take us
            // answers the challenge and lets our own check fail rather than
            // sending a verdict of `authStatus == 0x2`. Kept because the
            // protocol defines it and a refusal we did not handle would be
            // retried straight into the lockout.
            switch failureCode {
            case .challengeMismatch?:
                return .wrongPairingCode
            case .deviceTypeRestriction?:
                return .inUseElsewhere
            default:
                return .refused
            }
        case .timeout, .unexpectedResponse, .noCredentials:
            return nil
        }
    }

    /// Second-guesses a verdict of "wrong code" against what the sensor was
    /// saying before we connected.
    ///
    /// A sensor whose display slot is already taken completes the key
    /// exchange and then answers the challenge with something our key did not
    /// produce — byte for byte what a sensor belonging to a different code
    /// does. This is measured, not assumed. A capture of a pairing run
    /// against a sensor the Dexcom app was holding, with the right code
    /// entered, has both exchanges on one link three and a half seconds
    /// apart: the app's `02` request answered and verified through to
    /// `05 01 01`, then ours answered with something that did not verify.
    /// iOS gives both apps the same connection, so there is no doubt it is
    /// the same sensor in the same state.
    ///
    /// The explanation that fits is a key per display slot: the slot's key
    /// belongs to whoever holds it, so the sensor answers our nonce under a
    /// key we were never given. "Does not match our key" is then literally
    /// true and says nothing whatever about the code that was typed.
    ///
    /// So the handshake cannot tell the two apart and no amount of care with
    /// it will. The advertisement can, and of the two, telling someone the
    /// code they just read off the applicator is wrong is much the worse one
    /// to get wrong.
    private func settledReason(_ reason: G7PairingRuleOutReason) -> G7PairingRuleOutReason {
        guard reason == .wrongPairingCode,
              planner.currentCandidate?.wasHeldByAnotherDisplay == true
        else {
            return reason
        }
        return .inUseElsewhere
    }

    /// Republishes which sensors the scan turns away.
    ///
    /// A ruled-out sensor's advertisements are ignored: reconnecting to it
    /// costs the next candidate its turn, and a fourth rejection would put it
    /// into a connection-refusing cooldown. Re-admitting one takes it off the
    /// list again, so this is read from the planner rather than accumulated.
    private func syncRuledOutIdentifiers() {
        ruledOutIdentifiers.value = Set(planner.candidates.filter { $0.status.ruleOutReason != nil }.map(\.id))
    }

    private func handleCandidateFailure(error: Error? = nil) {
        // Whatever happens next starts its own connect deadline; a leftover
        // one would only be in the way of arming it.
        cancelCandidateWatchdog()

        let candidateID = planner.currentCandidate?.id
        let action: G7PairingPlanner.Action
        if let reason = ruleOutReason(for: error) {
            action = planner.ruleOutCurrent(settledReason(reason))
        } else {
            action = planner.recordFailure()
        }
        if let candidate = planner.candidates.first(where: { $0.id == candidateID }),
           let reason = candidate.status.ruleOutReason {
            report("\(candidate.name) ruled out: \(reason.localizedDescription)")
        }
        syncRuledOutIdentifiers()
        publishProgress()

        switch action {
        case .retryCurrent:
            guard let candidate = planner.currentCandidate,
                  let peripheralManager = readyManagers[candidate.id]
            else {
                bluetoothManager?.disconnectAll()
                bluetoothManager?.scanForPeripheral()
                armCandidateWatchdog()
                return
            }
            if peripheralManager.peripheral.state == .connected {
                authenticateCurrentCandidate()
            } else {
                readyManagers.removeValue(forKey: candidate.id)
                bluetoothManager?.disconnectAll()
                bluetoothManager?.scanForPeripheral()
                armCandidateWatchdog()
            }

        case .advanceToNext:
            if planner.currentCandidate.flatMap({ readyManagers[$0.id] }) != nil {
                authenticateCurrentCandidate()
            } else {
                bluetoothManager?.scanForPeripheral()
                armCandidateWatchdog()
            }

        case .waitForNewCandidates:
            // Nothing left that can pair, which is not the end of the run: the
            // sensor being paired may simply not have advertised yet. One that
            // a display used in the last ~15 minutes only speaks up for about
            // two seconds around each 5-minute reading.
            report("Every sensor found so far is ruled out; still looking")
            bluetoothManager?.disconnectAll()
            readyManagers.removeAll()
            bluetoothManager?.scanForPeripheral()
        }

        // The rule-out just made may have been the last thing standing
        // between the run and a sensor that is only ever going to say it is
        // busy.
        failIfHeldSlotBlocksTheRun()
    }

    /// Ends a run that cannot go anywhere: everything found has been ruled
    /// out and the one sensor that never rejected the code keeps advertising
    /// its display slot as taken. Waiting cannot free it, because whatever
    /// holds it is connecting often enough to keep renewing the lease, so
    /// the user is told what to go and stop rather than left watching a
    /// timer run out.
    private func failIfHeldSlotBlocksTheRun() {
        guard isRunActive else {
            return
        }

        // Before believing the advertisement, ask the sensor. It has said its
        // slot is taken for longer than a lease can last, so if that is still
        // true it will refuse us, and if it is not we pair.
        if planner.admitBlockerForFinalAttempt() {
            if let candidate = planner.currentCandidate {
                report("\(candidate.name) has said its slot is taken past any lease; trying it once more before giving up")
            }
            syncRuledOutIdentifiers()
            publishProgress()
            bluetoothManager?.scanForPeripheral()
            armCandidateWatchdog()
            return
        }

        guard let blocker = planner.heldSlotBlocker else {
            return
        }
        report("\(blocker.name) would not pair on a last attempt, with its display slot still taken; giving up")
        fail(String(
            format: LocalizedString(
                "%1$@ says another display is connected to it, and no other sensor here took this code. Stop the Dexcom app from using it: delete it, turn off its Bluetooth, or force quit it. Then try again.",
                comment: "Pairing failure reason when the only remaining sensor keeps advertising its display slot as taken (1: sensor name)"
            ),
            blocker.name
        ))
    }

    private func report(_ message: String) {
        log.default("%{public}@", message)
        onLog?(message)
    }
}

extension G7PairingService: G7BluetoothManagerDelegate {

    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any]) -> PeripheralConnectionCommand {
        // A finished run must never connect again: the sensor it just paired
        // belongs to the session manager now.
        guard !state.isFinished,
              let advertisement = G7Advertisement(peripheral: peripheral, advertisementData: advertisementData),
              advertisement.isSupportedSensor
        else {
            return .ignore
        }

        if peripheral.identifier == excludedPeripheralIdentifier {
            return .ignore
        }

        if let serial = expectedSerial, !advertisement.couldHaveSerial(serial) {
            // Once per sensor, not once per advertisement: a sensor with a
            // free slot advertises continuously, and the log is the only
            // record of what the serial filter turned away.
            var isFirstSighting = false
            _ = skippedBySerial.mutate { skipped in
                isFirstSighting = skipped.insert(peripheral.identifier).inserted
            }
            if isFirstSighting {
                onMain { [weak self] in
                    self?.report("Skipping \(advertisement.name): it cannot be the sensor with the scanned serial")
                }
            }
            return .ignore
        }

        let id = peripheral.identifier
        // A ruled-out sensor is still listened to, just never connected to
        // again: what its advertisement says about its display slot is the
        // only explanation a stuck run has to offer.
        let isRuledOut = ruledOutIdentifiers.value.contains(id)

        onMain { [weak self] in
            guard let self = self, self.isRunActive else { return }
            // Nil means the packet did not carry the types-in-use byte. It
            // stands in for free only at discovery, where it decides nothing
            // but the order candidates are tried in; from then on an
            // unreadable advertisement says nothing and changes nothing.
            let slot = advertisement.isSlotHeld(for: displayType)
            let isHeld = slot ?? false
            if self.planner.addCandidate(id: id, name: advertisement.name, isPhoneSlotHeld: isHeld) {
                self.report(isHeld
                    ? "Found \(advertisement.name); another phone connected recently, so trying others first"
                    : "Found \(advertisement.name)")
                self.planner.recordAdvertisement(id: id, isPhoneSlotHeld: slot)
                self.publishProgress()
            } else {
                let before = self.planner.candidates.first { $0.id == id }
                if self.planner.recordAdvertisement(id: id, isPhoneSlotHeld: slot) {
                    let after = self.planner.candidates.first { $0.id == id }
                    if let after = after, after.readmissions != before?.readmissions {
                        self.report("\(advertisement.name) says its slot is free again; giving it another turn (\(after.readmissions) of \(G7PairingPlanner.maximumReadmissions))")
                        // It is no longer turned away at the door, so the
                        // next advertisement from it is connected to.
                        self.syncRuledOutIdentifiers()
                    } else if let slot = slot, before?.isPhoneSlotHeld != slot {
                        self.report("\(advertisement.name) slot is now \(slot ? "held" : "free")")
                    }
                    self.publishProgress()
                }
            }
            if !isRuledOut {
                self.armCandidateWatchdog()
            }
            self.failIfHeldSlotBlocksTheRun()
        }
        return isRuledOut ? .ignore : .connect
    }

    func bluetoothManagerShouldAcceptRestoredPeripherals(_ manager: G7BluetoothManager) -> Bool {
        // A stale restored peripheral would masquerade as a candidate.
        return false
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool {
        let id = peripheralManager.peripheral.identifier
        onMain { [weak self] in
            guard let self = self, self.isRunActive else { return }
            self.readyManagers[id] = peripheralManager
            if self.planner.currentCandidate?.id == id {
                self.authenticateCurrentCandidate()
            }
        }
        // Keep scanning: other candidates may still be in range.
        return false
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error) {
        log.default("Candidate connection failed: %{public}@", String(describing: error))
        onMain { [weak self] in
            guard let self = self, self.isRunActive, !self.authenticationInFlight else { return }
            // Reported, because this spends one of the sensor's attempts. An
            // unreported one turns the log into "attempt 1" followed by
            // "attempt 3", with nothing to say where 2 went.
            if let candidate = self.planner.currentCandidate {
                self.report("\(candidate.name) could not be connected: \(error)")
            }
            self.handleCandidateFailure()
        }
    }

    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool) {
        let id = peripheralManager.peripheral.identifier
        onMain { [weak self] in
            guard let self = self, self.isRunActive, self.planner.currentCandidate?.id == id else { return }
            self.readyManagers.removeValue(forKey: id)
            if self.authenticationInFlight {
                // The sensor drops the link itself a few seconds after the
                // bond request, with the handshake complete and the key
                // installed; the authenticator reports that as success once
                // it notices. Its verdict decides, not the disconnect. A drop
                // earlier in the handshake ends in its step timeout instead.
                self.report("Link dropped during the handshake; waiting for the handshake's verdict")
                return
            }
            if let candidate = self.planner.currentCandidate {
                self.report("\(candidate.name) dropped the link before the handshake")
            }
            self.handleCandidateFailure()
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data) {}

    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data) {}

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data) {}

    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager) {
        // Off the manager's queue: `isScanning` syncs onto it.
        onMain { [weak self] in
            guard let self = self, self.isRunActive else { return }
            self.report(manager.isScanning ? "Scanning for sensors" : "Stopped scanning")
            self.onBluetoothStateChange?(manager.centralState)
        }
    }
}
