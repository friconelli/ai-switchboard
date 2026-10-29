import SwiftUI

enum Theme {
    static let coral = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let clay = Color(red: 0.60, green: 0.26, blue: 0.20)
    static let brandGradient = LinearGradient(
        colors: [coral, clay],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardRadius: CGFloat = 16

    static func color(forContext context: String) -> Color {
        switch context.lowercased() {
        case "personale", "personal": return .pink
        case "lavoro", "work", "studiogusto": return .indigo
        default:
            let palette: [Color] = [.teal, .orange, .green, .purple, .blue, .mint, .brown]
            return palette[context.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
        }
    }

    static func symbol(forContext context: String) -> String {
        switch context.lowercased() {
        case "personale", "personal": return "person.fill"
        case "lavoro", "work", "studiogusto": return "building.2.fill"
        default: return "square.stack.fill"
        }
    }

    /// Stable colour per account name.
    static func color(forAccount name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .green]
        if name == "predefinito" { return .gray }
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

struct AccountBadge: View {
    let account: ClaudeAccount
    var compact = false

    var body: some View {
        let color = Theme.color(forAccount: account.name)
        Label(account.name, systemImage: "person.crop.circle")
            .labelStyle(.titleAndIcon)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1 : 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .help(account.email ?? account.name)
    }
}

struct ContextBadge: View {
    let context: String?

    var body: some View {
        if let context {
            Label(context, systemImage: Theme.symbol(forContext: context))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.color(forContext: context).opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.color(forContext: context))
        } else {
            Label("Da assegnare", systemImage: "tray")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusDot: View {
    let busy: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(busy ? Color.orange : Color.green)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(busy ? Color.orange : Color.green, lineWidth: 2)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(pulse ? 0 : 0.7)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

// MARK: - Building blocks

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(
                colors: [tint.opacity(0.85), tint],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.3), radius: 4, y: 2)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// Header shared by detail pages: icon tile, title, badge and explanation.
struct PageHeader<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.bold())
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.brandGradient)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SelectionCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}

/// Floating bottom bar for the destructive "move to Trash" action.
struct ActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let bar = HStack(spacing: 12) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

        Group {
            if #available(macOS 26.0, *) {
                bar.glassEffect(.regular, in: Capsule())
            } else {
                bar
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

extension View {
    /// Prominent button style: Liquid Glass on macOS 26, bordered prominent before.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

