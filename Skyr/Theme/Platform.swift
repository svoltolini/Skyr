import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformColor = NSColor
typealias PlatformView = NSView
#endif

// The shared screens are written once for iPhone and Mac. What differs between the two lives here,
// so a view never has to know which platform it is on.

/// The word for the device in copy: "iPhone", "iPad", "Mac" or "Apple TV".
enum Device {
    static let noun: String = {
        #if os(macOS)
        "Mac"
        #elseif os(tvOS)
        "Apple TV"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }()
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(tvOS)
        // No clipboard on a television.
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #elseif os(tvOS)
        _ = url
        #else
        UIPasteboard.general.url = url
        #endif
    }
}

#if os(tvOS)
/// The television has no pointer; hovering is a no-op there.
extension View {
    func onHover(perform action: @escaping (Bool) -> Void) -> some View { self }
}

/// Cover cards lift and cast a shadow under focus. The system's card style would draw a platter
/// behind the whole button, boxing in the title beneath the cover.
struct CoverFocusStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused && !reduceMotion ? 1.08 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 24, y: 16)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2), value: isFocused)
    }
}
#endif

/// Decoding through ImageIO gives the same `CGImage` on both platforms, orientation applied.
enum PlatformImages {
    static func cgImage(data: Data, maxPixelSize: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    static func cgImage(contentsOf url: URL, maxPixelSize: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Copy that names the platform's own gestures and menus.
enum Hints {
    /// "…and pull down to scan again" / "…and choose Library › Scan for New Music".
    static let rescan: String = {
        #if os(macOS)
        "choose Library › Scan for New Music"
        #elseif os(tvOS)
        "use Scan now in Settings"
        #else
        "pull down to scan again"
        #endif
    }()

    /// A full sentence for the end of an error message.
    static let tryAgain: String = {
        #if os(macOS)
        "Choose Library › Scan for New Music to try again."
        #elseif os(tvOS)
        "Use Scan now in Settings to try again."
        #else
        "Pull down to try again."
        #endif
    }()

    static let familyRetry: String = {
        #if os(macOS)
        "Click Refresh to try again."
        #elseif os(tvOS)
        "It is tried again on its own."
        #else
        "Pull down to try again."
        #endif
    }()

    static let songMenu: String = {
        #if os(macOS)
        "Click the ⋯"
        #elseif os(tvOS)
        "Select the ⋯"
        #else
        "Tap the ⋯"
        #endif
    }()

    static let renameGenre: String = {
        #if os(macOS)
        "Right-click a genre in the Library to rename it or merge it with another."
        #elseif os(tvOS)
        "Press and hold a genre in the Library to rename it or merge it with another."
        #else
        "Tap and hold a genre in the Library to rename it or merge it with another."
        #endif
    }()
}

/// Sizes that were drawn for a phone, scaled for a screen across the room.
enum Metrics {
    /// Multiplies fixed card and tile sizes; the television is viewed from ten feet away.
    static let scale: CGFloat = {
        #if os(tvOS)
        2
        #else
        1
        #endif
    }()
}

/// Type that reads at the size of the window.
enum Fonts {
    /// The name at the top of an album, artist or playlist page.
    static var pageTitle: Font {
        #if os(macOS)
        .system(size: 28, weight: .bold)
        #elseif os(tvOS)
        .system(size: 46, weight: .bold)
        #else
        .title2.weight(.semibold)
        #endif
    }
}

/// Grid columns that fit the window: two across on a phone, as many as fit at a Mac-sized tile.
extension EnvironmentValues {
    /// Room for desktop-style layouts: always on the Mac and the television, and on an iPad
    /// (or a resized window) whenever its width is regular. Phones and narrow windows are compact.
    var isWideLayout: Bool {
        #if os(macOS) || os(tvOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }
}

enum Grids {
    /// Playlist and album cards with a title underneath: two columns on a phone, as many as fit elsewhere.
    static func cards(wide: Bool) -> [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 172, maximum: 210), spacing: 18)]
        #elseif os(tvOS)
        [GridItem(.adaptive(minimum: 360, maximum: 420), spacing: 48)]
        #else
        wide
            ? [GridItem(.adaptive(minimum: 172, maximum: 220), spacing: 18)]
            : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        #endif
    }

    /// Square tiles such as genres.
    static func tiles(wide: Bool) -> [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 12)]
        #elseif os(tvOS)
        [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 40)]
        #else
        wide
            ? [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        #endif
    }
}

extension Notification.Name {
    static var appBecameActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the bar: the navigation bar on iPhone, the window toolbar on Mac.
    static var trailingBar: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #elseif os(tvOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }
}

extension View {
    /// A compact title on iPhone; Mac window titles have one size.
    @ViewBuilder func inlineTitle() -> some View {
        #if os(macOS) || os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder func largeTitle() -> some View {
        #if os(macOS) || os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.large)
        #endif
    }

    @ViewBuilder func titleDisplay(large: Bool) -> some View {
        #if os(macOS) || os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(large ? .large : .inline)
        #endif
    }

