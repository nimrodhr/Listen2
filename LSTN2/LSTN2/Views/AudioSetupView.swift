import SwiftUI

struct AudioSetupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BlackHole Setup Required")
                .font(.headline)

            Text("Install and route system audio through BlackHole to enable dual-channel transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Open BlackHole Download") {
                if let url = URL(string: "https://existential.audio/blackhole/") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding()
        .frame(width: 420)
    }
}
