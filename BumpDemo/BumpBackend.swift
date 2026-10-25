import AuthenticationServices
import Combine
import Foundation
import Security
import UIKit

private struct DeviceCredentials: Codable {
    let participantId: String
    let token: String
}

private struct MeResponse: Decodable {
    let participantId: String
    let available: [String]
    let connected: [String: String?]
}

enum Network: String, CaseIterable, Identifiable {
    case instagram, linkedin, x

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instagram: "Instagram"
        case .linkedin: "LinkedIn"
        case .x: "X"
        }
    }

    var overlapPhrase: String {
        switch self {
        case .instagram, .x: "you both follow"
        case .linkedin: "mutual connections"
        }
    }
}

private struct LinkResponse: Decodable {
    let url: URL
}

struct SharedAccount: Decodable, Identifiable {
    let id: String
    let name: String
    let username: String?
    let profileUrl: URL?
}

struct NetworkOverlap: Decodable {
    let count: Int?
    let common: [SharedAccount]?
    let stale: Bool?
    let error: String?
}

private struct MeetingResponse: Decodable {
    let status: String
    let networks: [String: NetworkOverlap]?
}

private struct APIProblem: Decodable {
    let detail: String
}

private struct APIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum DeviceKeychain {
    static let service = "dev.autumn.bumpdemo.device"

    static func load() -> DeviceCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    static func save(_ credentials: DeviceCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-session"
        ]
        SecItemDelete(match as CFDictionary)
        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw APIError(message: "Could not save this phone's session.")
        }
    }
}

@MainActor
final class BumpBackend: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var participantID: String?
    @Published private(set) var available: [Network] = []
    @Published private(set) var connected: [Network: String] = [:]
    @Published private(set) var status = "Connecting to server…"
    @Published private(set) var overlaps: [(Network, NetworkOverlap)] = []
    @Published private(set) var linking: Network?
    /// True once startup has finished, whether or not it reached the server.
    @Published private(set) var loaded = false
    /// True once the server has compared both phones' accounts.
    @Published private(set) var comparisonReady = false

    /// Every account in common, across networks.
    var sharedAccounts: [SharedAccount] { overlaps.flatMap { $0.1.common ?? [] } }

    private var credentials: DeviceCredentials?
    private var authSession: ASWebAuthenticationSession?
    private var meetingTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private let session = URLSession.shared

    private var baseURL: URL? {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "BumpAPIBaseURL") as? String else { return nil }
        return URL(string: configured)
    }

    /// Overlapping calls share one run, so a fresh install never registers twice.
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { await performStart() }
        startTask = task
        await task.value
        startTask = nil
        loaded = true
    }

    private func performStart() async {
        do {
            if credentials != nil {
                try await refreshMe()
                return
            }
            if let saved = DeviceKeychain.load() {
                credentials = saved
                participantID = saved.participantId
                try await refreshMe()
            } else {
                let created: DeviceCredentials = try await request("/v1/participants", method: "POST", authorized: false)
                try DeviceKeychain.save(created)
                credentials = created
                participantID = created.participantId
                try await refreshMe()
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func connect(_ network: Network) {
        guard credentials != nil, linking == nil else { return }
        linking = network
        status = "Opening \(network.label) connection…"
        Task {
            do {
                let response: LinkResponse = try await request("/v1/\(network.rawValue)/link", method: "POST")
                let auth = ASWebAuthenticationSession(url: response.url, callbackURLScheme: "bumpdemo") {
                    [weak self] callbackURL, error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.authSession = nil
                        self.linking = nil
                        let callback = callbackURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                        let approved = callback?.queryItems?.contains(where: { $0.name == "ok" && $0.value == "1" }) == true
                        if approved {
                            do { try await self.refreshMe() }
                            catch { self.status = error.localizedDescription }
                        } else if error == nil {
                            self.status = "\(network.label) connection did not finish."
                        } else {
                            do { try await self.refreshMe() }
                            catch { self.status = "\(network.label) connection was canceled." }
                        }
                    }
                }
                auth.presentationContextProvider = self
                authSession = auth
                if !auth.start() {
                    authSession = nil
                    linking = nil
                    status = "Could not open \(network.label) sign-in."
                }
            } catch {
                linking = nil
                status = error.localizedDescription
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }

    func joinMeeting(_ meeting: BumpMeeting) {
        meetingTask?.cancel()
        overlaps = []
        comparisonReady = false
        status = "Comparing your accounts…"
        meetingTask = Task {
            do {
                let body = try JSONEncoder().encode(["peer_id": meeting.peerID])
                var response: MeetingResponse = try await request(
                    "/v1/meetings/\(meeting.id)/join", method: "POST", body: body
                )
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    if response.status == "ready", let networks = response.networks {
                        overlaps = Network.allCases.compactMap { network in networks[network.rawValue].map { (network, $0) } }
                        comparisonReady = true
                        let total = overlaps.reduce(0) { $0 + ($1.1.count ?? 0) }
                        status = total == 0 ? "No overlap found yet." : "Found \(total) people in common."
                        if overlaps.allSatisfy({ $0.1.error == nil }) { return }
                    } else {
                        status = response.status == "waiting_for_accounts"
                            ? "Connect the same network on both phones to compare."
                            : "Waiting for the other phone…"
                    }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    response = try await request("/v1/meetings/\(meeting.id)")
                }
                status = "Still waiting. Tap Restart pairing to try again."
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func clearMeeting() {
        meetingTask?.cancel()
        meetingTask = nil
        overlaps = []
        comparisonReady = false
        status = connectedSummary
    }

    private var connectedSummary: String {
        let names = Network.allCases.filter { connected[$0] != nil }.map(\.label)
        return names.isEmpty ? "Connect an account to compare." : "Connected: \(names.joined(separator: ", "))."
    }

    private func refreshMe() async throws {
        let me: MeResponse = try await request("/v1/me")
        participantID = me.participantId
        available = me.available.compactMap(Network.init(rawValue:))
        connected = Dictionary(uniqueKeysWithValues: me.connected.compactMap { key, value in
            Network(rawValue: key).map { ($0, value ?? "") }
        })
        status = connectedSummary
    }

    private func request<T: Decodable>(
        _ path: String, method: String = "GET", body: Data? = nil, authorized: Bool = true
    ) async throws -> T {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError(message: "Server URL is missing from the app build.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authorized {
            guard let credentials else { throw APIError(message: "Phone session is not ready.") }
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError(message: "No server response.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIProblem.self, from: data))?.detail ?? "Server error"
            if response.statusCode == 429 {
                let retry = response.value(forHTTPHeaderField: "Retry-After")
                throw APIError(message: "\(detail). Try again in \(retry ?? "a few") seconds.")
            }
            throw APIError(message: detail)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