    @ViewBuilder func noAutocapitalization() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }

    @ViewBuilder func wordsAutocapitalization() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.words)
        #endif
    }

    @ViewBuilder func urlKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.URL)
        #endif
    }

    @ViewBuilder func numberKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.numberPad)
        #endif
    }

    /// Inset grouped rows on iPhone; the Mac's inset list is the same idea.
    @ViewBuilder func groupedList() -> some View {
        #if os(macOS)
        listStyle(.inset)
        #elseif os(tvOS)
        listStyle(.plain)
        #else
        listStyle(.insetGrouped)
        #endif
    }

    /// Screens that draw their own header hide the bar on iPhone; a Mac window keeps its title bar.
    @ViewBuilder func hidesNavigationBar() -> some View {
        #if os(macOS)
        self
        #else
        toolbar(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder func clearNavigationBar() -> some View {
        #if os(macOS)
        self
        #else
        toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    /// The window title on a Mac; the phone's pages carry their name in their own header.
    @ViewBuilder func windowTitle(_ title: String, subtitle: String? = nil) -> some View {
        #if os(macOS)
        if let subtitle {
            navigationTitle(title).navigationSubtitle(subtitle)
        } else {
            navigationTitle(title)
        }
        #else
        self
        #endif
    }

    /// A hero that runs up under the phone's navigation bar; a Mac toolbar is opaque, so it stays below it.
    @ViewBuilder func heroUnderBar() -> some View {
        #if os(macOS)
        self
        #else
        ignoresSafeArea(edges: .top)
        #endif
    }

    /// A screen that owns the Mac window: no title, no toolbar background, paper up to the top edge.
    @ViewBuilder func bareWindow() -> some View {
        #if os(macOS)
        toolbar(removing: .title).toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }

    /// The first-run screens: full width on a phone, a centred column in a Mac window or on an iPad.
    @ViewBuilder func connectColumn(alignment: Alignment = .center, width: CGFloat = 520) -> some View {
        #if os(macOS)
        frame(maxWidth: width, maxHeight: .infinity, alignment: alignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #elseif os(tvOS)
        frame(maxWidth: width * 1.8, maxHeight: .infinity, alignment: alignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        modifier(ConnectColumn(alignment: alignment, width: width))
        #endif
    }

    /// Forms in sheets: the Mac's grouped style matches the phone's inset groups.
    @ViewBuilder func groupedForm() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    /// Pull to refresh where there is something to pull; the television scans from Settings.
    @ViewBuilder func pullToRefresh(_ action: @escaping @Sendable () async -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        refreshable(action: action)
        #endif
    }

    /// A cover that lifts under focus on the television; elsewhere a plain button.
    @ViewBuilder func cardButton() -> some View {
        #if os(tvOS)
        buttonStyle(CoverFocusStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    /// A menu-style picker where menus exist; the television lays the choices out.
    @ViewBuilder func menuPicker() -> some View {
        #if os(tvOS)
        pickerStyle(.automatic)
        #else
        pickerStyle(.menu)
        #endif
    }

    /// A list or form over the app's own paper; the television draws its lists without a background anyway.
    @ViewBuilder func hiddenScrollBackground() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }

    /// Puts the cursor in the search field; the television opens its keyboard on its own.
    @ViewBuilder func focusesSearch(_ binding: FocusState<Bool>.Binding) -> some View {
        #if os(tvOS)
        self
        #else
        searchFocused(binding)
        #endif
    }

    /// The line under a window or page title, where titles have one.
    @ViewBuilder func windowSubtitle(_ text: String) -> some View {
        #if os(tvOS)
        self
        #else
        navigationSubtitle(text)
        #endif
    }

    /// A percentage as the accessibility value; the television's SwiftUI cannot resolve the plain form.
    @ViewBuilder func accessibilityPercent(_ percent: Int) -> some View {
        #if os(tvOS)
        self
        #else
        accessibilityValue("\(percent) percent")
        #endif
    }

    /// Text the person can select and copy, where there is a way to.
    @ViewBuilder func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }

    /// Sheet heights on iPhone; on Mac a sheet is a panel, so it gets a sensible size instead.
    @ViewBuilder func sheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        #if os(macOS)
        frame(minWidth: 460, idealWidth: 480, minHeight: detents == [.large] ? 640 : 520, idealHeight: 640)
        #elseif os(tvOS)
        self
        #else
        presentationDetents(detents)
        #endif
    }
}

#if os(iOS)
/// The phone fills the screen; an iPad keeps the same content in a centred column.
private struct ConnectColumn: ViewModifier {
    let alignment: Alignment
    let width: CGFloat
    @Environment(\.isWideLayout) private var isWide

    func body(content: Content) -> some View {
        if isWide {
            content
                .frame(maxWidth: width, maxHeight: .infinity, alignment: alignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }
}
#endif

/// UIKit's semantic colours by the same names, with the Mac's nearest equivalents.
extension Color {
    static var groupedCard: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #elseif os(tvOS)
        Color.primary.opacity(0.06)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}
