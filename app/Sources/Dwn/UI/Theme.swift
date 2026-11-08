import SwiftUI

/// Dwn's visual language: near-black surfaces, soft hairline strokes,
/// white for primary actions and a single lime accent for the brand.
enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let sidebar = Color(red: 0.063, green: 0.063, blue: 0.070)
    static let card = Color(red: 0.090, green: 0.090, blue: 0.100)
    static let raised = Color(red: 0.130, green: 0.130, blue: 0.145)
    static let hover = Color(red: 0.165, green: 0.165, blue: 0.180)
    static let stroke = Color.white.opacity(0.075)
    static let strokeStrong = Color.white.opacity(0.14)
    static let text = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.56)
    static let text3 = Color.white.opacity(0.34)
    static let accent = Color(red: 0.80, green: 1.0, blue: 0.30)   // lime
    static let warn = Color(red: 1.0, green: 0.70, blue: 0.35)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.40)

    static let radius: CGFloat = 16
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Surfaces

struct CardBackground: ViewModifier {
    var fill: Color = Theme.card
    var radius: CGFloat = Theme.radius

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke))
    }
}

extension View {
    func card(_ fill: Color = Theme.card, radius: CGFloat = Theme.radius) -> some View {
        modifier(CardBackground(fill: fill, radius: radius))
    }

    func sectionLabel() -> some View {
        font(.ui(11.5, .semibold)).foregroundStyle(Theme.text3)
    }
}

// MARK: - Metrics

/// One spacing and sizing scale for every control, so things line up.
enum M {
    static let control: CGFloat = 36      // standard control height
    static let controlLarge: CGFloat = 42 // primary actions in the main window
    static let r: CGFloat = 10            // control corner radius
    static let icon: CGFloat = 12.5       // icon point size inside controls
    static let iconColumn: CGFloat = 16   // fixed icon column so labels align
}

/// Fill-only surface for controls: no outline, just a quiet lift off the card.
extension View {
    func controlFill(_ on: Bool = false, hover: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: M.r, style: .continuous)
            .fill(Color.white.opacity(on ? 0.12 : (hover ? 0.085 : 0.055))))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = M.controlLarge

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13.5, .semibold))
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(enabled ? Color.black : Theme.text3)
            .background(
                RoundedRectangle(cornerRadius: M.r, style: .continuous)
                    .fill(enabled ? Color.white.opacity(configuration.isPressed ? 0.80 : 0.95) : Color.white.opacity(0.055))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = M.control
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, enabled: enabled, height: height, fill: fill)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        let enabled: Bool
        let height: CGFloat
        let fill: Bool
        @Local private var hover = false

        var body: some View {
            configuration.label
                .font(.ui(12.5, .medium))
                .padding(.horizontal, 12)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: height)
                .foregroundStyle(enabled ? Theme.text : Theme.text3)
                .controlFill(configuration.isPressed, hover: hover && enabled)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// Borderless square icon button; a soft fill appears on hover.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, filled: filled)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let filled: Bool
        @Local private var hover = false

        var body: some View {
            configuration.label
                .font(.ui(M.icon, .medium))
                .imageScale(.medium)
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : (hover ? 0.08 : (filled ? 0.05 : 0)))))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

// MARK: - Switch

struct DwnSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.white.opacity(0.95) : Color.white.opacity(0.10))
                    Circle()
                        .fill(configuration.isOn ? Color.black : Color.white.opacity(0.55))
                        .padding(3)
                }
                .frame(width: 34, height: 20)
                .animation(.spring(response: 0.26, dampingFraction: 0.8), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab bar (segmented control)

struct TabItem<ID: Hashable>: Identifiable {
    var id: ID
    var title: String
    var icon: String
}

struct DwnTabs<ID: Hashable>: View {
    var items: [TabItem<ID>]
    @Binding var selection: ID
    var height: CGFloat = M.control
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = item.id == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = item.id }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.ui(11.5, .semibold))
                        Text(item.title).font(.ui(12.5, .semibold))
                    }
                    .foregroundStyle(on ? Theme.text : Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: height - 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: M.r - 2, style: .continuous)
                                .fill(Color.white.opacity(0.11))
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: M.r, style: .continuous).fill(Color.white.opacity(0.045)))
    }
}

// MARK: - Dropdown

/// One line: the choice on the left, its detail right-aligned, then a chevron.
struct DwnDropdown<ID: Hashable>: View {
    var options: [(ID, String, String?)]   // id, title, detail
    @Binding var selection: ID
    var icon: String? = nil
    var height: CGFloat = M.control
    @Local private var hover = false

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { opt in
                Button {
                    selection = opt.0
                } label: {
                    if opt.0 == selection { Label(opt.1, systemImage: "checkmark") } else { Text(opt.1) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.ui(M.icon, .medium)).foregroundStyle(Theme.text2)
                        .frame(width: M.iconColumn)
                }
                Text(current?.1 ?? "").font(.ui(13, .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let d = current?.2 {
                    Text(d).font(.ui(12)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.ui(10, .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .controlFill(hover: hover)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover = $0 }
    }

    private var current: (ID, String, String?)? { options.first { $0.0 == selection } }
}

// MARK: - Option row

struct OptionRow: View {
    var icon: String
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.ui(M.icon, .medium))
                    .foregroundStyle(Theme.text3)
                    .frame(width: M.iconColumn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.ui(11.5)).foregroundStyle(Theme.text3) }
                }
            }
        }
        .toggleStyle(DwnSwitchStyle())
    }
}

/// Square-ish toggle tile: icon over a short label. Used in an even row.
struct OptionTile: View {
    var icon: String
    var title: String
    @Binding var isOn: Bool
    @Local private var hover = false

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.ui(12.5, .semibold)).frame(height: 14)
                Text(title).font(.ui(10.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.black : (hover ? Theme.text : Theme.text2))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .fill(isOn ? Color.white.opacity(0.92) : Color.white.opacity(hover ? 0.085 : 0.05)))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Animated stripe used for indeterminate progress.
struct Shimmer: View {
    @Local private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Color.white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.5)
                .offset(x: phase * g.size.width)
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.5 }
        }
        .allowsHitTesting(false)
    }
}

struct ProgressBar: View {
    var value: Double
    var indeterminate = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                if indeterminate {
                    Capsule().fill(Theme.accent.opacity(0.35)).overlay(Shimmer()).clipShape(Capsule())
                } else {
                    Capsule().fill(Theme.accent)
                        .frame(width: max(6, g.size.width * min(max(value, 0), 1)))
                        .animation(.easeOut(duration: 0.35), value: value)
                }
            }
        }
        .frame(height: 4)
    }
}
