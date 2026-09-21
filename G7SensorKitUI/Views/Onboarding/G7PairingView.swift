//
//  G7PairingView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

/// Narrates the pairing run: what has been found, which sensor is being
/// tried, and which ones are out of the running and why.
///
/// Pairing is not one opaque search. Spent applicators in a drawer and the
/// sensor on the arm all advertise, so the run works through them in turn and
/// the screen has to show that, or a perfectly healthy run looks stuck.
struct G7PairingView: View {
    @ObservedObject var viewModel: G7PairingViewModel
    var didEditCode: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    statusIcon
                        .frame(height: 80)
                        .padding(.top, 8)

                    status

                    if !viewModel.candidates.isEmpty {
                        candidateList
                    }

                    if viewModel.activeCandidate != nil {
                        Text(LocalizedString("If iOS asks to pair with the sensor, tap Pair.", comment: "Hint about the system Bluetooth pairing prompt during G7 pairing"))
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }

            buttons
                .padding([.horizontal, .bottom])
        }
        .navigationBarTitle(Text(LocalizedString("Pairing", comment: "Navigation title of the pairing progress screen")), displayMode: .inline)
        .navigationBarBackButtonHidden(viewModel.isWorking)
        .animation(.default, value: viewModel.candidates)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.state {
        case .idle, .running:
            ProgressView()
                .scaleEffect(2)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(guidanceColors.acceptable)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(guidanceColors.critical)
        }
    }

    private var status: some View {
        VStack(spacing: 10) {
            Text(viewModel.statusTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            if viewModel.isWorking, let startedAt = viewModel.scanStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(String(format: LocalizedString("Looking for %d:%02d", comment: "Elapsed scan time while pairing (1: minutes, 2: seconds)"), elapsed / 60, elapsed % 60))
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if let problem = viewModel.bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.critical)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let detail = viewModel.statusDetail {
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = viewModel.wrongCodeHint {
                Label(hint, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: LocalizedString("Sensors found (%d)", comment: "Header of the list of sensors discovered while pairing (1: count)"), viewModel.candidates.count))
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.leading, 4)

            ForEach(viewModel.candidates) { candidate in
                candidateRow(candidate)
            }
        }
    }

    private func candidateRow(_ candidate: G7PairingCandidate) -> some View {
        let isOut = candidate.status.ruleOutReason != nil

        return HStack(spacing: 12) {
            Group {
                if let model = candidate.model {
                    model.image
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .saturation(isOut ? 0 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.model?.displayName ?? candidate.name)
                    .font(.subheadline.weight(.medium))
                Text(String(
                    format: LocalizedString("%1$@ · %2$@", comment: "A discovered sensor's advertised name and its pairing status (1: name, 2: status)"),
                    candidate.name,
                    viewModel.detail(for: candidate)
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            trailingIndicator(candidate)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .opacity(isOut ? 0.6 : 1)
    }

    @ViewBuilder
    private func trailingIndicator(_ candidate: G7PairingCandidate) -> some View {
        switch candidate.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .connecting, .pairing:
            ProgressView()
        case .ruledOut:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
        case .paired:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(guidanceColors.acceptable)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if case .failed = viewModel.state {
            VStack(spacing: 10) {
                Button(action: { viewModel.retry() }) {
                    Text(LocalizedString("Try Again", comment: "Button title to retry pairing"))
                        .actionButtonStyle(.primary)
                }
                Button(action: didEditCode) {
                    Text(LocalizedString("Change Code", comment: "Button title to go back and edit the pairing code"))
                        .actionButtonStyle(.secondary)
                }
            }
        } else if viewModel.isWorking {
            Button(action: didEditCode) {
                Text(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"))
                    .actionButtonStyle(.secondary)
            }
        }
    }
}
