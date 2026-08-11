//
//  CypherpunkTheme.swift
//  Aurelia
//
//  Modern theme system with multiple color schemes
//

import SwiftUI
import Combine

// MARK: - Theme Types

enum AppTheme: String, CaseIterable, Identifiable {
    case cypherpunk = "Cypherpunk"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var description: String { "Neon accents with dark backgrounds" }
}

// MARK: - Theme Manager

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "selectedTheme")
        }
    }

    private init() {
        if let savedTheme = UserDefaults.standard.string(forKey: "selectedTheme"),
           let theme = AppTheme(rawValue: savedTheme) {
            currentTheme = theme
        } else {
            currentTheme = .cypherpunk
        }
    }
}

// MARK: - Color Palette
extension Color {
    // Cypherpunk Theme - Neon Accents (matched to BRAND-GUIDE.md)
    static let neonCyan = Color(hex: "00FFDD")       // Primary accent
    static let neonPink = Color(hex: "FF3D85")       // Secondary accent
    static let neonPurple = Color(hex: "8B5CF6")     // Tertiary
    static let neonGreen = Color(red: 0.0, green: 1.0, blue: 0.25)
    static let neonOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
    static let neonBlue = Color(red: 0.0, green: 0.4, blue: 1.0)

    // Cypherpunk Theme - Dark Backgrounds (matched to BRAND-GUIDE.md)
    static let darkBackground = Color(hex: "060609")  // Deep Black
    static let darkMid = Color(hex: "0A0A10")         // Card
    static let darkElevated = Color(hex: "0E0E16")    // Surface

    // Bitcoin Theme - Backgrounds
    static let matteBlack = Color(hex: "181818")
    static let steelyGray = Color(hex: "33434b")

    // Bitcoin Theme - Refined Palette (less orange-heavy)
    static let mattaze = Color(hex: "cc6633")           // Rust/terracotta (toned down from bright orange)
    static let deepBlue = Color(hex: "0d579b")          // Deep blue
    static let lightGray = Color(hex: "ececec")         // Light gray text
    static let cyphernyuk = Color(hex: "3d5a5a")        // Dark teal/green
    static let goldBrass = Color(hex: "d5bb73")         // Gold/brass
    static let bronze = Color(hex: "9f8247")            // Bronze/brown
    static let bitcoinOrange = Color(hex: "f7931a")     // Pure bitcoin orange (used sparingly)

    // Semantic Colors (Theme-aware)
    static var appAccent: Color {
        return neonCyan
    }

    static var appSecondary: Color {
        return neonPink
    }

    static var appSuccess: Color {
        return neonGreen
    }

    static var appWarning: Color {
        return neonOrange
    }

    static var appError: Color {
        return Color.red
    }

    static var appBackground: Color {
        return darkBackground
    }

    static var appMidBackground: Color {
        return darkMid
    }

    static var appElevated: Color {
        return darkElevated
    }

    static var appText: Color {
        return Color(hex: "EEEEF2")  // Brand primary text
    }

    static var appTextSecondary: Color {
        return Color(hex: "8888AA")  // Brand secondary text
    }

    static var appTextMuted: Color {
        return Color(hex: "555570")  // Brand muted text
    }

    static var appTertiary: Color {
        return neonPurple
    }

    // Helper for hex colors
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
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
                        Color.white.opacity(configuration.isPressed ? 0.05 : 0.1)
                    }
                }
            )
            .foregroundColor(isProminent ? .black : color)
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

// MARK: - Preview
#Preview {
    ZStack {
        Color.darkBackground.ignoresSafeArea()

        VStack(spacing: 30) {
            // Glass Card Example
            VStack(spacing: 12) {
                Text("Now Playing")
                    .font(.appHeadline)
                    .foregroundColor(.white)

                Text("Synthwave Dreams")
                    .font(.appBody)
                    .foregroundColor(.secondary)
            }
            .padding(30)
            .glassCard(tint: .neonCyan)

            // Button Examples
            HStack(spacing: 20) {
                Button("Play") {
                    // Action
                }
                .buttonStyle(CypherpunkButtonStyle(color: .neonCyan, isProminent: true))

                Button("Queue") {
                    // Action
                }
                .buttonStyle(CypherpunkButtonStyle(color: .neonPink))
            }

            // Neon Text
            Text("Aurelia")
                .font(.appTitle)
                .foregroundColor(.neonCyan)
                .neonGlow(color: .neonCyan, radius: 12)
        }
        .padding()
    }
}
