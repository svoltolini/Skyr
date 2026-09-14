import SkyrCore
import SwiftUI

/// Recent app events, for reporting problems.
struct DiagnosticsView: View {
    @Environment(PlayerModel.self) private var player
    private var log: DiagnosticsLog { DiagnosticsLog.shared }

    private static var buildText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        List {
            LabeledContent("Build", value: Self.buildText)
            if log.entries.isEmpty {
                Text("Nothing recorded yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.message)
                        .font(.footnote)
                        .selectableText()
                }
                .padding(.vertical, 2)
            }
        }
        .groupedList()
        .hiddenScrollBackground()
        .skyrBackground(player.tint)
        .navigationTitle("Diagnostics")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Copy", systemImage: "doc.on.doc") {
                    Clipboard.copy(log.text)
                }
            }
            ToolbarItem(placement: .trailingBar) {
                Button("Clear", systemImage: "trash", role: .destructive) {
                    log.clear()
                }
            }
        }
    }
}
