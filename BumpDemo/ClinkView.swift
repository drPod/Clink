import SwiftUI
import UIKit

/// The CLINK! moment: circles collide, the overlap lights up, and the shared accounts burst out into a grid.
struct ClinkView: View {
    var sections: [OverlapSection]
    /// True once the server has compared both lists.
    var ready: Bool
    var message: String?
    var onSeeAll: () -> Void
    var onClinkAgain: () -> Void

    @State private var start = Date()
    @State private var readyAt: Double?

    private static let impact = 0.7
    private var shown: [(Network, SharedAccount)] { Array(sections.tagged.prefix(12)) }
    private var total: Int { sections.total }

    /// "on Instagram", "across Instagram and LinkedIn", and so on.
    private var across: String {
        let names = sections.filter { $0.count > 0 }.map(\.network.label)
        switch names.count {
        case 0: return sections.isEmpty ? "Connect the same network on both phones." : "Nothing in common yet."
        case 1: return "on \(names[0])"
        default: return "across " + names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            GeometryReader { proxy in
                scene(t: t, w: proxy.size.width, h: proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            start = Date()
            readyAt = ready ? 0 : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.impact) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
            }
        }
        .onChange(of: ready) { isReady in
            if isReady, readyAt == nil { readyAt = Date().timeIntervalSince(start) }
        }
    }

    @ViewBuilder
    private func scene(t: Double, w: CGFloat, h: CGFloat) -> some View {
        let approach = Ease.cubicIn(Ease.segment(t, 0, Self.impact))
        let settle = Ease.segment(t, Self.impact, Self.impact + 0.35)
        let squish = t < Self.impact ? 0 : sin(settle * .pi) * (1 - settle)
        let flash = t < Self.impact ? 0 : exp(-(t - Self.impact) * 5)
        // Wait for the server before the grid comes out.
        let riseStart = max(1.7, (readyAt ?? 1e9) + 0.2)
        let rise = Ease.inOut(Ease.segment(t, riseStart, riseStart + 0.8))

        let size = lerp(min(176, w * 0.45), min(132, w * 0.34), rise)
        let overlap = size * 0.42 * CGFloat(approach) + size * 0.16 * CGFloat(squish) - (1 - CGFloat(approach)) * w * 0.66
        let cx = w / 2
        let cy = lerp(h * 0.40, h * 0.25, rise)
        let leftX = cx - (size * 2 - overlap) / 2
        let lensFaceSize: CGFloat = 14

        ZStack {
            LiveBackground(style: .blue, flash: flash)

            Wordmark(color: .clinkCream, lens: .clinkCream, size: 20)
                .position(x: cx, y: h * 0.085)

            PersonCircle(colors: PersonCircle.you)
                .frame(width: size)
                .position(x: leftX + size / 2, y: cy)
            PersonCircle(colors: PersonCircle.them)
                .frame(width: size)
                .position(x: leftX + size - overlap + size / 2, y: cy)

            if overlap > 0 {
                Lens(size: size, overlap: overlap, leftX: leftX)
                    .fill(Color.clinkCream)
                    .frame(width: w, height: size)
                    .shadow(color: .clinkCream.opacity(0.6 + 0.4 * flash), radius: 22 + 30 * flash)
                    .position(x: w / 2, y: cy)
            }

            // Faces pop into the lens, then fly out into the grid.
            let faceCount = readyAt == nil ? 12 : shown.count
            ForEach(0..<faceCount, id: \.self) { i in
                let pop = Ease.outBack(Ease.segment(t, 0.95 + Double(i) * 0.04, 1.25 + Double(i) * 0.04))
                let fly = Ease.inOut(Ease.segment(t, riseStart + 0.05 + Double(i) * 0.035, riseStart + 0.75 + Double(i) * 0.035))
                let lensPoint = CGPoint(x: cx + CGFloat(i % 3 - 1) * lensFaceSize * 1.2,
                                        y: cy + (CGFloat(i / 3) - 1.5) * lensFaceSize * 1.2
                                            + CGFloat(sin(t * 3 + Double(i))) * (readyAt == nil ? 1.5 : 0))
                let columns = min(4, max(1, shown.count))
                let gridPoint = CGPoint(x: cx + (CGFloat(i % 4) - CGFloat(columns - 1) / 2) * min(84, w * 0.21),
                                        y: h * 0.50 + CGFloat(i / 4) * 92)
                let d = lerp(lensFaceSize, 62, fly)
                let tagged = i < shown.count ? shown[i] : nil
                let name = tagged?.1.name ?? ""

                VStack(spacing: 6) {
                    AccountFace(name: name, index: i, size: d)
                        .overlay(Circle().stroke(Color.clinkCream, lineWidth: 2.5 * CGFloat(fly)))
                        .overlay(alignment: .bottomTrailing) {
                            if let network = tagged?.0, fly > 0.6 {
                                NetworkBadge(network: network, size: 22)
                                    .scaleEffect(CGFloat(Ease.outBack(Ease.segment(fly, 0.6, 1))))
                                    .offset(x: 4, y: 4)
                            }
                        }
                    if fly > 0.95, let tagged {
                        Text(tagged.1.username.map { tagged.0 == .linkedin ? $0 : "@\($0)" } ?? name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.clinkCream.opacity(0.85))
                            .lineLimit(1)
                            .frame(width: 80)
                    }
                }
                .scaleEffect(CGFloat(pop))
                .position(x: lerp(lensPoint.x, gridPoint.x, fly),
                          y: lerp(lensPoint.y, gridPoint.y, fly) - CGFloat(sin(fly * .pi)) * 40 + (fly > 0.95 ? 10 : 0))
            }

            // Title arrives once the circles have risen.
            let title = Ease.inOut(Ease.segment(t, riseStart + 0.55, riseStart + 1.1))
            Text("Clink!")
                .font(ClinkFont.display(40))
                .foregroundStyle(Color.clinkCream)
                .opacity(title)
                .offset(y: 12 * (1 - title))
                .position(x: cx, y: cy + size / 2 + 44)

            // While the server compares, say so under the circles.
            if readyAt == nil && t > 1.3 {
                Text(message ?? "Finding your overlap…")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.clinkCream.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .position(x: cx, y: cy + size / 2 + 56)
                    .transition(.opacity)
            }

            let footer = Ease.inOut(Ease.segment(t, riseStart + 0.85, riseStart + 1.35))
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(total)").font(ClinkFont.display(34))
                        Text(total == 1 ? "person in common" : "people in common")
                            .font(.system(size: 17, weight: .medium))
                    }
                    Text(across)
                        .font(.system(size: 14))
                        .opacity(0.75)
                }
                .foregroundStyle(Color.clinkCream)

