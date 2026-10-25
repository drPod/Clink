import Foundation
import Combine
import Network
import NearbyInteraction
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.autumn.bumpdemo", category: "bump")

struct BumpMeeting: Equatable {
    let id: String
    let peerID: String
}

final class BumpCoordinator: NSObject, ObservableObject, NISessionDelegate {
    @Published private(set) var status = "Starting…"
    @Published private(set) var distance: Float?
    @Published private(set) var bumped = false
    @Published private(set) var meeting: BumpMeeting?

    private var id = UUID().uuidString.lowercased()
    var shortID: String { String(id.prefix(4)).uppercased() }

    private var niSession: NISession?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var closeReadings = 0
    private var started = false
    private var participantID: String?
    private var peerID: String?
    private var meetingID: String?
    private var isInitiator = false
    private var discoveryRetries = 0

    private struct Message: Codable {
        let kind: String
        var token: String? = nil
        var participantID: String? = nil
        var meetingID: String? = nil
    }

    func setParticipantID(_ participantID: String) {
        self.participantID = participantID
        if connection != nil { sendHello() }
    }

    func start() {
        guard !started else { return }
        started = true

        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            status = "This iPhone does not support UWB distance measurement."
            return
        }

        makeSession()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        do {
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: id, type: "_bumpdemo._tcp")
            listener.newConnectionHandler = { [weak self] peer in
                DispatchQueue.main.async { self?.accept(peer) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    guard let self, self.listener === listener else { return }
                    if case .failed = state { self.retryDiscovery() }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = "Could not advertise this phone: \(error.localizedDescription)"
            return
        }

        let browser = NWBrowser(for: .bonjour(type: "_bumpdemo._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.consider(results) }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, self.browser === browser else { return }
                if case .failed = state { self.retryDiscovery() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        status = "Waiting for the other phone…"
    }

    private func retryDiscovery() {
        guard started else { return }
        guard discoveryRetries < 3 else {
            status = "Local discovery stopped. Check Local Network access, then tap Restart pairing."
            return
        }
        discoveryRetries += 1
        status = "Local discovery interrupted. Reconnecting…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.started else { return }
            self.restart(resetRetries: false)
        }
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  name != id,
                  id < name else { continue }
            status = "Found another phone. Pairing…"
            attach(NWConnection(to: result.endpoint, using: peerParameters()), isInitiator: true)
            return
        }
    }

    private func peerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    private func makeSession() {
        niSession?.delegate = nil
        niSession?.invalidate()
        let session = NISession()
        session.delegate = self
        niSession = session
    }

    private func accept(_ peer: NWConnection) {
        guard connection == nil else { peer.cancel(); return }
        status = "Found another phone. Pairing…"
        attach(peer, isInitiator: false)
    }

    private func attach(_ peer: NWConnection, isInitiator: Bool) {
        connection = peer
        self.isInitiator = isInitiator
        meetingID = isInitiator ? UUID().uuidString.lowercased() : nil
        peer.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self, self.connection === peer else { return }
                switch state {
                case .ready:
                    self.discoveryRetries = 0
                    self.status = "Connected. Starting distance measurement…"
                    self.sendToken()
                    self.sendHello()
                    self.receive()
                case .failed(let error):
                    self.disconnected("Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.disconnected("Other phone disconnected.")
                default: break
                }
            }
        }
        peer.start(queue: .main)
    }

    private func sendToken() {
        guard let token = niSession?.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            status = "Could not create a nearby session."
            return
        }
        send(Message(kind: "token", token: data.base64EncodedString()))
    }

    private func sendHello() {
        guard let participantID else { return }
        send(Message(kind: "hello", participantID: participantID, meetingID: meetingID))
    }

    private func send(_ message: Message) {
        guard let connection = connection,
              var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self = self, self.connection === connection else { return }
                if let data = data { self.receiveBuffer.append(data) }
                while let newline = self.receiveBuffer.firstIndex(of: 0x0A) {
                    let line = self.receiveBuffer.prefix(upTo: newline)
                    self.receiveBuffer.removeSubrange(...newline)
                    if let message = try? JSONDecoder().decode(Message.self, from: line) {
                        self.handle(message)
                    }
                }
                if isComplete || error != nil {
                    self.disconnected("Other phone disconnected.")
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: Message) {
        switch message.kind {
        case "token":
            guard let encoded = message.token,
                  let data = Data(base64Encoded: encoded),
                  let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
                status = "Could not read the other phone's nearby token."
                return
            }
            niSession?.run(NINearbyPeerConfiguration(peerToken: token))
            status = "Paired. Bring the phones together."
        case "bump":
            showBump()
        case "hello":
            guard let participantID = message.participantID,
                  UUID(uuidString: participantID) != nil else { return }
            peerID = participantID
            if let incomingID = message.meetingID, UUID(uuidString: incomingID) != nil, !isInitiator {
                meetingID = incomingID
            }
            if bumped { publishMeeting() }
        case "reset":
            reset(sendToPeer: false)
        default: break
        }
    }

    private func disconnected(_ reason: String) {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        distance = nil
        closeReadings = 0
        peerID = nil
        meetingID = nil
        isInitiator = false
        makeSession()
        if !bumped { status = reason + " Waiting to reconnect…" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.connection == nil,
                  let browser = self.browser else { return }
            self.consider(browser.browseResults)
        }
    }

    func restart(resetRetries: Bool = true) {
        if resetRetries { discoveryRetries = 0 }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        niSession?.delegate = nil
        niSession?.invalidate()
        niSession = nil
        receiveBuffer.removeAll()
        distance = nil
        closeReadings = 0
        bumped = false
        meeting = nil
        peerID = nil
        meetingID = nil
        isInitiator = false
        started = false
        id = UUID().uuidString.lowercased()
        start()
    }

    func reset() { reset(sendToPeer: true) }

    private func reset(sendToPeer: Bool) {
        if sendToPeer { send(Message(kind: "reset", token: nil)) }
        bumped = false
        meeting = nil
        closeReadings = 0
        status = connection == nil ? "Waiting for the other phone…" : "Paired. Bring the phones together."
    }

    private func showBump() {
        guard !bumped else { return }
        bumped = true
        status = "The two phones found each other."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        publishMeeting()
    }

    private func publishMeeting() {
        guard let peerID, let meetingID, participantID != nil else { return }
        meeting = BumpMeeting(id: meetingID, peerID: peerID)
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        DispatchQueue.main.async {
            guard self.niSession === session, self.connection != nil else { return }
            guard let measured = nearbyObjects.compactMap(\.distance).first else { return }
            self.distance = measured
            guard !self.bumped else { return }
            self.closeReadings = measured < 0.25 ? self.closeReadings + 1 : 0
            log.info("distance \(measured, format: .fixed(precision: 3)) close \(self.closeReadings)")
            if self.closeReadings >= 2 {
                self.showBump()
                self.send(Message(kind: "bump", token: nil))
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        DispatchQueue.main.async {
            guard self.niSession === session else { return }
            log.info("peer removed \(reason == .timeout ? "timeout" : "peerEnded")")
            self.distance = nil
            self.closeReadings = 0
            guard reason == .timeout, let config = session.configuration else { return }
            session.run(config)
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        DispatchQueue.main.async {
            guard self.niSession === session else { return }
            self.status = "Nearby Interaction stopped: \(error.localizedDescription). Tap Restart pairing."
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        DispatchQueue.main.async { if !self.bumped { self.status = "Keep Clink open on both phones." } }
    }

    func sessionSuspensionEnded(_ session: NISession) {
        DispatchQueue.main.async {
            if let config = session.configuration { session.run(config) }
        }
    }
}
