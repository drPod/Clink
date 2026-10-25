import SwiftUI

/// What two people share on one network.
struct OverlapSection: Identifiable {
    var network: Network
    var accounts: [SharedAccount]
    /// The server's total, which can exceed the accounts it sent back.
    var count: Int
    var stale = false
    var error: String?

    var id: String { network.rawValue }
}

extension OverlapSection {
    init(network: Network, overlap: NetworkOverlap) {
        let accounts = overlap.common ?? []
        self.init(network: network, accounts: accounts, count: overlap.count ?? accounts.count,
                  stale: overlap.stale ?? false, error: overlap.error)
    }
}

extension Array where Element == OverlapSection {
    var total: Int { reduce(0) { $0 + $1.count } }
    /// Every account with the network it came from, in section order.
    var tagged: [(Network, SharedAccount)] { flatMap { section in section.accounts.map { (section.network, $0) } } }
}

/// Everything the two of you share, after the clink.
struct OverlapView: View {
    var sections: [OverlapSection]
    var onClinkAgain: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clinkCream.ignoresSafeArea()
            Grain(opacity: 0.06)

            ScrollView {
                VStack(spacing: 0) {
                    header
                    list
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                        .padding(.bottom, 140)
                }
            }
            .ignoresSafeArea(edges: .top)

            Button("Clink again") {
                dismiss()
                onClinkAgain()
            }
            .buttonStyle(PillButtonStyle())
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .background(
                LinearGradient(colors: [Color.clinkCream.opacity(0), .clinkCream, .clinkCream], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appeared = true } }
    }

    private var header: some View {
        VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold))
                    }
                    Spacer()
                }
                .foregroundStyle(Color.clinkCream)
                .padding(.horizontal, 22)
                .padding(.top, 64)

                BreathingVenn(size: 96)
                    .frame(height: 96)
                    .shadow(color: .clinkNavy.opacity(0.35), radius: 16, y: 8)

                Text("Your overlap")
                    .font(ClinkFont.display(30))
                    .foregroundStyle(Color.clinkCream)
                    .padding(.top, 16)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.clinkCream.opacity(0.75))
                    .padding(.top, 3)
                    .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .background(LiveBackground(style: .blue))
        .clipShape(BottomRounded(radius: 32))
    }

    private var subtitle: String {
        let total = sections.total
        return "Clinked just now · \(total) \(total == 1 ? "person" : "people") in common"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 34) {
            if sections.isEmpty {
                Text("Connect the same network on both phones to see what you share.")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.clinkNavy.opacity(0.7))
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { s, section in
                sectionView(section, offset: sections.prefix(s).reduce(0) { $0 + $1.accounts.count })
            }
        }
    }

    private func sectionView(_ section: OverlapSection, offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                NetworkBadge(network: section.network, size: 26)
                Text(section.network.label).font(ClinkFont.display(22)).foregroundStyle(Color.clinkNavy)
                Spacer()
                Text("\(section.count) \(section.network.overlapPhrase)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(section.network.tint)
            }
            if let error = section.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.clinkRed)
                    .padding(.top, 6)
            } else if section.stale {
                Text("From a \(section.network.label) list saved earlier")
                    .font(.footnote)
                    .foregroundStyle(Color.clinkNavy.opacity(0.55))
                    .padding(.top, 6)
            }
            if section.accounts.isEmpty && section.error == nil {
                Text("Nothing in common here yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.clinkNavy.opacity(0.55))
                    .padding(.top, 10)
            }

            VStack(spacing: 0) {
                ForEach(Array(section.accounts.enumerated()), id: \.element.id) { j, account in
                    let i = offset + j
                    Button {
                        if let url = account.profileUrl { openURL(url) }
                    } label: {
                        HStack(spacing: 12) {
                            AccountFace(name: account.name, index: i, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.clinkNavy)
                                if let username = account.username {
                                    Text(section.network == .linkedin ? username : "@\(username)").font(.system(size: 14)).foregroundStyle(Color.clinkNavy.opacity(0.55))
                                }
                            }
                            Spacer()
                            if account.profileUrl != nil {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(section.network.tint)
                                    .frame(width: 30, height: 30)
                                    .background(section.network.tint.opacity(0.1), in: Circle())
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(min(i, 12)) * 0.04), value: appeared)

                    if j < section.accounts.count - 1 { Divider().opacity(0.5) }
                }
            }
            .padding(.top, 8)
        }
    }
}

#Preview("Overlap") {
    OverlapView(sections: OverlapSection.samples, onClinkAgain: {})
}
