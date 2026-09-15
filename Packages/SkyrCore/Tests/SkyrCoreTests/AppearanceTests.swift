import Testing
@testable import SkyrCore

@Test func appearanceTitlesMatchSettingsCopy() {
    #expect(Appearance.light.title == "Light")
    #expect(Appearance.dark.title == "Dark")
    #expect(Appearance.auto.title == "Automatic")
    #expect(Appearance.allCases.map(\.title) == ["Light", "Dark", "Automatic"])
}

@Test func appearanceColorSchemeMatchesSelection() {
    #expect(Appearance.light.colorScheme == .light)
    #expect(Appearance.dark.colorScheme == .dark)
    #expect(Appearance.auto.colorScheme == nil)
}
