import SkyrShared
import ActivityKit
import SwiftUI
import WidgetKit

/// Album or playlist download progress on the lock screen and in the Dynamic Island.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 14) {
                DownloadRing(fraction: context.state.fraction, size: 44, lineWidth: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(statusLine(context.state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.11, green: 0.106, blue: 0.102))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadRing(fraction: context.state.fraction, size: 40, lineWidth: 4)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(min(context.state.done + 1, context.state.total)) of \(context.state.total)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(statusLine(context.state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                DownloadRing(fraction: context.state.fraction, size: 18, lineWidth: 2.5)
            } minimal: {
                DownloadRing(fraction: context.state.fraction, size: 18, lineWidth: 2.5)
            }
            .keylineTint(.white)
        }
    }

    private func statusLine(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.done >= state.total { return "Downloaded" }
        return state.currentTitle.isEmpty
            ? "Downloading \(state.done) of \(state.total) songs"
            : "Downloading \(state.done + 1) of \(state.total) · \(state.currentTitle)"
    }
}

/// Circular progress drawn with the same look as the button in the app.
private struct DownloadRing: View {
    let fraction: Double
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if fraction >= 1 {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Download \(Int((fraction * 100).rounded())) percent")
    }
}
