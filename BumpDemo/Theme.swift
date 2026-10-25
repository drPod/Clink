import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let clinkBlue = Color(hex: 0x3139FB)
    static let clinkDeep = Color(hex: 0x2404AA)
    static let clinkNavy = Color(hex: 0x000354)
    static let clinkCream = Color(hex: 0xFFFCEC)
    static let clinkSky = Color(hex: 0x96C4FF)
    static let clinkRed = Color(hex: 0xFB3A4D)
    static let clinkRose = Color(hex: 0xFF8A80)
}

enum ClinkFont {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .serif) }
}

// MARK: Grain

private let grainTile: UIImage = {
    let size = 128
    var seed: UInt64 = 42
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 33
    }
    return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
        for _ in 0..<(size * size / 3) {
            let x = Double(next() % UInt64(size)), y = Double(next() % UInt64(size))
            (next() % 2 == 0 ? UIColor.white : UIColor.black).setFill()
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
}()

struct Grain: View {
    var opacity = 0.08

    var body: some View {
        Image(uiImage: grainTile)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}

// MARK: Living background

/// Slow drifting blobs of blue, sky and red behind every screen.
struct LiveBackground: View {
    enum Style { case cream, blue }
    var style: Style
    /// Adds a cream flash from the center, 0...1.
    var flash: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                ZStack {
                    switch style {
                    case .cream:
                        Color.clinkCream
                        blob(.clinkBlue.opacity(0.22), w * 0.9, x: w * (0.25 + 0.12 * sin(t * 0.21)), y: h * (0.30 + 0.06 * cos(t * 0.17)))
                        blob(.clinkRed.opacity(0.20), w * 0.8, x: w * (0.78 + 0.10 * cos(t * 0.19)), y: h * (0.42 + 0.08 * sin(t * 0.23)))
                        blob(.clinkSky.opacity(0.35), w * 0.7, x: w * (0.55 + 0.15 * sin(t * 0.13 + 2)), y: h * (0.12 + 0.05 * sin(t * 0.29)))
                    case .blue:
                        LinearGradient(colors: [.clinkBlue, .clinkDeep], startPoint: .top, endPoint: .bottom)
                        blob(.clinkSky.opacity(0.55), w * 1.0, x: w * (0.20 + 0.14 * sin(t * 0.23)), y: h * (0.22 + 0.07 * cos(t * 0.19)))
                        blob(.clinkRed.opacity(0.75), w * 1.1, x: w * (0.92 + 0.10 * cos(t * 0.17)), y: h * (0.52 + 0.10 * sin(t * 0.21)))
                        blob(.clinkBlue.opacity(0.8), w * 0.9, x: w * (0.40 + 0.18 * cos(t * 0.11 + 1)), y: h * (0.85 + 0.05 * sin(t * 0.27)))
                    }
                    if flash > 0 {
                        RadialGradient(colors: [Color.clinkCream.opacity(0.85 * flash), .clear],
                                       center: .center, startRadius: 0, endRadius: 260 + 320 * (1 - flash))
                    }
                }
            }
        }
        .overlay(Grain(opacity: style == .blue ? 0.12 : 0.06))
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, _ diameter: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.22)
            .position(x: x, y: y)
    }
}

// MARK: Overlap shapes

/// The lens where two equal circles of diameter `size` meet, with the left circle at `leftX`.
struct Lens: Shape {
    var size: CGFloat
    var overlap: CGFloat
    var leftX: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = size / 2, d = size - overlap
        guard overlap > 0, d >= 0 else { return path }
        let h = (r * r - d * d / 4).squareRoot()
        let theta = Double(atan2(h, d / 2))
        let c1 = CGPoint(x: leftX + r, y: rect.midY)
        let c2 = CGPoint(x: leftX + r + d, y: rect.midY)
        let steps = 40
        // Right edge of the left circle, top to bottom.
        for i in 0...steps {
            let a = -theta + 2 * theta * Double(i) / Double(steps)
            let p = CGPoint(x: c1.x + r * CGFloat(cos(a)), y: c1.y + r * CGFloat(sin(a)))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        // Left edge of the right circle, bottom to top.
        for i in 0...steps {
            let a = (.pi - theta) + 2 * theta * Double(i) / Double(steps)
            path.addLine(to: CGPoint(x: c2.x + r * CGFloat(cos(a)), y: c2.y + r * CGFloat(sin(a))))
        }
        path.closeSubpath()
        return path
    }
}

