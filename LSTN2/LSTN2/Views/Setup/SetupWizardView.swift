import SwiftUI

struct SetupWizardView: View {
    let setupState: SetupState
    let setupManager: SetupManager
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)

                Text("Welcome to LSTN2")
                    .font(.title2.weight(.semibold))

                Text("Let's get everything set up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Step progress bar
            StepProgressBar(
                steps: SetupState.Step.allCases,
                currentStep: setupState.currentStep,
                statuses: setupState.stepStatuses
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            // Step content (scrollable, fixed height)
            ScrollView {
                Group {
                    switch setupState.currentStep {
                    case .environment:
                        EnvironmentStepView(state: setupState, manager: setupManager)
                    case .apiKey:
                        APIKeyStepView(state: setupState, manager: setupManager)
                    case .blackHole:
                        BlackHoleStepView(state: setupState, manager: setupManager)
                    case .audioConfig:
                        AudioConfigStepView(state: setupState)
                    }
                }
                .padding(24)
            }
            .frame(height: 360)

            Divider()

            // Navigation bar
            navigationBar
        }
        .frame(width: 370)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            if setupState.currentStep != SetupState.Step.allCases.first {
                Button("Back") {
                    goToPreviousStep()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            if isCurrentStepOptional && !isCurrentStepDone {
                Button(setupState.currentStep == .apiKey ? "Skip and add later" : "Skip") {
                    setupState.stepStatuses[setupState.currentStep] = .skipped
                    goToNextStep()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isLastStep {
                Button("Finish") {
                    SetupState.markSetupComplete()
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!setupState.isSetupComplete)
            } else {
                Button("Next") {
                    goToNextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isCurrentStepDone)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var isCurrentStepDone: Bool {
        let status = setupState.stepStatuses[setupState.currentStep]
        return status == .completed || status == .skipped
    }

    private var isCurrentStepOptional: Bool {
        [.apiKey, .blackHole, .audioConfig].contains(setupState.currentStep)
    }

    private var isLastStep: Bool {
        setupState.currentStep == SetupState.Step.allCases.last
    }

    private func goToNextStep() {
        let allSteps = SetupState.Step.allCases
        guard let currentIndex = allSteps.firstIndex(of: setupState.currentStep),
              currentIndex + 1 < allSteps.count else { return }
        setupState.currentStep = allSteps[currentIndex + 1]
    }

    private func goToPreviousStep() {
        let allSteps = SetupState.Step.allCases
        guard let currentIndex = allSteps.firstIndex(of: setupState.currentStep),
              currentIndex > 0 else { return }
        setupState.currentStep = allSteps[currentIndex - 1]
    }
}
