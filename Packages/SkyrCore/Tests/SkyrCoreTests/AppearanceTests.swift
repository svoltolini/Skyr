import SwiftUI
import Testing
@testable import SkyrCore

@Test func appearanceSegmentsReadLightDarkAutomatic() {
    #expect(Appearance.allCases.map(\.title) == ["Light", "Dark", "Automatic"])
}

@Test func appearanceKeepsStoredValuesWhileRenamingAutomatic() {
    #expect(Appearance.auto.rawValue == "Auto")
    #expect(Appearance(rawValue: "Auto") == .auto)
    #expect(Appearance.light.title == Appearance.light.rawValue)
    #expect(Appearance.dark.title == Appearance.dark.rawValue)
}

@Test func appearanceResolvesColorScheme() {
    #expect(Appearance.light.colorScheme == ColorScheme.light)
    #expect(Appearance.dark.colorScheme == ColorScheme.dark)
    #expect(Appearance.auto.colorScheme == nil)
}
