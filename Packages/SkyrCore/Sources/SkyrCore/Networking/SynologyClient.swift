import Foundation

// MARK: - Wire types

public nonisolated struct SynologyAPIDescriptor: Decodable, Sendable {
    public let path: String
    public let minVersion: Int
    public let maxVersion: Int
}

public nonisolated struct SynologyEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let data: Payload?
    public let error: SynologyAPIError?
}

public nonisolated struct SynologyAPIError: Decodable, Sendable {
    public let code: Int
}

public nonisolated struct SynologyAuthData: Decodable, Sendable {
    public let sid: String
    /// The CSRF token DSM hands out at login; administration calls are refused without it.
    public let synotoken: String?
    /// The responder's half of DSM 7.2's sign-in handshake, when one was offered.
    public let ikMessage: String?
}

public nonisolated struct SynologyDSMInfo: Decodable, Sendable {
    public let model: String?
    public let versionString: String?
}

public nonisolated struct SynologyFileEntry: Decodable, Sendable {
    public let isdir: Bool
    public let name: String
    public let path: String
    public let additional: Additional?

    public nonisolated struct Additional: Decodable, Sendable {
        public let size: Int64?
        public let time: Time?
        public nonisolated struct Time: Decodable, Sendable {
            public let mtime: Double?
        }
    }

    public var entry: RemoteEntry {
        RemoteEntry(
            path: path, name: name, isDirectory: isdir, size: additional?.size,
            modified: additional?.time?.mtime.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

public nonisolated struct SynologyShareList: Decodable, Sendable {
    public let shares: [SynologyFileEntry]
    public let total: Int?
}

public nonisolated struct SynologyFileList: Decodable, Sendable {
    public let files: [SynologyFileEntry]
    public let offset: Int?
    public let total: Int?
}

/// One answer of `getinfo`: a file's details, or a per-path error code when it is not there.
public nonisolated struct SynologyFileInfo: Decodable, Sendable {
    public let path: String
    public let name: String?
    public let isdir: Bool?
    public let code: Int?
    public let additional: SynologyFileEntry.Additional?

    public var entry: RemoteEntry {
        RemoteEntry(
            path: path, name: name ?? (path.split(separator: "/").last.map(String.init) ?? path), isDirectory: isdir ?? false,
            size: additional?.size, modified: additional?.time?.mtime.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

public nonisolated struct SynologyFileInfoList: Decodable, Sendable {
    public let files: [SynologyFileInfo]
}

/// What File Station reports after an upload.
public nonisolated struct SynologyUploadResult: Decodable, Sendable {
    /// True when an existing file was kept and the upload skipped.
    public let blSkip: Bool?
    public let file: String?
}

public nonisolated struct SynologyEmpty: Decodable, Sendable {}

/// DSM's proof that the signed-in person just confirmed their password.
public nonisolated struct SynologyConfirmToken: Decodable, Sendable {
    public let token: String

    private enum CodingKeys: String, CodingKey { case token = "SynoConfirmPWToken" }
}

/// Everything needed to talk to DSM after signing in.
public nonisolated struct DSMSession: Sendable, Hashable {
    public let baseURL: URL
    public let account: String?
    public let sid: String
    public let apis: [String: SynologyAPIDescriptor]
    /// The DSM application the session was scoped to at login, or nil for a plain DSM session.
    public let sessionParam: String?
    /// A label for logs and logout.
    public var name: String { sessionParam ?? "DSM" }
    /// DSM's CSRF token, sent with every call as the login guide asks.
    public let token: String?
    /// DSM 7.2's sign-in handshake, when the login negotiated one. Administration calls over a public
    /// route are refused unless each request is signed from it.
    public let noise: NoiseSession?

    public init(baseURL: URL, sid: String, apis: [String: SynologyAPIDescriptor], sessionParam: String? = "FileStation", token: String? = nil, noise: NoiseSession? = nil, account: String? = nil) {
        self.baseURL = baseURL
        self.account = account
        self.sid = sid
        self.apis = apis
        self.sessionParam = sessionParam
        self.token = token
        self.noise = noise
    }

    public func descriptor(_ api: String) -> SynologyAPIDescriptor? { apis[api] }

    /// Builds a web API URL; string and array parameters are JSON encoded as DSM 7 expects.
    public func url(api: String, version: Int, method: String, params: [String: SynologyParam] = [:], authorized: Bool = true) -> URL? {
        guard NASTransportSecurity.isAllowed(baseURL), let descriptor = apis[api] else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/" + descriptor.path
        let item = Self.encodedItem
        var items = [
            item("api", api),
            item("version", String(min(max(version, descriptor.minVersion), descriptor.maxVersion))),
            item("method", method),
        ]
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            items.append(item(key, value.encoded))
        }
        if authorized {
            items.append(item("_sid", sid))
            if let token { items.append(item("SynoToken", token)) }
        }
        components.percentEncodedQueryItems = items
        return components.url
    }

    /// The same call as a form POST. The session id and CSRF token stay in the query string, which is
    /// where DSM's checks read them; the call itself and its parameters go in the body.
    public func form(api: String, version: Int, method: String, params: [String: SynologyParam] = [:]) -> (URL, [String: String])? {
        guard NASTransportSecurity.isAllowed(baseURL), let descriptor = apis[api] else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/" + descriptor.path
        var items = [Self.encodedItem("_sid", sid)]
        if let token { items.append(Self.encodedItem("SynoToken", token)) }
        components.percentEncodedQueryItems = items
        guard let url = components.url else { return nil }
        var form = [
            "api": api,
            "version": String(min(max(version, descriptor.minVersion), descriptor.maxVersion)),
            "method": method,
        ]
        for (key, value) in params { form[key] = value.encoded }
        return (url, form)
    }

    /// Encodes everything but unreserved characters: DSM treats "+" as a space and "&" as a separator.
    static func encodedItem(_ name: String, _ value: String) -> URLQueryItem {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)
    }
}

nonisolated extension SynologyAPIDescriptor: Hashable {}

/// A DSM web API parameter with the encoding DSM 7's JSON request format expects.
public nonisolated enum SynologyParam: Sendable {
    case string(String)
    /// A string sent without JSON quotes, for servers that expect the older form.
    case raw(String)
    case int(Int)
    case bool(Bool)
    case strings([String])

    public var encoded: String {
        switch self {
        case .string(let value): Self.json(value)
        case .raw(let value): value
        case .int(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .strings(let values): "[" + values.map(Self.json).joined(separator: ",") + "]"
        }
    }

    private static func json(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }
}

// MARK: - Errors

public nonisolated enum SynologyError: LocalizedError, Sendable {
    case invalidAddress
    case unreachable(String)
    case http(Int)
    case api(code: Int, api: String)
    case fileStationMissing
    case notSignedIn
    case twoFactorRequired
    case decoding(String)
    /// HTTPS answered, but with a certificate this device does not trust.
    case untrustedCertificate(host: String)
    /// Nothing answered on any of DSM's usual ports at a public address.
    case noAnswer(host: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "That address doesn't look like a server address."
        case .unreachable(let detail):
            "Couldn't reach the server. \(detail)"
        case .http(let status):
            "The server answered with HTTP \(status)."
        case .api(let code, let api):
            switch (api, code) {
            case ("SYNO.API.Auth", 400): "Wrong account name or password."
            case ("SYNO.API.Auth", 401): "This account is disabled."
            case ("SYNO.API.Auth", 402): "This account isn't allowed to sign in."
            case ("SYNO.API.Auth", 403), ("SYNO.API.Auth", 404): "A two-factor code is required."
            case (_, 119): "The session has expired. Sign in again."
            case ("SYNO.FileStation.List", 408), ("SYNO.FileStation.List", 407): "This account can't open that folder."
            case ("SYNO.FileStation.Upload", 1805), (_, 414): "A file with that name already exists on the server."
            case (_, 407), (_, 411): "This account can only read the music folder, so its files can't be changed."
            case (_, 408): "The file is no longer on the server."
            case (_, 415), (_, 416): "The server has run out of space."
            case (_, 418), (_, 419): "The server refused that file name."
            case ("SYNO.FileStation.Rename", 1200): "The server couldn't rename the file."
            case ("SYNO.FileStation.Upload", 1800), ("SYNO.FileStation.Upload", 1801), ("SYNO.FileStation.Upload", 1803):
                "The upload didn't arrive completely at the server."
            case ("SYNO.API.Auth", 414): "DSM turned down the sign-in used for account management (error 414)."
            case ("SYNO.Core.User", 105): "DSM refused to manage users with this account (error 105)."
            case ("SYNO.Core.Share.Permission", 105): "DSM refused to change the folder's permissions with this account (error 105)."
            case (_, 105): "This account doesn't have permission for that."
            default: "\(api) failed with error \(code)."
            }
        case .fileStationMissing:
            "This server doesn't offer the File Station API, so it isn't a DiskStation."
        case .notSignedIn:
            "Sign in to the server first."
        case .twoFactorRequired:
            "A two-factor code is required."
        case .decoding(let detail):
            "Unexpected reply from the server. \(detail)"
        case .untrustedCertificate(let host):
            "\(host) answered, but its certificate isn't trusted, so the connection was refused. In DSM, get a Let's Encrypt certificate for this name under Control Panel › Security › Certificate."
        case .noAnswer(let host):
            "Nothing answered at \(host) on DSM's usual ports. Check that your router forwards TCP port 5001 to the NAS (DSM: Control Panel › External Access › Router Configuration) and that the DSM firewall allows it. At home, the NAS's local address works without any of that."
        }
    }
}

// MARK: - Client

/// Signs in to DSM and returns a session the File Station drive can use.
public nonisolated enum SynologyClient {
    public static let requiredAPIs = [
        "SYNO.API.Auth", "SYNO.DSM.Info", "SYNO.FileStation.Info", "SYNO.FileStation.List",
        "SYNO.FileStation.Download", "SYNO.FileStation.Thumb", "SYNO.Core.User", "SYNO.Core.Share.Permission",
        "SYNO.API.Encryption", "SYNO.Core.User.PasswordConfirm",
        // Writing tags back: a rewritten song is uploaded beside the original, then swapped in.
        "SYNO.FileStation.Upload", "SYNO.FileStation.Rename", "SYNO.FileStation.Delete",
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NASRedirectDelegate.shared, delegateQueue: nil)
    }()

    /// Builds a base URL from what the user typed: a host, host:port, or full URL.
    public static func baseURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hadScheme = trimmed.contains("://")
        if !hadScheme { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        let hostPattern = #"^(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*)$"#
        guard host.range(of: hostPattern, options: .regularExpression) != nil else { return nil }
        // A bare host means DSM's own ports; an explicit scheme keeps the web defaults.
        if components.port == nil, !hadScheme {
            components.port = components.scheme == "https" ? 5001 : 5000
        }
        components.path = ""
        components.query = nil
        guard let url = components.url, let origin = NASOrigin(url: url) else { return nil }
        return origin.url
    }

    /// Where DSM answers for what the person typed. A full URL is taken as it is; a bare name or
    /// address is tried using HTTPS. An explicitly typed HTTP URL is offered for local confirmation
    /// without probing it or sending credentials; HTTP is never an automatic fallback.
    public static func reachableBaseURL(for text: String) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let typed = baseURL(from: trimmed), let host = typed.host() else { throw SynologyError.invalidAddress }
        if typed.scheme == "http" { return typed }
        let isHome = ServerConnection.isHomeAddress(host)
        let candidates = secureCandidates(for: trimmed)
        // Everything is asked at once; the first answer in order of preference wins.
        let results: [ProbeOutcome] = await parallelResults(candidates) { url in
            if case .failure(let error) = await Self.probe(url) { return ProbeOutcome(error: error) }
            return ProbeOutcome(error: nil)
        }
        for index in candidates.indices where results[index].error == nil {
            return candidates[index]
        }
        let certificateProblem = results.contains { result in
            if let error = result.error, let urlError = error as? URLError {
                return [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                        .serverCertificateNotYetValid, .secureConnectionFailed].contains(urlError.code)
            }
            return false
        }
        if certificateProblem { throw SynologyError.untrustedCertificate(host: host) }
        if !isHome { throw SynologyError.noAnswer(host: host) }
        throw SynologyError.unreachable("Nothing answered at \(host). Check the address and that the NAS is on.")
    }

    /// Pure route selection, shared by the resolver and ordinary compatibility tests.
    static func secureCandidates(for text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let typed = baseURL(from: trimmed), typed.scheme == "https",
              let original = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed) else { return [] }
        var candidates = [typed]
        if original.port == nil {
            var components = URLComponents(url: typed, resolvingAgainstBaseURL: false)!
            components.port = trimmed.contains("://") ? 5001 : 443
            if let alternate = components.url, !candidates.contains(alternate) { candidates.append(alternate) }
        }
        return candidates
    }

    /// What one probe found; a struct rather than a `Result`, which came back corrupted from worker tasks in release builds.
    private nonisolated struct ProbeOutcome: Sendable {
        let error: (any Error)?
    }

    /// One quick, unauthenticated question to DSM: does its API answer here?
    private static func probe(_ base: URL) async -> Result<Void, any Error> {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/query.cgi"
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Info"), URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "query"), URLQueryItem(name: "query", value: "SYNO.API.Auth"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["success"] as? Bool == true
            else { return .failure(SynologyError.http((response as? HTTPURLResponse)?.statusCode ?? 0)) }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    public static func loadAPIs(baseURL: URL) async throws -> [String: SynologyAPIDescriptor] {
        try NASTransportSecurity.requireAllowed(baseURL)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/query.cgi"
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Info"), URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "query"), URLQueryItem(name: "query", value: requiredAPIs.joined(separator: ",")),
        ]
        return try await request(components.url!, as: [String: SynologyAPIDescriptor].self, api: "SYNO.API.Info")
    }

    /// Signs in and returns a session. Throws `fileStationMissing` when the server isn't a DiskStation.
    /// `sessionName` is the DSM application the session is opened for; pass nil for a plain DSM
    /// session, which is what user administration (SYNO.Core.*) needs — a File Station-scoped
    /// session's id is refused there with error 119. `handshake` negotiates DSM 7.2's sign-in
    /// handshake, which the server demands before it will manage users over a public route.
    public static func login(baseURL: URL, account: String, password: String, otpCode: String?, sessionName: String? = "FileStation", handshake: Bool = false) async throws -> DSMSession {
        try NASTransportSecurity.requireAllowed(baseURL)
        guard let origin = NASOrigin(url: baseURL) else { throw NASTransportError.invalidAddress }
        let baseURL = origin.url
        let apis = try await loadAPIs(baseURL: baseURL)
        guard let auth = apis["SYNO.API.Auth"] else { throw SynologyError.fileStationMissing }
        guard apis["SYNO.FileStation.List"] != nil, apis["SYNO.FileStation.Download"] != nil else { throw SynologyError.fileStationMissing }
        let version = max(min(auth.maxVersion, handshake ? 7 : 6), auth.minVersion)
        var form = [
            "api": "SYNO.API.Auth", "version": "\(version)", "method": "login",
            "account": account, "passwd": password, "format": "sid",
            "enable_syno_token": "yes",
        ]
        if let sessionName { form["session"] = sessionName }
        if let otpCode, !otpCode.isEmpty { form["otp_code"] = otpCode }
        var noise: NoiseSession?
        if handshake, version >= 7 {
            // The rest of what a browser sends; without it DSM answers the handshake login with 414.
            form["client"] = "browser"
            form["logintype"] = "local"
            form["rememberme"] = "0"
            form["enable_device_token"] = "no"
            if form["otp_code"] == nil { form["otp_code"] = "" }
            if let (session, ikMessage) = await beginHandshake(baseURL: baseURL, path: auth.path) {
                noise = session
                form["ik_message"] = ikMessage
            } else {
                diagnostics("Sign-in handshake could not be started; continuing without it")
            }
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/" + auth.path
        let data = try await request(components.url!, as: SynologyAuthData.self, api: "SYNO.API.Auth", form: form)
        if let noise, let reply = data.ikMessage, let bytes = NoiseSession.data(base64url: reply) {
            do { try noise.finish(with: bytes) } catch { diagnostics("Sign-in handshake did not complete: \(error)") }
        }
        let live = noise?.isFinished == true ? noise : nil
        diagnostics("DSM session “\(sessionName ?? "DSM")” opened as \(account) (API version \(version), CSRF token \(data.synotoken == nil ? "absent" : "present"), handshake \(handshake ? (live != nil ? "established" : "not established") : "not requested"))")
        return DSMSession(baseURL: baseURL, sid: data.sid, apis: apis, sessionParam: sessionName, token: data.synotoken, noise: live, account: account)
    }

    /// Fetches DSM's login UI config, which hands back the `_SSID` cookie carrying the server's
    /// handshake key, then builds the initiator's message.
    private static func beginHandshake(baseURL: URL, path: String) async -> (NoiseSession, String)? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi/SYNO.API.Auth.UIConfig"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("api=SYNO.API.Auth.UIConfig&method=get&version=1".utf8)
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        let cookies = (response as? HTTPURLResponse).flatMap { http -> [HTTPCookie] in
            guard let fields = http.allHeaderFields as? [String: String], let responseURL = http.url else { return [] }
            return HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL)
        } ?? []
        let stored = session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        guard let ssid = (cookies + stored).first(where: { $0.name == "_SSID" })?.value,
              let key = NoiseSession.data(base64url: ssid), let noise = try? NoiseSession(remoteStaticKey: key) else { return nil }
        let payload = Data("{\"time\":\(Int(Date().timeIntervalSince1970))}".utf8)
        guard let message = try? noise.firstMessage(payload: payload) else { return nil }
        return (noise, NoiseSession.base64url(message))
    }

    public static func logout(_ session: DSMSession) async {
        let params: [String: SynologyParam] = session.sessionParam.map { ["session": .string($0)] } ?? [:]
        guard let url = session.url(api: "SYNO.API.Auth", version: 1, method: "logout", params: params) else { return }
        _ = try? await request(url, as: SynologyEmpty.self, api: "SYNO.API.Auth")
    }

    /// Model name and DSM version, used to label the connection.
    public static func info(_ session: DSMSession) async -> SynologyDSMInfo? {
        guard let url = session.url(api: "SYNO.DSM.Info", version: 2, method: "getinfo") else { return nil }
        return try? await request(url, as: SynologyDSMInfo.self, api: "SYNO.DSM.Info")
    }

    // MARK: Family account

    /// Whether this session may manage users: only administrators can list them.
    public static func canManageUsers(_ session: DSMSession) async -> Bool? {
        do {
            try await post(session, api: "SYNO.Core.User", version: 1, method: "list", params: [
                "offset": .int(0), "limit": .int(1), "type": .string("local"),
            ])
            return true
        } catch SynologyError.api(let code, _) where code == 105 {
            return false
        } catch {
            diagnostics("Checking user rights failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// DSM guards sensitive changes behind a fresh proof of the signed-in person's password. The web
    /// interface asks for it in a dialog; here the host's own stored password answers the same call.
    public static func confirmToken(_ session: DSMSession, password: String) async -> String? {
        let versions = [2, 1]
        for version in versions {
            do {
                let reply: SynologyConfirmToken = try await post(
                    session, as: SynologyConfirmToken.self, api: "SYNO.Core.User.PasswordConfirm",
                    version: version, method: "auth", params: [:], sealing: ["password": password]
                )
                diagnostics("Password confirmed for privileged changes")
                return reply.token
            } catch {
                diagnostics("Password confirmation (v\(version)) failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Makes an account for the family on the NAS that can only read the music share. Needs an
    /// administrator, and DSM's confirmation token when the server asks for one.
    public static func createFamilyUser(_ session: DSMSession, name: String, password: String, shareName: String, confirm: String?) async throws {
        try await postWithPassword(session, api: "SYNO.Core.User", method: "create", params: [
            "name": .string(name), "description": .string("Skyr Music family"),
            "email": .string(""), "expired": .string("normal"), "cannot_chg_passwd": .bool(true),
            "passwd_never_expire": .bool(true), "notify_by_email": .bool(false), "send_password": .bool(false),
        ], password: password, confirm: confirm)
        diagnostics("Family account \(name) created; granting read-only access to “\(shareName)”")
        do {
            try await grantReadOnly(session, user: name, shareName: shareName, confirm: confirm)
        } catch {
            // No half-made account: the user is removed again and the reason reported.
            try? await deleteUser(session, name: name, confirm: confirm)
            throw error
        }
    }

    public static func grantReadOnly(_ session: DSMSession, user: String, shareName: String, confirm: String?) async throws {
        let permissions = "[{\"name\":\(SynologyParam.string(user).encoded),\"is_readonly\":true,\"is_writable\":false,\"is_deny\":false,\"is_custom\":false}]"
        try await post(session, api: "SYNO.Core.Share.Permission", version: 1, method: "set", params: [
            "name": .string(shareName), "user_group_type": .string("local_user"), "permissions": .raw(permissions),
        ], confirm: confirm)
    }

    public static func setPassword(_ session: DSMSession, user: String, password: String, confirm: String?) async throws {
        try await postWithPassword(session, api: "SYNO.Core.User", method: "set", params: ["name": .string(user)], password: password, confirm: confirm)
    }

    public static func deleteUser(_ session: DSMSession, name: String, confirm: String?) async throws {
        try await post(session, api: "SYNO.Core.User", version: 1, method: "delete", params: ["name": .strings([name])], confirm: confirm)
    }

    /// Sends the password sealed the way DSM's own interface does; if the server will not take that
    /// form, once more in the plain form, so an older or oddly configured DSM still works.
    private static func postWithPassword(_ session: DSMSession, api: String, method: String, params: [String: SynologyParam], password: String, confirm: String?) async throws {
        do {
            try await post(session, api: api, version: 1, method: method, params: params, sealing: ["password": password], confirm: confirm)
        } catch SynologyError.api(let code, _) where code != 105 {
            diagnostics("\(api) \(method) with a sealed password was refused (error \(code)); trying the plain form")
            var plain = params
            plain["password"] = .string(password)
            try await post(session, api: api, version: 1, method: method, params: plain, confirm: confirm)
        }
    }

    private static func encryptionInfo(_ session: DSMSession) async throws -> SynologyEncryptionInfo {
        guard let url = session.url(api: "SYNO.API.Encryption", version: 1, method: "getinfo", params: ["format": .raw("module")], authorized: false) else {
            throw SynologyError.api(code: 102, api: "SYNO.API.Encryption")
        }
        return try await request(url, as: SynologyEncryptionInfo.self, api: "SYNO.API.Encryption")
    }

    /// Sends an API call as a form POST, keeping passwords out of URLs and server logs. `sealing`
    /// fields are encrypted with the NAS's public key first, as DSM's interface does for passwords,
    /// and `confirm` carries DSM's proof that the person just re-entered their password.
    @discardableResult
    private static func post<Payload: Decodable & Sendable>(
        _ session: DSMSession, as type: Payload.Type = SynologyEmpty.self, api: String, version: Int, method: String,
        params: [String: SynologyParam], sealing secrets: [String: String] = [:], confirm: String? = nil
    ) async throws -> Payload {
        guard let (url, plainForm) = session.form(api: api, version: version, method: method, params: params) else {
            throw SynologyError.api(code: 102, api: api)
        }
        var form = plainForm
        if !secrets.isEmpty {
            let info = try await encryptionInfo(session)
            form[info.cipherkey] = try SynologyCipher.seal(secrets, with: info)
        }
        if let confirm { form["SynoConfirmPWToken"] = confirm }
        var headers = session.token.map { ["X-SYNO-TOKEN": $0] } ?? [:]
        if let hash = session.noise?.requestHash() { headers["X-SYNO-HASH"] = hash }
        diagnostics("POST \(api) \(method) v\(form["version"] ?? "?") via “\(session.name)” session, \(secrets.isEmpty ? "plain" : "sealed password"), confirmation \(confirm == nil ? "none" : "attached"), handshake \(session.noise == nil ? "no" : "signed")")
        return try await request(url, as: Payload.self, api: api, form: form, headers: headers)
    }

    // MARK: Plumbing

    public static func request<Payload: Decodable & Sendable>(
        _ url: URL, as type: Payload.Type, api: String, form: [String: String]? = nil, headers: [String: String] = [:]
    ) async throws -> Payload {
        try NASTransportSecurity.requireAllowed(url)
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            // Strict encoding: "&", "=" and "+" in a password must not reach DSM as separators.
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            request.httpBody = form
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SynologyError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SynologyError.http(http.statusCode)
        }
        return try decode(data, as: Payload.self, api: api)
    }

    /// Unwraps DSM's `{success, data, error}` envelope, turning a refusal into `SynologyError.api`.
    public static func decode<Payload: Decodable & Sendable>(_ data: Data, as type: Payload.Type, api: String) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope: SynologyEnvelope<Payload>
        do {
            envelope = try decoder.decode(SynologyEnvelope<Payload>.self, from: data)
        } catch {
            throw SynologyError.decoding(String(describing: error).prefix(160).description)
        }
        guard envelope.success else {
            let code = envelope.error?.code ?? -1
            if api.hasPrefix("SYNO.Core.") {
                // Administration calls are rare and their answers carry the detail needed to fix them.
                let body = String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                diagnostics("\(api) answered: \(body)")
            }
            if api == "SYNO.API.Auth", code == 403 || code == 404 { throw SynologyError.twoFactorRequired }
            throw SynologyError.api(code: code, api: api)
        }
        if let payload = envelope.data { return payload }
        if let empty = SynologyEmpty() as? Payload { return empty }
        throw SynologyError.decoding("Missing data.")
    }
}
