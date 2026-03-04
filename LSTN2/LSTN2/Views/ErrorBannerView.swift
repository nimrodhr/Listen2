import SwiftUI

struct ErrorBannerView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)

            Text(message)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .overlay(
            Rectangle()
                .fill(Color.red)
                .frame(height: 2),
            alignment: .bottom
        )
    }
}