/// A person's circle. Shows a silhouette until we have their photo.
struct PersonCircle: View {
    var colors: [Color]
    var ring: Color = .clinkCream

    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Image(systemName: "person.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: s * 0.72)
                        .offset(y: s * 0.16)
                )
                .clipShape(Circle())
                .overlay(Circle().stroke(ring, lineWidth: max(2, s * 0.024)))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension PersonCircle {
    static let you: [Color] = [.clinkSky, .clinkBlue]
    static let them: [Color] = [.clinkRose, .clinkRed]
}

/// A shared account: an initial on a color from the palette.
struct AccountFace: View {
    var name: String
    var index: Int
    var size: CGFloat

    private static let palettes: [[Color]] = [
        [.clinkSky, .clinkBlue], [.clinkRose, .clinkRed], [.clinkBlue, .clinkDeep],
        [.clinkRed, .clinkDeep], [.clinkSky, .clinkDeep], [.clinkBlue, .clinkNavy]
    ]

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: Self.palettes[index % Self.palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Text(name.first.map { String($0).uppercased() } ?? "•")
                    .font(.system(size: size * 0.42, weight: .bold, design: .serif))
                    .foregroundStyle(Color.clinkCream)
            )
            .frame(width: size, height: size)
    }
}

/// The logo: two outlined circles with a filled overlap.
struct ClinkMark: View {
    var line: Color = .clinkNavy
    var lens: Color = .clinkRed
    var size: CGFloat = 20

    var body: some View {
        let overlap = size * 0.45
        ZStack(alignment: .leading) {
            Lens(size: size, overlap: overlap).fill(lens)
            Circle().stroke(line, lineWidth: size * 0.11).frame(width: size, height: size)
            Circle().stroke(line, lineWidth: size * 0.11).frame(width: size, height: size).offset(x: size - overlap)
        }
        .frame(width: size * 2 - overlap, height: size)
    }
}

struct Wordmark: View {
    var color: Color = .clinkNavy
    var lens: Color = .clinkRed
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: size * 0.33) {
            ClinkMark(line: color, lens: lens, size: size * 0.82)
            Text("clink").font(ClinkFont.display(size)).foregroundStyle(color)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color = .clinkBlue
    var text: Color = .clinkCream

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(fill, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A quieter pill for secondary choices.
struct OutlinePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.clinkNavy)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.clinkCream.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(Color.clinkNavy.opacity(0.18), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: Timing helpers for hand-driven animations

enum Ease {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func segment(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func cubicIn(_ x: Double) -> Double { x * x * x }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func outBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }

/// Only the bottom corners rounded; UnevenRoundedRectangle needs iOS 17.
struct BottomRounded: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.bottomLeft, .bottomRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

// MARK: Networks

extension Network {
    /// Brand-neutral tint from the palette.
    var tint: Color {
        switch self {
        case .instagram: .clinkRed
        case .linkedin: .clinkBlue
        case .x: .clinkNavy
        }
    }
}

/// A small mark that says which network an account came from.
struct NetworkGlyph: View {
    var network: Network
    var size: CGFloat

    var body: some View {
        switch network {
        case .instagram:
            Image(systemName: "camera").font(.system(size: size * 0.8, weight: .semibold))
        case .linkedin:
            Text("in").font(.system(size: size, weight: .heavy))
        case .x:
            Text("𝕏").font(.system(size: size, weight: .bold))
        }
    }
}

/// A round badge pinned to a face.
struct NetworkBadge: View {
    var network: Network
    var size: CGFloat

    var body: some View {
        NetworkGlyph(network: network, size: size * 0.5)
            .foregroundStyle(Color.clinkCream)
            .frame(width: size, height: size)
            .background(network.tint, in: Circle())
            .overlay(Circle().stroke(Color.clinkCream, lineWidth: max(1.5, size * 0.1)))
    }
}
