import Foundation
import Testing
@testable import SkyrCore

@Suite("NAS transport")
struct NASTransportTests {
    @Test func originsKeepPortsAndSchemesSeparateAndNormalizeOrdinaryAddresses() throws {
        let ordinary = try #require(NASOrigin(url: URL(string: "https://NAS.EXAMPLE/music")!))
        #expect(ordinary == NASOrigin(url: URL(string: "https://nas.example:443/webapi/query.cgi")!))
        #expect(ordinary != NASOrigin(url: URL(string: "https://nas.example:5001")!))
        #expect(ordinary != NASOrigin(url: URL(string: "http://nas.example:443")!))
        #expect(ordinary.identifier == "https://nas.example:443")
        #expect(try JSONDecoder().decode(NASOrigin.self, from: JSONEncoder().encode(ordinary)) == ordinary)
        #expect(NASOrigin(url: URL(string: "ftp://nas.example")!) == nil)
        #expect(NASOrigin(url: URL(string: "https://listener:password@nas.example")!) == nil)
        #expect(NASOrigin(url: URL(string: "https://[fd00::1]:5001")!)?.identifier == "https://[fd00::1]:5001")
    }

    @Test func defaultsAndDiscoveryChooseHTTPSWithoutHomeOrVPNInference() throws {
        for address in ["nas.example", "192.168.1.40", "diskstation.local", "100.64.0.20", "nas.tailnet.ts.net", "[fd00::1]"] {
            let url = try #require(SynologyClient.baseURL(from: address))
            #expect(url.scheme == "https")
            #expect(url.port == 5001)
            let candidates = SynologyClient.secureCandidates(for: address)
            #expect(!candidates.isEmpty)
            #expect(candidates.allSatisfy { $0.scheme == "https" })
        }
        let discovered = DiscoveredServer(name: "NAS", host: "192.168.1.40", port: 5000, model: nil)
        #expect(discovered.baseURL.scheme == "https")
        #expect(discovered.baseURL.port == 5001)
        #expect(discovered.address == "https://192.168.1.40:5001")
    }

    @Test func explicitPortsAndHTTPSelectionRemainExplicit() throws {
        #expect(SynologyClient.secureCandidates(for: "https://nas.example:8443").map(\.port) == [8443])
        #expect(SynologyClient.secureCandidates(for: "nas.example:8443").map(\.port) == [8443])
        #expect(SynologyClient.secureCandidates(for: "https://nas.example").map(\.port) == [443, 5001])
        #expect(SynologyClient.secureCandidates(for: "http://192.168.1.40:5000").isEmpty)
        #expect(SynologyClient.baseURL(from: "http://192.168.1.40:5000")?.scheme == "http")
        #expect(NASTransportSecurity.httpsAlternative(for: URL(string: "http://192.168.1.40:5000")!)?.port == 5001)
        #expect(SynologyClient.baseURL(from: "ftp://nas.example") == nil)
        #expect(SynologyClient.baseURL(from: "https://listener:password@nas.example") == nil)
    }

    @Test func HTTPPermissionIsLocalAndBoundToOneOrigin() throws {
        let suiteA = "skyr.transport.A.\(UUID().uuidString)"
        let suiteB = "skyr.transport.B.\(UUID().uuidString)"
        let deviceA = try #require(UserDefaults(suiteName: suiteA))
        let deviceB = try #require(UserDefaults(suiteName: suiteB))
        defer {
            deviceA.removePersistentDomain(forName: suiteA)
            deviceB.removePersistentDomain(forName: suiteB)
        }
        let url = URL(string: "http://nas.example:5000")!
        #expect(!NASTransportSecurity.isAllowed(url, defaults: deviceA))
        NASTransportSecurity.allowHTTP(url, defaults: deviceA)
        #expect(NASTransportSecurity.isAllowed(url, defaults: deviceA))
        #expect(NASTransportSecurity.isAllowed(URL(string: "http://NAS.EXAMPLE:5000/webapi/query.cgi")!, defaults: deviceA))
        #expect(!NASTransportSecurity.isAllowed(URL(string: "http://nas.example:8080")!, defaults: deviceA))
        #expect(!NASTransportSecurity.isAllowed(URL(string: "http://other.example:5000")!, defaults: deviceA))
        #expect(!NASTransportSecurity.isAllowed(url, defaults: deviceB))
        #expect(NASTransportSecurity.isAllowed(URL(string: "https://nas.example:5001")!, defaults: deviceB))
        NASTransportSecurity.revokeHTTP(url, defaults: deviceA)
        #expect(!NASTransportSecurity.isAllowed(url, defaults: deviceA))
    }

    @Test func redirectsRemainWithinApprovedOrigin() throws {
        let suite = "skyr.transport.redirects.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secure = URL(string: "https://nas.example/webapi/entry.cgi")!
        #expect(NASTransportSecurity.permitsRedirect(from: secure, to: URL(string: "https://NAS.EXAMPLE:443/webapi/auth.cgi")!, defaults: defaults))
        #expect(!NASTransportSecurity.permitsRedirect(from: secure, to: URL(string: "https://other.example/webapi/auth.cgi")!, defaults: defaults))
        #expect(!NASTransportSecurity.permitsRedirect(from: secure, to: URL(string: "https://nas.example:5001/webapi/auth.cgi")!, defaults: defaults))
        let local = URL(string: "http://nas.example/webapi/entry.cgi")!
        NASTransportSecurity.allowHTTP(local, defaults: defaults)
        #expect(!NASTransportSecurity.permitsRedirect(from: secure, to: local, defaults: defaults))
        #expect(NASTransportSecurity.permitsRedirect(from: local, to: URL(string: "http://nas.example:80/webapi/download.cgi")!, defaults: defaults))
    }

    @Test func savedHTTPSessionCannotBuildCredentialURLsWithoutLocalChoice() {
        let api = SynologyAPIDescriptor(path: "entry.cgi", minVersion: 1, maxVersion: 6)
        let saved = DSMSession(baseURL: URL(string: "http://unapproved-\(UUID().uuidString).example:5000")!, sid: "ordinary-test-session", apis: ["SYNO.API.Auth": api], account: "listener")
        #expect(saved.url(api: "SYNO.API.Auth", version: 1, method: "logout") == nil)
        #expect(saved.form(api: "SYNO.API.Auth", version: 1, method: "logout") == nil)
        let secure = DSMSession(baseURL: URL(string: "https://nas.example:5001")!, sid: "ordinary-test-session", apis: ["SYNO.API.Auth": api], account: "listener")
        #expect(secure.url(api: "SYNO.API.Auth", version: 1, method: "logout") != nil)
        #expect(secure.form(api: "SYNO.API.Auth", version: 1, method: "logout") != nil)
        #expect(secure.account == "listener")
    }

    @Test func savedHTTPLoginStopsBeforeNetworkWork() async {
        let url = URL(string: "http://unapproved-\(UUID().uuidString).example:5000")!
        do {
            _ = try await SynologyClient.login(baseURL: url, account: "listener", password: "ordinary-test-value", otpCode: nil)
            Issue.record("An unapproved HTTP login must require a local transport choice")
        } catch NASTransportError.httpApprovalRequired {
            // The shared login gate runs before API discovery or any credential request.
        } catch {
            Issue.record("Expected a transport choice, got \(error)")
        }
    }
}