                Button(total == 0 ? "Clink again" : "See everything you share") {
                    total == 0 ? onClinkAgain() : onSeeAll()
                }
                .buttonStyle(PillButtonStyle(fill: .clinkCream, text: .clinkNavy))

                Button("Clink again", action: onClinkAgain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.clinkCream.opacity(0.75))
                    .opacity(total == 0 ? 0 : 1)
            }
            .frame(width: w - 52)
            .opacity(footer)
            .offset(y: 20 * (1 - footer))
            .allowsHitTesting(footer > 0.5)
            .position(x: cx, y: h - 120)
        }
    }
}

extension OverlapSection {
    static let samples: [OverlapSection] = [
        .init(network: .instagram, accounts: SharedAccount.make("ig", [
            ("Phoebe Bridgers", "phoebebridgers"), ("Tartine Bakery", "tartinebakery"), ("NASA", "nasa"),
            ("A24", "a24"), ("Outside Lands", "outsidelands"), ("Kinfolk", "kinfolk"), ("Blue Bottle", "bluebottle"),
            ("SFMOMA", "sfmoma")
        ]) { "https://instagram.com/\($0)" }, count: 8),
        .init(network: .linkedin, accounts: SharedAccount.make("li", [
            ("Maya Chen", "mayachen"), ("Jordan Alvarez", "jalvarez"), ("Priya Natarajan", "priyan")
        ]) { "https://linkedin.com/in/\($0)" }, count: 3),
        .init(network: .x, accounts: SharedAccount.make("x", [
            ("Hacker News", "hackernews"), ("Figma", "figma")
        ]) { "https://x.com/\($0)" }, count: 2)
    ]
}

extension SharedAccount {
    static func make(_ prefix: String, _ pairs: [(String, String)], url: (String) -> String) -> [SharedAccount] {
        pairs.enumerated().map { i, pair in
            SharedAccount(id: "\(prefix)\(i)", name: pair.0, username: pair.1, profileUrl: URL(string: url(pair.1)))
        }
    }
}

#Preview("Clink") {
    ClinkView(sections: OverlapSection.samples, ready: true, message: nil, onSeeAll: {}, onClinkAgain: {})
}
