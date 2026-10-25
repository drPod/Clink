import SwiftUI

@main
struct BumpDemoApp: App {
    @StateObject private var coordinator = BumpCoordinator()
    @StateObject private var backend = BumpBackend()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .environmentObject(backend)
        }
    }
}

private struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: BumpCoordinator
    @EnvironmentObject private var backend: BumpBackend

    @State private var showingOverlap = false
    @State private var clinkID = UUID()
    @State private var demo: DemoClink?
    @State private var splashExpired = false
    /// Stays open until this person taps Clink again, even if the other phone resets first.
    @State private var clinkOpen = false
    /// The last result, kept so a reset from the other phone doesn't empty the screen.
    @State private var kept: [OverlapSection]?

    /// Backend messages that describe normal progress rather than a problem.
    private static func isRoutine(_ status: String) -> Bool {
        ["Connecting to server", "Opening ", "Connect an account", "Connected: "].contains(where: status.hasPrefix)
    }
    /// Backend messages about a clink in progress.
    private static func isMeetingStatus(_ status: String) -> Bool {
        ["Comparing", "Found ", "No overlap", "Waiting for", "Connect the same", "Still waiting"].contains(where: status.hasPrefix)
    }
    /// Coordinator messages worth showing on the home screen.
    private static let problemMarkers = ["Could not", "stopped", "does not support", "Check Local Network"]

    private var clinking: Bool { clinkOpen || demo != nil }
    /// Networks to offer; Instagram alone until the server says otherwise.
    private var networks: [Network] { backend.available.isEmpty ? [.instagram] : backend.available }
    private var liveSections: [OverlapSection] { backend.overlaps.map { OverlapSection(network: $0.0, overlap: $0.1) } }
    private var sections: [OverlapSection] {
        demo?.sections ?? (backend.comparisonReady ? liveSections : kept ?? [])
    }
    private var homeProblem: String? {
        if Self.problemMarkers.contains(where: coordinator.status.contains) { return coordinator.status }
        let status = backend.status
        return Self.isRoutine(status) || Self.isMeetingStatus(status) ? nil : status
    }

    #if DEBUG
    /// Launch with -skipOnboarding to see the home screen, -demoClink to also play a clink,
    /// or -demoOverlap to open the overlap sheet after it.
    private static let skipOnboarding = ProcessInfo.processInfo.arguments.contains("-skipOnboarding")
    private static let autoOverlap = ProcessInfo.processInfo.arguments.contains("-demoOverlap")
    private static let autoDemo = autoOverlap || ProcessInfo.processInfo.arguments.contains("-demoClink")
    #else
    private static let skipOnboarding = false
    private static let autoOverlap = false
    private static let autoDemo = false
    #endif

    var body: some View {
        ZStack {
            if !backend.loaded && !splashExpired {
                LiveBackground(style: .cream)
                    .overlay(Wordmark(size: 30))
            } else if backend.connected.isEmpty && !Self.skipOnboarding && !Self.autoDemo {
                OnboardingView(
                    networks: networks,
                    linking: backend.linking,
                    message: Self.isRoutine(backend.status) ? nil : backend.status,
                    onConnect: connect
                )
                .transition(.opacity)
            } else {
                HomeView(
                    distance: coordinator.distance,
                    paired: coordinator.distance != nil,
                    problem: homeProblem,
                    networks: networks,
                    connected: backend.connected,
                    linking: backend.linking,
                    onConnect: connect,
                    onRestart: { coordinator.restart() },
                    onDemoClink: demoAction
                )
                .transition(.opacity)
            }

            if clinking {
                ClinkView(
                    sections: sections,
                    ready: demo?.ready ?? (backend.comparisonReady || kept != nil),
                    message: demo == nil && !Self.isRoutine(backend.status) ? backend.status : nil,
                    onSeeAll: { showingOverlap = true },
                    onClinkAgain: clinkAgain
                )
                .id(clinkID)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: backend.loaded || splashExpired)
        .animation(.easeInOut(duration: 0.35), value: backend.connected.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: clinking)
        .sheet(isPresented: $showingOverlap) {
            OverlapView(
                sections: sections,
                onClinkAgain: clinkAgain
            )
        }
        .task {
            // Don't hold the splash for a slow server; the screen updates when it answers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { splashExpired = true }
            coordinator.start()
            await backend.start()
            if let participantID = backend.participantID { coordinator.setParticipantID(participantID) }
            if Self.autoDemo { demoAction?() }
            if Self.autoOverlap {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                showingOverlap = true
            }
        }
        .onChange(of: coordinator.bumped) { bumped in
            if bumped {
                clinkID = UUID()
                kept = nil
                clinkOpen = true
            } else if kept == nil {
                // The other phone reset before we had a result, so there is nothing to show.
                clinkOpen = false
                showingOverlap = false
            }
        }
        .onChange(of: backend.status) { _ in
            if clinkOpen, backend.comparisonReady { kept = liveSections }
        }
        .onChange(of: backend.comparisonReady) { ready in
            if clinkOpen, ready { kept = liveSections }
        }
        .onChange(of: backend.participantID) { participantID in
            if let participantID { coordinator.setParticipantID(participantID) }
        }
        .onChange(of: coordinator.meeting) { meeting in
            if let meeting { backend.joinMeeting(meeting) }
            else { backend.clearMeeting() }
        }
        .onChange(of: backend.connected) { _ in
            if let meeting = coordinator.meeting { backend.joinMeeting(meeting) }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // Picks up a link that finished in the browser.
            Task { await backend.start() }
            if !clinking { coordinator.restart() }
        }
    }

    private func connect(_ network: Network) {
        if backend.participantID == nil { Task { await backend.start() } }
        else { backend.connect(network) }
    }

    private func clinkAgain() {
        showingOverlap = false
        if demo != nil { demo = nil; return }
        clinkOpen = false
        kept = nil
        coordinator.reset()
    }

    private var demoAction: (() -> Void)? {
        #if DEBUG
        return {
            clinkID = UUID()
            demo = DemoClink()
            // Pretend the server takes a moment to compare.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { demo?.ready = true }
        }
        #else
        return nil
        #endif
    }
}

/// A fake clink for trying the animation without two phones.
private struct DemoClink {
    var sections = OverlapSection.samples
    var ready = false
}
