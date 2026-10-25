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
    let instagramConnected: Bool
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

private struct MeetingResponse: Decodable {
    let status: String
    let count: Int?
    let common: [SharedAccount]?
    let asOf: Int?
    let stale: Bool?
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
    @Published private(set) var instagramConnected = false
    @Published private(set) var status = "Connecting to server…"
    @Published private(set) var sharedAccounts: [SharedAccount] = []
    @Published private(set) var resultIsStale = false
    @Published private(set) var linking = false

    private var credentials: DeviceCredentials?
    private var authSession: ASWebAuthenticationSession?
    private var meetingTask: Task<Void, Never>?
    private let session = URLSession.shared

    private var baseURL: URL? {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "BumpAPIBaseURL") as? String else { return nil }
        return URL(string: configured)
    }

    func start() async {
        guard credentials == nil else { return }
        do {
            if let saved = DeviceKeychain.load() {
                credentials = saved
                participantID = saved.participantId
                try await refreshMe()
            } else {
                let created: DeviceCredentials = try await request("/v1/participants", method: "POST", authorized: false)
                try DeviceKeychain.save(created)
                credentials = created
                participantID = created.participantId
                status = "Ready to connect Instagram."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func connectInstagram() {
        guard credentials != nil, !linking else { return }
        linking = true
        status = "Opening Instagram connection…"
        Task {
            do {
                let response: LinkResponse = try await request("/v1/instagram/link", method: "POST")
                let auth = ASWebAuthenticationSession(url: response.url, callbackURLScheme: "bumpdemo") {
                    [weak self] callbackURL, error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.authSession = nil
                        self.linking = false
                        let callback = callbackURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                        let approved = callback?.queryItems?.contains(where: { $0.name == "ok" && $0.value == "1" }) == true
                        if approved {
                            do { try await self.refreshMe() }
                            catch { self.status = error.localizedDescription }
                        } else if error == nil {
                            self.status = "Instagram connection did not finish."
                        } else {
                            self.status = "Instagram connection was canceled."
                        }
                    }
                }
                auth.presentationContextProvider = self
                authSession = auth
                if !auth.start() {
                    authSession = nil
                    linking = false
                    status = "Could not open Instagram sign-in."
                }
            } catch {
                linking = false
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
        sharedAccounts = []
        status = "Checking what you both follow…"
        meetingTask = Task {
            do {
                let body = try JSONEncoder().encode(["peer_id": meeting.peerID])
                var response: MeetingResponse = try await request(
                    "/v1/meetings/\(meeting.id)/join", method: "POST", body: body
                )
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    if response.status == "ready" {
                        sharedAccounts = response.common ?? []
                        resultIsStale = response.stale ?? false
                        status = sharedAccounts.isEmpty ? "No shared accounts found." : "You both follow \(sharedAccounts.count) accounts."
                        return
                    }
                    status = response.status == "waiting_for_instagram"
                        ? "Connect Instagram on both phones to see your overlap."
                        : "Waiting for the other phone…"
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
        sharedAccounts = []
        resultIsStale = false
        status = instagramConnected ? "Instagram connected." : "Ready to connect Instagram."
    }

    private func refreshMe() async throws {
        let me: MeResponse = try await request("/v1/me")
        participantID = me.participantId
        instagramConnected = me.instagramConnected
        status = me.instagramConnected ? "Instagram connected." : "Ready to connect Instagram."
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
                throw APIError(message: "Instagram is rate limited. Try again in \(retry ?? "a few") seconds.")
            }
            throw APIError(message: detail)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
