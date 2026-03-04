import SwiftUI

struct StatusBarView: View {
    let connectionStatus: AppState.ConnectionStatus
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(connectionStatus.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(isRecording ? "Recording" : "Idle")
                .font(.caption)
                .foregroundStyle(isRecording ? .red : .secondary)
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private var statusColor: Color {
        switch connectionStatus {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        }
    }
}
