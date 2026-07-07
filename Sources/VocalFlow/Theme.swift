import SwiftUI

// ============================================================
// VocalLabs brand theme for macOS.
//
// Mirrors windows/VocalFlow/UI/Theme.xaml so the two desktop apps look like
// the same product: dark, minimal, purple accent (palette derived from
// vocallabs.ai — #8400ff signature, near-black-purple ground, ~10px radius).
//
// The goal here is brand parity *with* native Mac cleanliness — we reuse
// stock SwiftUI controls (Toggle, Picker, TextField) and SF Pro, and only
// restyle the surfaces around them (cards, headers, buttons, colors).
// ============================================================

extension Color {
    /// Build a Color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    static let vlWindowBg      = Color(hex: 0x0C0714)
    static let vlSidebarBg     = Color(hex: 0x100A1E)
    static let vlCardBg        = Color(hex: 0x16112A)
    static let vlControlBg     = Color(hex: 0x1E1838)
    static let vlControlBorder = Color(hex: 0x352D55)
    static let vlCardBorder    = Color(hex: 0x272040)
    static let vlTextPrimary   = Color(hex: 0xF4F2FA)
    static let vlTextSecondary = Color(hex: 0xA79FBE)
    static let vlAccent        = Color(hex: 0x8400FF)
    static let vlAccentHover   = Color(hex: 0x9A35FF)
    static let vlError         = Color(hex: 0xFF5C72)
    static let vlSuccess       = Color(hex: 0x34D399)
}

extension LinearGradient {
    /// Primary-button gradient (matches the WPF AccentGradientBrush).
    static let vlAccent = LinearGradient(
        colors: [Color(hex: 0x9148FF), Color(hex: 0x6E3EF3)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Buttons

/// Primary / accent button — purple gradient, white semibold (WPF AccentButton).
struct VLAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(LinearGradient.vlAccent, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// Secondary / default button — control fill, subtle border (WPF default Button).
struct VLSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color.vlTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Color.vlControlBorder : Color.vlControlBg,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(configuration.isPressed ? Color.vlAccent : Color.vlControlBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

// MARK: - Layout primitives

/// A branded card — the unit of the settings layout (WPF Card style).
/// Vertical gradient + drop shadow give the card gentle depth against the
/// darker window ground; a hairline top highlight sells the "lit from above" look.
struct VLCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                LinearGradient(colors: [Color(hex: 0x1B1435), Color(hex: 0x151027)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        LinearGradient(colors: [Color(hex: 0x3A3060), Color.vlCardBorder],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// Card title row with an optional trailing action (WPF DockPanel header + button).
struct VLCardHeader: View {
    let title: String
    var actionLabel: String? = nil
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.vlTextPrimary)
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(action: action) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(actionLabel)
                    }
                }
                .buttonStyle(VLSecondaryButtonStyle())
                .disabled(isDisabled || isLoading)
            }
        }
    }
}

/// "Label …… [control]" row — label hugs the left, the control sits at the
/// trailing edge at its natural size (capped so long menu items truncate
/// instead of blowing out the row). System Settings-style alignment.
struct VLField<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Color.vlTextPrimary)
            Spacer(minLength: 16)
            control.frame(maxWidth: 300, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Muted, wrapping caption text (WPF Caption style).
    func vlCaption() -> some View {
        self.font(.system(size: 11))
            .foregroundStyle(Color.vlTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Wrap a text editor / field in the branded control surface.
    func vlControlSurface() -> some View {
        self.background(Color.vlControlBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.vlControlBorder, lineWidth: 1))
    }
}
