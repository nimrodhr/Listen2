import SwiftUI
import UniformTypeIdentifiers

struct QuestionListView: View {
    let questions: [AppState.QuestionCard]
    let onDismiss: (UUID) -> Void
    let onClear: () -> Void

    @State private var showClearConfirmation = false

    /// Questions that have been answered (used for CSV export).
    private var answeredQuestions: [AppState.QuestionCard] {
        questions.filter {
            if case .answered = $0.state { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Label("Q&A", systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !questions.isEmpty {
                    Text("\(questions.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }

                Spacer()

                if !questions.isEmpty {
                    // Export answered Q&A to CSV
                    Button {
                        exportAnsweredCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export answered Q&A to CSV")
                    .disabled(answeredQuestions.isEmpty)

                    // Clear all questions
                    Button {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all questions")
                    .alert("Clear Q&A", isPresented: $showClearConfirmation) {
                        Button("Clear", role: .destructive) { onClear() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Remove all questions and answers? This cannot be undone.")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if questions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(questions) { question in
                            QuestionCardView(question: question) {
                                onDismiss(question.id)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - CSV Export

    private func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func exportAnsweredCSV() {
        let header = "Timestamp,Category,Question,Answer,Sources"
        let rows = answeredQuestions.map { card -> String in
            let timestamp = formatElapsed(card.elapsed)
            let category = card.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            let question = csvEscape(card.question)
            let answer: String
            if case let .answered(text) = card.state {
                answer = csvEscape(text)
            } else {
                answer = ""
            }
            let sources = card.sources.map { $0.fileName + ($0.page.map { " p.\($0)" } ?? "") }.joined(separator: "; ")
            return "\(timestamp),\(csvEscape(category)),\(question),\(answer),\(csvEscape(sources))"
        }
        let csv = ([header] + rows).joined(separator: "\n")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = formatter.string(from: Date())

        let panel = NSSavePanel()
        panel.title = "Export Q&A"
        panel.nameFieldStringValue = "questions_\(timestamp).csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    private func csvEscape(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"") || value.contains("\n")
        if needsQuoting {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("No questions detected")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Questions will appear here as they're identified")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct QuestionCardView: View {
    let question: AppState.QuestionCard
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top: timestamp + category + dismiss
            HStack(alignment: .top) {
                Text(timestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                categoryBadge

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // Question text
            Text(question.question)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            // Answer / loading state
            answerContent

            // Sources
            if !question.sources.isEmpty {
                sourceBadges
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private var timestamp: String {
        let total = Int(question.elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private var categoryBadge: some View {
        Text(question.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2.weight(.medium))
            .foregroundStyle(categoryColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(categoryColor.opacity(0.12))
            )
    }

    private var categoryColor: Color {
        switch question.category {
        case .factual: .blue
        case .opinion: .purple
        case .clarification: .orange
        case .actionItem: .green
        }
    }

    @ViewBuilder
    private var answerContent: some View {
        switch question.state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding answer...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .answered(answer):
            Text(answer)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
        case let .noAnswer(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private var sourceBadges: some View {
        FlowLayout(spacing: 4) {
            ForEach(question.sources) { source in
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 8))
                    Text(source.fileName + (source.page.map { " p.\($0)" } ?? ""))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .help(source.preview)
            }
        }
    }
}

// Simple horizontal flow layout for source badges
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
