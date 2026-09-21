//
//  G7DexcomAppWarningView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

/// Shown before pairing when a Dexcom app is installed.
///
/// A sensor admits one display at a time and the Dexcom app will keep trying
/// to be it, so it has to stop reaching the sensor before pairing. Deleting
/// it is the surest way and not the only one, and it is not this screen's
/// place to insist: someone may want the app's history, or may be pairing a
/// second sensor while the first still belongs to the app.
///
/// Three things the copy has to keep doing: say what to do before why, give
/// each way out its own block so none of it reads as a paragraph to wade
/// through, and stay in primary text. Grey on white is the first thing to
/// go unread, and this screen is the one that decides whether pairing works
/// at all.
struct G7DexcomAppWarningView: View {
    /// Whether the sensor being paired is one the Dexcom app has been
    /// connected to (an eavesdropping session moving to direct). That is
    /// when the sensor's 15-minute display lease matters, and when readings
    /// stop until pairing completes.
    var isReplacingDexcomAppSession: Bool

    /// Re-checks whether the app is still installed, so leaving to delete it
    /// and coming back is reflected here.
    var isDexcomAppInstalled: () -> Bool
    var didContinue: () -> Void

    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @State private var isInstalled = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(guidanceColors.warning)
                        Text(String(format: LocalizedString("Stop the %@ App", comment: "Title of the Dexcom app warning shown before pairing (1: app name, e.g. Dexcom G7 or Stelo)"), G7DexcomApp.installedAppNames))
                            .font(.title2)
                            .fontWeight(.semibold)
                    }

                    Text(String(format: LocalizedString("A sensor works with only one app at a time. The %1$@ app has to stop using this sensor before %2$@ can pair with it.", comment: "First paragraph of the Dexcom app warning (1: Dexcom app name, 2: appName)"), G7DexcomApp.installedAppNames, appName))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedString("Do any one of these:", comment: "Lead-in to the list of ways to stop the Dexcom app"))
                        .font(.headline)
                        .padding(.top, 2)

                    option(
                        number: 1,
                        symbol: "trash",
                        title: LocalizedString("Delete the app", comment: "Title of the option to delete the Dexcom app"),
                        detail: LocalizedString("The surest way. Your readings stay in the Dexcom cloud.", comment: "Detail of the option to delete the Dexcom app")
                    )
                    orSeparator
                    option(
                        number: 2,
                        symbol: "dot.radiowaves.left.and.right",
                        title: LocalizedString("Turn off its Bluetooth", comment: "Title of the option to revoke the Dexcom app's Bluetooth permission"),
                        detail: LocalizedString("In Settings › Privacy & Security › Bluetooth. The app keeps its history.", comment: "Detail of the option to revoke the Dexcom app's Bluetooth permission")
                    )
                    orSeparator
                    option(
                        number: 3,
                        symbol: "xmark.app",
                        title: LocalizedString("Force quit it", comment: "Title of the option to force quit the Dexcom app"),
                        detail: LocalizedString("Swipe it away in the app switcher. Opening it again undoes this.", comment: "Detail of the option to force quit the Dexcom app")
                    )

                    tail
                        .padding(.top, 2)
                }
                .padding()
            }

            Button(action: didContinue) {
                Text(LocalizedString("Continue", comment: "Button title for starting setup"))
                    .actionButtonStyle(.primary)
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear { isInstalled = isDexcomAppInstalled() }
    }

    /// What is left to know once the user has picked a way: how long the
    /// sensor stays loyal to the app that had it, and what to have ready.
    ///
    /// Only an eavesdropping session tells us the Dexcom app has had this
    /// sensor. Everywhere else the sensor may be fresh out of the box or may
    /// have been on the user's arm for days with the Dexcom app reading it,
    /// and we cannot tell which, so the wait is stated as the condition it
    /// is rather than asserted either way.
    private var tail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isReplacingDexcomAppSession {
                Text(LocalizedString("This sensor has been used by the Dexcom app. Wait about 15 minutes after it last connected, then pair.", comment: "Dexcom app warning: lease wait when moving an existing session"))
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedString("You need the 4-digit code from this sensor's applicator.", comment: "Dexcom app warning: reminder that the code for the current sensor is needed"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(LocalizedString("If the Dexcom app has used the sensor you are pairing, wait about 15 minutes after it last connected. A sensor it has never used can be paired right away.", comment: "Dexcom app warning: the lease wait applies only if the Dexcom app has used this sensor"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Deleting the app does not hand the sensor back: the lease it
            // holds runs on the sensor's own clock, so the wait above still
            // stands and this only confirms the app is gone.
            if !isInstalled {
                Label(
                    String(format: LocalizedString("The %@ app is gone.", comment: "Message once the Dexcom app has been removed (1: app name)"), G7DexcomApp.installedAppNames),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var orSeparator: some View {
        Text(LocalizedString("OR", comment: "Separator between the ways to stop the Dexcom app"))
            .font(.footnote.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func option(number: Int, symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundColor(.accentColor)
                Text(String(format: LocalizedString("OPTION %d", comment: "Label numbering a way to stop the Dexcom app (1: number)"), number))
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
            }

            Text(title)
                .font(.headline)

            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
