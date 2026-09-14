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
        urlSession = URLSession(configuration: configuration, delegate: NASRedirectDelegate.shared, delegateQueue: nil)
    }

    public var id: String { NASSource.identifier(baseURL: session.baseURL, account: session.account ?? "") }

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

    @concurrent public func read(_ path: String, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, !range.isEmpty,
              let wanted = Int(exactly: range.upperBound - range.lowerBound) else { throw RemoteDriveError.tooLarge }
        guard let url = streamURL(for: path) else { throw RemoteDriveError.notSignedIn }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await urlSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RemoteDriveError.http(0) }
        guard http.statusCode == 206 || http.statusCode == 200 else { throw RemoteDriveError.http(http.statusCode) }
        // Read only the window we asked for, even if the server ignored the Range header.
        return try await withTaskCancellationHandler {
            var remainingSkip = http.statusCode == 200 ? range.lowerBound : 0
            var data = Data()
            data.reserveCapacity(min(wanted, 64 * 1024))
            for try await byte in bytes {
                try Task.checkCancellation()
                if remainingSkip > 0 { remainingSkip -= 1 }
                else { data.append(byte) }
                if data.count == wanted { break }
            }
            try Task.checkCancellation()
            return data
        } onCancel: {
            bytes.task.cancel()
        }
    }

    @concurrent public func download(_ path: String, maxBytes: Int64) async throws -> Data {
        guard maxBytes >= 0 else { throw RemoteDriveError.tooLarge }
        guard let url = streamURL(for: path) else { throw RemoteDriveError.notSignedIn }
        let (bytes, response) = try await urlSession.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RemoteDriveError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw RemoteDriveError.http(http.statusCode) }
        return try await withTaskCancellationHandler {
            try await BoundedBytes.collect(bytes, maximum: maxBytes, expectedLength: response.expectedContentLength)
        } onCancel: {
            bytes.task.cancel()
        }
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
