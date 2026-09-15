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

// MARK: - Writing

extension SynologyDrive: WritableRemoteDrive {
    public func info(_ path: String) async throws -> RemoteEntry {
        guard let url = session.url(api: "SYNO.FileStation.List", version: 2, method: "getinfo", params: [
            "path": .strings([path]), "additional": .strings(["size", "time"]),
        ]) else { throw RemoteDriveError.notSignedIn }
        let list = try await SynologyClient.request(url, as: SynologyFileInfoList.self, api: "SYNO.FileStation.List")
        guard let file = list.files.first else { throw RemoteWriteError.missing }
        if let code = file.code { throw SynologyError.api(code: code, api: "SYNO.FileStation.List") }
        return file.entry
    }

    /// Streams the file straight to disk, so a whole song is never held in memory, and stops at `maxBytes`.
    @concurrent public func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws {
        guard maxBytes >= 0 else { throw RemoteDriveError.tooLarge }
        guard let url = streamURL(for: path) else { throw RemoteDriveError.notSignedIn }
        let (bytes, response) = try await urlSession.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RemoteDriveError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw RemoteDriveError.http(http.statusCode) }
        guard response.expectedContentLength <= maxBytes else { throw RemoteDriveError.tooLarge }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try await withTaskCancellationHandler {
            var buffer = Data()
            buffer.reserveCapacity(256 * 1024)
            var total: Int64 = 0
            for try await byte in bytes {
                total += 1
                guard total <= maxBytes else { throw RemoteDriveError.tooLarge }
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
        } onCancel: {
            bytes.task.cancel()
        }
    }

    /// File Station's upload as its API guide shows it: the session in the query string, the call and
    /// its parameters as form fields, and the file as the last part. The form is staged on disk so
    /// the song streams from there.
    @concurrent public func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws {
        guard let (url, call) = session.form(api: "SYNO.FileStation.Upload", version: 2, method: "upload") else {
            throw RemoteWriteError.unsupported
        }
        var fields = ["api", "version", "method"].compactMap { key in call[key].map { (key, $0) } }
        fields += [("path", folder), ("create_parents", "false"), ("overwrite", "true")]
        if let modified { fields.append(("mtime", String(Int64(modified.timeIntervalSince1970 * 1000)))) }
        let boundary = "skyr-" + UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appending(path: "skyr-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipartForm(fields: fields, file: file, fileName: name, boundary: boundary, to: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = session.token { request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.upload(for: request, fromFile: body)
        } catch {
            throw SynologyError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteDriveError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw RemoteDriveError.http(http.statusCode) }
        // Some DSM builds answer with details, others with a bare success; only a refusal or a
        // skipped file counts as failure.
        _ = try SynologyClient.decode(data, as: SynologyEmpty.self, api: "SYNO.FileStation.Upload")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let result = try? decoder.decode(SynologyEnvelope<SynologyUploadResult>.self, from: data), result.data?.blSkip == true {
            throw SynologyError.api(code: 1805, api: "SYNO.FileStation.Upload")
        }
    }

    public func rename(_ path: String, to name: String) async throws {
        guard let url = session.url(api: "SYNO.FileStation.Rename", version: 2, method: "rename", params: [
            "path": .strings([path]), "name": .strings([name]),
        ]) else { throw RemoteWriteError.unsupported }
        _ = try await SynologyClient.request(url, as: SynologyEmpty.self, api: "SYNO.FileStation.Rename")
    }

    public func delete(_ path: String) async throws {
        guard let url = session.url(api: "SYNO.FileStation.Delete", version: 2, method: "delete", params: [
            "path": .strings([path]), "recursive": .bool(false),
        ]) else { throw RemoteWriteError.unsupported }
        _ = try await SynologyClient.request(url, as: SynologyEmpty.self, api: "SYNO.FileStation.Delete")
    }

    /// Writes the multipart body to `destination`: the text fields first, then the file, copied in chunks.
    nonisolated static func writeMultipartForm(fields: [(String, String)], file: URL, fileName: String, boundary: String, to destination: URL) throws {
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var head = ""
        for (name, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        // Quotes and line breaks cannot appear in the header; DSM reads the rest as UTF-8.
        let safeName = fileName.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(head.utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.synchronize()
    }
}
