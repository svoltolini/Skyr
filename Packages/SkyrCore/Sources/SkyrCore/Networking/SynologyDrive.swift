import Foundation

/// File Station on a DiskStation, reached through a signed-in DSM session.
public nonisolated final class SynologyDrive: RemoteDrive {
    public let session: DSMSession
    public let displayName: String
    private let urlSession: URLSession

    public init(session: DSMSession, displayName: String) {
        self.session = session
        self.displayName = displayName
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 40
        configuration.httpMaximumConnectionsPerHost = 6
        urlSession = URLSession(configuration: configuration)
    }

    public var id: String { session.baseURL.host() ?? session.baseURL.absoluteString }

    public func roots() async throws -> [RemoteEntry] {
        guard let url = session.url(api: "SYNO.FileStation.List", version: 2, method: "list_share", params: [
            "offset": .int(0), "limit": .int(500), "sort_by": .string("name"), "sort_direction": .string("asc"),
            "onlywritable": .bool(false),
        ]) else { throw RemoteDriveError.notSignedIn }
        return try await SynologyClient.request(url, as: SynologyShareList.self, api: "SYNO.FileStation.List").shares.map(\.entry)
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        do {
            return try await list(path, minimal: false, rawPath: false)
        } catch {
            diagnostics("List failed for \(path): \(error.localizedDescription). Retrying with minimal parameters.")
            do {
                let entries = try await list(path, minimal: true, rawPath: false)
                diagnostics("Minimal listing worked for \(path): \(entries.count) entries.")
                return entries
            } catch {
                do {
                    let entries = try await list(path, minimal: true, rawPath: true)
                    diagnostics("Unquoted listing worked for \(path): \(entries.count) entries.")
                    return entries
                } catch let finalError {
                    diagnostics("All listing attempts failed for \(path): \(finalError.localizedDescription)")
                    throw finalError
                }
            }
        }
    }

    private func list(_ path: String, minimal: Bool, rawPath: Bool) async throws -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        var offset = 0
        let pageSize = 1000
        while true {
            var params: [String: SynologyParam] = [
                "folder_path": rawPath ? .raw(path) : .string(path), "offset": .int(offset), "limit": .int(pageSize),
            ]
            if !minimal {
                params["sort_by"] = .string("name")
                params["sort_direction"] = .string("asc")
                params["filetype"] = .string("all")
                params["additional"] = .strings(["size", "time"])
            }
            guard let url = session.url(api: "SYNO.FileStation.List", version: 2, method: "list", params: params) else {
                throw RemoteDriveError.notSignedIn
            }
            let page = try await SynologyClient.request(url, as: SynologyFileList.self, api: "SYNO.FileStation.List")
            entries.append(contentsOf: page.files.map(\.entry))
            offset += page.files.count
            if page.files.isEmpty || offset >= (page.total ?? 0) { break }
        }
        return entries
    }

    public func read(_ path: String, range: Range<Int64>) async throws -> Data {
        guard let url = streamURL(for: path) else { throw RemoteDriveError.notSignedIn }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteDriveError.http(0) }
        guard http.statusCode == 206 || http.statusCode == 200 else { throw RemoteDriveError.http(http.statusCode) }
        // Read only the window we asked for, even if the server ignored the Range header.
        let skip = http.statusCode == 200 ? Int(range.lowerBound) : 0
        let wanted = Int(range.upperBound - range.lowerBound)
        var data = Data()
        data.reserveCapacity(wanted)
        var seen = 0
        for try await byte in bytes {
            if seen >= skip { data.append(byte) }
            seen += 1
            if data.count >= wanted { break }
        }
        return data
    }

    public func download(_ path: String, maxBytes: Int64) async throws -> Data {
        guard let url = streamURL(for: path) else { throw RemoteDriveError.notSignedIn }
        let (data, response) = try await urlSession.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteDriveError.http(http.statusCode)
        }
        guard Int64(data.count) <= maxBytes else { throw RemoteDriveError.tooLarge }
        return data
    }

    /// File Station's download endpoint with the file name appended, the form DSM's own UI uses,
    /// so players and caches see a sensible extension.
    public func streamURL(for path: String) -> URL? {
        guard let url = session.url(api: "SYNO.FileStation.Download", version: 2, method: "download", params: [
            "path": .strings([path]), "mode": .string("open"),
        ]), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let name = path.split(separator: "/").last.map(String.init) ?? "file"
        components.path += "/" + name
        return components.url
    }
}
