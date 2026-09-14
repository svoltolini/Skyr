import Foundation

/// A network origin is an address boundary, not proof that two routes reach the same NAS.
public nonisolated struct NASOrigin: Hashable, Codable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public var isHTTPS: Bool { scheme == "https" }
    public var identifier: String { "\(scheme)://\(host):\(port)" }
    public var url: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.url!
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let url = try container.decode(URL.self)
        guard let origin = NASOrigin(url: url) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid NAS origin")
        }
        self = origin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url)
    }
}

public nonisolated enum NASTransportError: LocalizedError, Equatable, Sendable {
    case invalidAddress
    case httpApprovalRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter an HTTP or HTTPS server address without a username or password in the address."
        case .httpApprovalRequired(let address):
            "HTTP is not encrypted: \(address). Choose HTTPS, or review and allow this HTTP address in Sign in on this device before reconnecting."
        }
    }
}

/// HTTP approval belongs to this device and exact origin. It is never imported from a family,
/// discovery result, saved connection, Watch message, or a hostname that resembles a VPN address.
public nonisolated enum NASTransportSecurity {
    private static func approvalKey(_ origin: NASOrigin) -> String { "nas.httpApproval.v1.\(origin.identifier)" }

    public static func isAllowed(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let origin = NASOrigin(url: url) else { return false }
        return origin.isHTTPS || defaults.bool(forKey: approvalKey(origin))
    }

    public static func requireAllowed(_ url: URL, defaults: UserDefaults = .standard) throws {
        guard let origin = NASOrigin(url: url) else { throw NASTransportError.invalidAddress }
        guard isAllowed(url, defaults: defaults) else { throw NASTransportError.httpApprovalRequired(origin.identifier) }
    }

    /// Call only in response to a person's explicit choice in this device's transport UI.
    public static func allowHTTP(_ url: URL, defaults: UserDefaults = .standard) {
        guard let origin = NASOrigin(url: url), !origin.isHTTPS else { return }
        defaults.set(true, forKey: approvalKey(origin))
    }

    public static func revokeHTTP(_ url: URL, defaults: UserDefaults = .standard) {
        guard let origin = NASOrigin(url: url), !origin.isHTTPS else { return }
        defaults.removeObject(forKey: approvalKey(origin))
    }

    public static func permitsRedirect(from original: URL, to destination: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let source = NASOrigin(url: original), source == NASOrigin(url: destination) else { return false }
        return isAllowed(original, defaults: defaults) && isAllowed(destination, defaults: defaults)
    }

    /// Suggest DSM's HTTPS port for its ordinary HTTP port; custom ports remain explicit.
    public static func httpsAlternative(for url: URL) -> URL? {
        guard let origin = NASOrigin(url: url) else { return nil }
        var components = URLComponents(url: origin.url, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        if origin.port == 5000 { components.port = 5001 }
        else if origin.port == 80 { components.port = 443 }
        return components.url
    }
}

/// URLSession consults this delegate for default/ephemeral sessions. Background download sessions
/// follow redirects inside the OS and do not support this callback.
nonisolated final class NASRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NASRedirectDelegate()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              NASTransportSecurity.permitsRedirect(from: original, to: destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
