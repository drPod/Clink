import SwiftUI
import UIKit

/// Waiting to clink. The other person's circle slides in as the phones get closer.
struct HomeView: View {
    /// Meters to the other phone, nil until paired.
    var distance: Float?
    var paired: Bool
    var problem: String?
    var networks: [Network] = []
    /// Linked networks and their usernames.
    var connected: [Network: String] = [:]
    var linking: Network?
    var onConnect: (Network) -> Void = { _ in }
    var onRestart: () -> Void
    var onDemoClink: (() -> Void)? = nil

    @State private var lastTick = 0

    private var closeness: Double {
        guard let distance else { return 0 }
        // 1.5 m away is 0, 25 cm (the clink distance) is 1.
        return Ease.clamp((1.5 - Double(distance)) / 1.25)
    }

    private var headline: String {
        if !paired { return "Hold near a friend." }
        switch closeness {
        case ..<0.35: return "Someone's here."
        case ..<0.8: return "Closer…"
        default: return "Almost…"
        }
    }

    private var caption: String {
        if let problem { return problem }
        return paired ? "Touch the tops of your phones together." : "They need Clink open too."
    }

    var body: some View {
        ZStack {
            LiveBackground(style: .cream)

            VStack(spacing: 0) {
                HStack {
                    Wordmark()
                    Spacer()
                    Menu {
                        Button(action: onRestart) { Label("Restart pairing", systemImage: "arrow.clockwise") }
                        if let onDemoClink {
                            Button(action: onDemoClink) { Label("Demo a clink", systemImage: "sparkles") }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.clinkNavy)
                            .frame(width: 44, height: 44)
                            .background(Color.clinkNavy.opacity(0.06), in: Circle())
                    }
                }
                .padding(.top, 12)

                Spacer()

                ApproachVenn(size: 150, closeness: paired ? closeness : 0, showsThem: paired)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: closeness)
                    .animation(.spring(response: 0.7, dampingFraction: 0.7), value: paired)

                Spacer()

                VStack(spacing: 10) {
                    Text(headline)
                        .font(ClinkFont.display(36))
                        .foregroundStyle(Color.clinkNavy)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: headline)
                    Text(caption)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.clinkNavy.opacity(problem == nil ? 0.7 : 0.9))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if !networks.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(networks) { network in chip(network) }
                        }
                        .padding(.top, 14)
                    }
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 26)
        }
        // Haptic ticks get stronger as the phones approach.
        .onChange(of: Int(closeness * 5)) { tick in
            guard tick > lastTick else { lastTick = tick; return }
            lastTick = tick
            let style: UIImpactFeedbackGenerator.FeedbackStyle = tick >= 4 ? .heavy : tick >= 2 ? .medium : .light
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }
}

extension HomeView {
    /// A linked network shows filled; tap an unlinked one to add it.
    @ViewBuilder
    private func chip(_ network: Network) -> some View {
        let username = connected[network]
        Button { onConnect(network) } label: {
            HStack(spacing: 6) {
                if linking == network {
                    ProgressView().controlSize(.mini).tint(username == nil ? .clinkNavy : .clinkCream)
                } else {
                    Image(systemName: username == nil ? "plus" : "checkmark").font(.system(size: 11, weight: .bold))
                }
                NetworkGlyph(network: network, size: 13)
                Text(network.label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(username == nil ? Color.clinkNavy : Color.clinkCream)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(username == nil ? Color.clinkCream.opacity(0.6) : network.tint, in: Capsule())
            .overlay(Capsule().stroke(Color.clinkNavy.opacity(username == nil ? 0.18 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(username != nil || linking != nil)
    }
}

/// Your circle pulses in the middle; theirs arrives from the right and overlaps more as they get closer.
struct ApproachVenn: View {
    var size: CGFloat
    var closeness: Double
    var showsThem: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 2.2) + 1) / 2
            let overlap = size * 0.42 * CGFloat(closeness)
            // Before pairing, center your circle alone; once paired, both share the center.
            let youX: CGFloat = showsThem ? -(size - overlap) / 2 : 0
            let themX: CGFloat = showsThem ? (size - overlap) / 2 : size * 1.6

            ZStack {
                // Ripples from your circle while searching.
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(Color.clinkBlue.opacity(0.35 * (1 - phase)), lineWidth: 2)
                        .frame(width: size * (1 + 0.9 * phase), height: size * (1 + 0.9 * phase))
                        .offset(x: youX)
                }
                .opacity(showsThem ? 0.4 : 1)

                PersonCircle(colors: PersonCircle.you)
                    .frame(width: size)
                    .scaleEffect(1 + 0.025 * pulse)
                    .offset(x: youX)

                PersonCircle(colors: PersonCircle.them)
                    .frame(width: size)
                    .offset(x: themX)
                    .opacity(showsThem ? 1 : 0)

                if showsThem && overlap > 1 {
                    Lens(size: size, overlap: overlap, leftX: 0)
                        .fill(Color.clinkCream)
                        .frame(width: size * 2 - overlap, height: size)
                        .shadow(color: .clinkCream.opacity(0.4 + 0.6 * closeness), radius: 8 + 20 * closeness)
                }
            }
            // Flexible width so the ripples can spill past the edges without widening the screen.
            .frame(maxWidth: .infinity, minHeight: size * 1.9, maxHeight: size * 1.9)
            .shadow(color: .clinkNavy.opacity(0.2), radius: 20, y: 10)
        }
    }
}

#Preview("Searching") {
    HomeView(distance: nil, paired: false, problem: nil, networks: Network.allCases, connected: [.instagram: "darsh"], onRestart: {})
}

#Preview("Getting close") {
    HomeView(distance: 0.6, paired: true, problem: nil, onRestart: {})
}
