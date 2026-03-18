import SwiftUI

struct StepProgressBar: View {
    let steps: [SetupState.Step]
    let currentStep: SetupState.Step
    let statuses: [SetupState.Step: SetupState.StepStatus]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(fillColor(for: step))
                            .frame(width: 26, height: 26)

                        statusIcon(for: step)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(step.title)
                        .font(.system(size: 9))
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(width: 60)
                }

                if index < steps.count - 1 {
                    Rectangle()
                        .fill(connectorColor(after: step))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 18)
                }
            }
        }
    }

    private func fillColor(for step: SetupState.Step) -> Color {
        let status = statuses[step] ?? .pending
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .gray
        case .inProgress, .checking: return .accentColor
        case .pending: return step == currentStep ? .accentColor.opacity(0.6) : .gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private func statusIcon(for step: SetupState.Step) -> some View {
        let status = statuses[step] ?? .pending
        switch status {
        case .completed:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "xmark")
        case .skipped:
            Image(systemName: "forward.fill")
        case .inProgress, .checking:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        case .pending:
            Image(systemName: step.systemImage)
                .font(.system(size: 10))
        }
    }

    private func connectorColor(after step: SetupState.Step) -> Color {
        let status = statuses[step] ?? .pending
        return (status == .completed || status == .skipped) ? .green.opacity(0.5) : .gray.opacity(0.2)
    }
}
