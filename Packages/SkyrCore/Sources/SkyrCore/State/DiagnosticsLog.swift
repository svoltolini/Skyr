import Foundation

/// In-app event log so problems on the phone can be read without a debugger.
@Observable
public final class DiagnosticsLog {
    public static let shared = DiagnosticsLog()

    public struct Entry: Identifiable, Hashable {
        public let id = UUID()
        public let date: Date
        public let message: String
    }

    public private(set) var entries: [Entry] = []

    /// Kept on disk so a problem can be read after a relaunch, or pulled off the device.
    public static let fileURL: URL = {
        let directory = AppDirectories.support.appending(path: "Skyr")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "diagnostics.log")
    }()

    private init() {
        entries = Self.loadEntries()
    }

    public func record(_ message: String) {
        let entry = Entry(date: .now, message: message)
        entries.append(entry)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        Self.append(entry)
    }

    public func clear() {
        entries.removeAll()
        try? Data().write(to: Self.fileURL)
    }

    private static func loadEntries() -> [Entry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(300)
        return lines.compactMap { line in
            guard let tab = line.firstIndex(of: "\t"), let date = ISO8601DateFormatter().date(from: String(line[..<tab])) else { return nil }
            return Entry(date: date, message: String(line[line.index(after: tab)...]))
        }
    }

    private static func append(_ entry: Entry) {
        let line = ISO8601DateFormatter().string(from: entry.date) + "\t" + entry.message.replacingOccurrences(of: "\n", with: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    public var text: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { "\(formatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
    }
}

/// Records from any isolation domain.
public nonisolated func diagnostics(_ message: String) {
    Task { @MainActor in
        DiagnosticsLog.shared.record(message)
    }
}
