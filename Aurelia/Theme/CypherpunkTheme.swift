//
//  CypherpunkTheme.swift
//  Aurelia
//
//  Aurelia's adaptive visual system
//

import SwiftUI

// MARK: - Appearance

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    // Keep the existing raw value so current installations retain their choice.
    case dark = "always_dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Color Palette
extension Color {
    static var appError: Color {
        return Color.red
    }

    // Most semantic colors are generated directly from Assets.xcassets.
    // Preserve the established surface spelling used throughout the app.
    static var appMidBackground: Color { .appSurface }

}

// MARK: - Typography (Brand Kit: Chakra Petch + Sora + JetBrains Mono)
extension Font {
    // Display — large hero text (Now Playing track title, onboarding)
    static let appDisplay = Font.custom("ChakraPetch-Bold", size: 28, relativeTo: .largeTitle)
    // Title — section headers, screen titles
    static let appTitle = Font.custom("ChakraPetch-Bold", size: 22, relativeTo: .title2)
    // Headline — card titles, artist/album names
    static let appHeadline = Font.custom("ChakraPetch-SemiBold", size: 17, relativeTo: .headline)
    // Subheadline — secondary info below headlines
    static let appSubheadline = Font.custom("Sora-Medium", size: 15, relativeTo: .subheadline)
    // Body — general text
    static let appBody = Font.custom("Sora-Regular", size: 16, relativeTo: .body)
    // Caption — labels, timestamps, metadata
    static let appCaption = Font.custom("Sora-Regular", size: 13, relativeTo: .caption)
    // Mono — time codes, durations, badges (JetBrains Mono)
    static let appMono = Font.custom("JetBrainsMono-Regular", size: 12, relativeTo: .caption)
}

// MARK: - Glass Effect Styles
struct GlassCard: ViewModifier {
    var tint: Color = .appAccent
    var intensity: Double = 0.3

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [
                                tint.opacity(intensity),
                                tint.opacity(intensity * 0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: tint.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

struct NeonGlow: ViewModifier {
    var color: Color
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.5), radius: radius * 0.5, x: 0, y: 0)
            .shadow(color: color.opacity(0.25), radius: radius, x: 0, y: 0)
            .shadow(color: color.opacity(0.1), radius: radius * 1.5, x: 0, y: 0)
    }
}

// MARK: - View Extensions
extension View {
    func glassCard(tint: Color = .appAccent, intensity: Double = 0.3) -> some View {
        modifier(GlassCard(tint: tint, intensity: intensity))
    }

    func neonGlow(color: Color = .appAccent, radius: CGFloat = 4) -> some View {
        modifier(NeonGlow(color: color, radius: radius))
    }

    /// The Catalyst tab bar already names and highlights the current root page.
    /// Hiding the root navigation bar there avoids repeating that title and
    /// returns its vertical space, while compact iOS layouts retain their title.
    @ViewBuilder
    func rootTabNavigationTitle(_ title: String) -> some View {
        #if targetEnvironment(macCatalyst)
        toolbar(.hidden, for: .navigationBar)
        #else
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Button Styles
struct CypherpunkButtonStyle: ButtonStyle {
    var color: Color = .appAccent
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isProminent {
                        color.opacity(configuration.isPressed ? 0.6 : 0.8)
                    } else {
                        Color.appControlFill.opacity(configuration.isPressed ? 0.6 : 1)
                    }
                }
            )
            .foregroundColor(isProminent ? .appAccentText : color)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
            .neonGlow(color: color, radius: configuration.isPressed ? 4 : 8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A prominent control whose label remains legible against the adaptive accent.
///
/// SwiftUI's built-in bordered-prominent style chooses its own foreground color.
/// That produces white-on-mint controls when `appAccent` resolves in dark mode,
/// even though the palette deliberately provides `appAccentText` for this case.
struct AppProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var color: Color = .appAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.appAccentText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.appBackground.ignoresSafeArea()

        VStack(spacing: 30) {
            // Glass Card Example
            VStack(spacing: 12) {
                Text("Now Playing")
                    .font(.appHeadline)
                    .foregroundColor(.appText)

                Text("Synthwave Dreams")
                    .font(.appBody)
                    .foregroundColor(.secondary)
            }
            .padding(30)
            .glassCard(tint: .appAccent)

            // Button Examples
            HStack(spacing: 20) {
                Button("Play") {
                    // Action
                }
                .buttonStyle(CypherpunkButtonStyle(color: .appAccent, isProminent: true))

                Button("Queue") {
                    // Action
                }
                .buttonStyle(CypherpunkButtonStyle(color: .appSecondary))
            }

            // Neon Text
            Text("Aurelia")
                .font(.appTitle)
                .foregroundColor(.appAccent)
                .neonGlow(color: .appAccent, radius: 12)
        }
        .padding()
    }
}
