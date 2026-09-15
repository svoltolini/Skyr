import SkyrShared
import ActivityKit
import SwiftUI
import WidgetKit

/// Album or playlist download progress on the lock screen and in the Dynamic Island.
/// Tapping it opens Downloads; a now-playing island tap uses `skyr://nowplaying` instead.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 14) {
                DownloadRing(state: context.state, size: 44, lineWidth: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.statusLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.11, green: 0.106, blue: 0.102))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(WidgetLink.tab("downloads"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadRing(state: context.state, size: 40, lineWidth: 4)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.done) of \(context.state.total) saved")
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
                    Text(context.state.statusLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                DownloadRing(state: context.state, size: 18, lineWidth: 2.5)
            } minimal: {
                DownloadRing(state: context.state, size: 18, lineWidth: 2.5)
            }
            .keylineTint(.white)
            .widgetURL(WidgetLink.tab("downloads"))
        }
    }

}

/// Circular progress drawn with the same look as the button in the app.
private struct DownloadRing: View {
    let state: DownloadProgress
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, state.fraction)))
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if state.outcome != .downloading {
                Image(systemName: terminalSymbol)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.outcome == .downloading ? "Download \(Int((state.fraction * 100).rounded())) percent" : state.statusLine)
    }

    private var terminalSymbol: String {
        switch state.outcome {
        case .downloaded: "checkmark"
        case .cancelled: "stop.fill"
        case .failed, .partial: "exclamationmark"
        case .downloading: "arrow.down"
        }
    }
}
