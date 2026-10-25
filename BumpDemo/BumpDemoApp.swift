import SwiftUI

@main
struct BumpDemoApp: App {
    @StateObject private var coordinator = BumpCoordinator()
    @StateObject private var backend = BumpBackend()

    var body: some Scene {
        WindowGroup {
            BumpView()
                .environmentObject(coordinator)
                .environmentObject(backend)
        }
    }
}

private struct BumpView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: BumpCoordinator
    @EnvironmentObject private var backend: BumpBackend

    var body: some View {
        ZStack {
            (coordinator.bumped ? Color(red: 0.19, green: 0.76, blue: 0.57) : Color(red: 0.09, green: 0.10, blue: 0.16))
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: coordinator.bumped ? "sparkles" : "iphone.radiowaves.left.and.right")
                    .font(.system(size: 76, weight: .light))
                    .symbolRenderingMode(.hierarchical)

                Text(coordinator.bumped ? "Connected!" : "Bring phones together")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(coordinator.status)
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.75))

                if backend.instagramConnected {
                    Label("Instagram connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if backend.participantID != nil {
                    Button(backend.linking ? "Connecting…" : "Connect Instagram") {
                        backend.connectInstagram()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(backend.linking)
                } else {
                    Button("Retry server") { Task { await backend.start() } }
                        .buttonStyle(.bordered)
                }

                Text(backend.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))

                if !backend.sharedAccounts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(backend.sharedAccounts) { account in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name).font(.headline)
                                    if let username = account.username {
                                        Text("@\(username)").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                if backend.resultIsStale {
                    Text("Showing a cached Instagram list")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }

                if let distance = coordinator.distance, !coordinator.bumped {
                    Text(String(format: "%.2f m apart", distance))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .padding(.top, 12)
                }

                Spacer()

                if coordinator.bumped {
                    Button("Try again") { coordinator.reset() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .controlSize(.large)
                }

                Button("Restart pairing") { coordinator.restart() }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))

                Text("Demo ID \(coordinator.shortID)  ·  Keep this app open on both phones")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .padding(32)
        }
        .task {
            coordinator.start()
            await backend.start()
            if let participantID = backend.participantID { coordinator.setParticipantID(participantID) }
        }
        .onChange(of: backend.participantID) { participantID in
            if let participantID { coordinator.setParticipantID(participantID) }
        }
        .onChange(of: coordinator.meeting) { meeting in
            if let meeting { backend.joinMeeting(meeting) }
            else { backend.clearMeeting() }
        }
        .onChange(of: backend.instagramConnected) { connected in
            if connected, let meeting = coordinator.meeting { backend.joinMeeting(meeting) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                coordinator.restart()
                Task { await backend.start() }
            }
        }
    }
}
