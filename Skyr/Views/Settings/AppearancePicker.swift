import SkyrCore
import SwiftUI

/// Light, Dark and Automatic as a segmented control. Accessibility text sizes stack the
/// choices so Dynamic Type is not clipped by a three-segment row.
struct AppearancePicker: View {
    @Binding var selection: Appearance
    var label = "Appearance"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedChoices
            } else {
                Picker(label, selection: $selection) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

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
}
