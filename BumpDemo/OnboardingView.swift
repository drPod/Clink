import SwiftUI

/// First launch: Instagram up front, the other networks just below.
struct OnboardingView: View {
    /// Networks the server can link; Instagram leads when it's offered.
    var networks: [Network]
    var linking: Network?
    var message: String?
    var onConnect: (Network) -> Void

    private var primary: Network { networks.contains(.instagram) ? .instagram : networks.first ?? .instagram }
    private var others: [Network] { networks.filter { $0 != primary } }

    @State private var appeared = false

    var body: some View {
        ZStack {
            LiveBackground(style: .cream)

            VStack(spacing: 0) {
                HStack {
                    Wordmark()
                    Spacer()
                }
                .padding(.top, 12)

                Spacer()

                BreathingVenn(size: 160)
                    .shadow(color: .clinkNavy.opacity(0.22), radius: 22, y: 12)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)

                Spacer()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Find your overlap.")
                        .font(ClinkFont.display(44))
                        .foregroundStyle(Color.clinkNavy)
                    Text("Touch phones with anyone and see everything you share.")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.clinkNavy.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)

                Button { onConnect(primary) } label: {
                    if linking == primary {
                        ProgressView().tint(.clinkCream)
                    } else {
                        HStack(spacing: 10) {
                            NetworkGlyph(network: primary, size: 17)
                            Text("Continue with \(primary.label)")
                        }
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(linking != nil)
                .padding(.top, 32)

                if !others.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(others) { network in
                            Button { onConnect(network) } label: {
                                if linking == network {
                                    ProgressView().tint(.clinkNavy)
                                } else {
                                    HStack(spacing: 8) {
                                        NetworkGlyph(network: network, size: 15)
                                        Text(network.label)
                                    }
                                }
                            }
                            .buttonStyle(OutlinePillStyle())
                            .disabled(linking != nil)
                        }
                    }
                    .padding(.top, 10)
                }

                Text(message ?? " ")
                    .font(.footnote)
                    .foregroundStyle(Color.clinkNavy.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 26)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.75).delay(0.1)) { appeared = true }
        }
    }
}

/// Two circles that drift apart and back together while the overlap glows.
struct BreathingVenn: View {
    var size: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 1.3) + 1) / 2
            let overlap = size * (0.34 + 0.14 * breath)
            let width = size * 2 - overlap
            ZStack(alignment: .leading) {
                PersonCircle(colors: PersonCircle.you).frame(width: size)
                PersonCircle(colors: PersonCircle.them).frame(width: size).offset(x: size - overlap)
                Lens(size: size, overlap: overlap)
                    .fill(Color.clinkCream)
                    .shadow(color: .clinkCream.opacity(0.9), radius: 14 + 12 * breath)
                LensFaces(size: size, overlap: overlap, t: t)
                    .clipShape(Lens(size: size, overlap: overlap))
            }
            .frame(width: width, height: size)
            .frame(width: size * 2, height: size)
        }
    }
}

/// Tiny faces that bob inside the lens.
struct LensFaces: View {
    var size: CGFloat
    var overlap: CGFloat
    var t: Double
    var count = 12

    var body: some View {
        let d = max(10, size * 0.085)
        let cx = size - overlap / 2
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let row = i / 3, col = i % 3
                AccountFace(name: "", index: i, size: d)
                    .position(x: cx + (CGFloat(col) - 1) * d * 1.2,
                              y: size / 2 + (CGFloat(row) - 1.5) * d * 1.2 + CGFloat(sin(t * 2 + Double(i))) * 1.5)
            }
        }
        .frame(width: size * 2 - overlap, height: size)
    }
}

#Preview("Welcome") {
    OnboardingView(networks: Network.allCases, linking: nil, message: nil, onConnect: { _ in })
}
