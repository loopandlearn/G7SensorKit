//
//  G7EnterCodeView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import AVFoundation
import G7SensorKit
import SwiftUI

/// Collects the 4-digit pairing code, by typing or by scanning the
/// applicator's Data Matrix.
struct G7EnterCodeView: View {
    var didEnterCode: (_ code: String, _ serial: String?) -> Void

    @State private var code = ""
    /// The code and serial from a scanned applicator. The serial only rides
    /// along while the code still matches what was scanned: it belongs to that
    /// applicator,
    /// not to whatever gets typed afterwards.
    @State private var scannedCode: String?
    @State private var scannedSerial: String?
    @State private var showingScanner = false
    @State private var showingCameraDenied = false
    @State private var scanMessage: String?

    @FocusState private var codeFieldFocused: Bool

    private var isValid: Bool {
        G7PairingService.isValidPairingCode(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if G7PackageScannerView.isAvailable {
                Text(LocalizedString("Scan the barcode on the sensor applicator. It carries the pairing code and the sensor's serial number, so pairing can look for your sensor and pass over every other Dexcom sensor in range.", comment: "Instructions on the pairing code entry screen when the applicator can be scanned"))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)

                Button(action: scanTapped) {
                    Label(LocalizedString("Scan Applicator", comment: "Button title to scan the applicator barcode"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                manualEntryDivider
            } else {
                Text(LocalizedString("Enter the 4-digit pairing code printed on the sensor applicator.", comment: "Instructions on the pairing code entry screen when the applicator cannot be scanned"))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
            }

            ZStack {
                TextField("", text: $code)
                    .focused($codeFieldFocused)
                    .keyboardType(.numberPad)
                    .disableAutocorrection(true)
                    .foregroundColor(.clear)
                    .accentColor(.clear)
                    .opacity(0.02)
                    .onChange(of: code) { _, newValue in
                        // Sanitising re-enters this handler, so wait for
                        // the second pass before acting on the code.
                        let trimmed = String(newValue.filter(\.isNumber).prefix(4))
                        guard trimmed == newValue else {
                            code = trimmed
                            return
                        }
                        if trimmed != scannedCode {
                            scannedSerial = nil
                        }
                        autoSubmitIfComplete()
                    }
                
                HStack(spacing: 14) {
                    ForEach(0 ..< 4, id: \.self) { index in
                        let characters = Array(code)
                        let character = index < characters.count ? String(characters[index]) : ""
                        let isActive = index == characters.count

                        Text(character)
                            .font(.title.weight(.semibold).monospaced())
                            .frame(width: 68, height: 68)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: isActive ? 2 : 0)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            .frame(height: 68)
            .contentShape(Rectangle())
            .onTapGesture { codeFieldFocused = true }

            if let scanMessage = scanMessage {
                Text(scanMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(LocalizedString("There is nothing to do in the Dexcom app first; the sensor is ready to pair as soon as it is on.", comment: "Reminder on the code entry screen that the Dexcom app is not involved"))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: { didEnterCode(code, scannedSerial) }) {
                Text(LocalizedString("Continue", comment: "Button title for starting setup"))
                    .actionButtonStyle(.primary)
            }
            .disabled(!isValid)
        }
        .padding()
        // No tap-to-dismiss over the whole screen: it fought the boxes' own
        // tap gesture, so one tap could set focus and clear it.
        // The keyboard stays down while scanning is on offer: raising it would
        // bury the scan button and answer the question for the user.
        .onAppear { codeFieldFocused = !G7PackageScannerView.isAvailable }
        .sheet(isPresented: $showingScanner) {
            NavigationView {
                G7PackageScannerView { package in
                    showingScanner = false
                    handleScannedPackage(package)
                }
                .navigationBarTitle(Text(LocalizedString("Scan Applicator", comment: "Navigation title of the applicator scanner")), displayMode: .inline)
                .navigationBarItems(trailing: Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup")) {
                    showingScanner = false
                })
            }
        }
        .alert(
            LocalizedString("Camera Access Is Off", comment: "Title of the alert shown when camera permission is denied"),
            isPresented: $showingCameraDenied
        ) {
            Button(LocalizedString("Open Settings", comment: "Button title to open the iOS Settings app")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"), role: .cancel) {}
        } message: {
            Text(LocalizedString("Allow camera access in Settings to scan the code on the applicator, or type the 4 digits instead.", comment: "Message of the alert shown when camera permission is denied"))
        }
    }

    /// Typing the code stays available, one step down from scanning it.
    private var manualEntryDivider: some View {
        HStack(spacing: 12) {
            line
            Text(LocalizedString("or enter it by hand", comment: "Separator between scanning the applicator and typing the pairing code"))
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize()
            line
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
    }

    /// Complete codes submit themselves, typed or scanned: with the boxes
    /// full there is nothing left to enter and the number pad has no return
    /// key to dismiss it. The delay lets the last box fill and the keyboard
    /// finish leaving, so its dismissal does not overlap the next push.
    private func autoSubmitIfComplete() {
        guard isValid, codeFieldFocused else { return }

        codeFieldFocused = false
        let submitted = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard code == submitted else { return }
            didEnterCode(submitted, scannedSerial)
        }
    }

    /// The scanner shows a blank view without camera access, so ask first.
    private func scanTapped() {
        codeFieldFocused = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showingScanner = true
                    } else {
                        showingCameraDenied = true
                    }
                }
            }
        default:
            showingCameraDenied = true
        }
    }

    private func handleScannedPackage(_ package: G7SensorPackage) {
        guard let pairingCode = package.pairingCode else {
            scanMessage = package.isDexcom
                ? LocalizedString("That barcode has no pairing code. Enter the code from the applicator instead.", comment: "Message after scanning a Dexcom barcode without a pairing code")
                : LocalizedString("That doesn't look like a Dexcom applicator.", comment: "Message after scanning a non-Dexcom barcode")
            return
        }
        scannedCode = pairingCode
        scannedSerial = package.serial
        code = pairingCode
        scanMessage = package.serial.map { serial in
            String(format: LocalizedString("Scanned sensor %@", comment: "Message after a successful package scan (1: serial number)"), serial)
        }
    }
}
