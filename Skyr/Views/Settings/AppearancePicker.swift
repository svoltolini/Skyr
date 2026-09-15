import SkyrCore
import SwiftUI

/// Light, Dark and Automatic as a segmented control. Accessibility text sizes stack the
/// choices so Dynamic Type is not clipped by a three-segment row. The television keeps the
/// system segmented control so the remote can focus each option.
struct AppearancePicker: View {
    @Binding var selection: Appearance
    var label = "Appearance"
    #if !os(tvOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        Group {
            #if os(tvOS)
            segmented
            #else
            if dynamicTypeSize.isAccessibilitySize {
                stackedChoices
            } else {
                segmented
            }
            #endif
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var segmented: some View {
        Picker(label, selection: $selection) {
            ForEach(Appearance.allCases) { appearance in
                Text(appearance.title).tag(appearance)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    #if !os(tvOS)
    /// Full-width rows stay readable when a segmented control would truncate.
    private var stackedChoices: some View {
        VStack(spacing: 0) {
            ForEach(Appearance.allCases) { appearance in
                if appearance != Appearance.allCases.first {
                    Divider()
                }
                Button {
                    selection = appearance
                } label: {
                    HStack {
                        Text(appearance.title)
                        Spacer(minLength: 12)
                        if selection == appearance {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == appearance ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
    #endif
}
