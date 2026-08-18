//
//  WidgetPalette.swift
//  AureliaWidgets
//
//  The app's accent colours, restated for the extension
//

import SwiftUI

/// The widget target does not carry the app's asset catalog, so the two shades
/// of the brand accent are spelled out here to match AppAccent.colorset.
enum WidgetPalette {
    static let accentLight = Color(.sRGB, red: 0, green: 0.478, blue: 0.420, opacity: 1)
    static let accentDark = Color(.sRGB, red: 0, green: 1.0, blue: 0.867, opacity: 1)

    static let backgroundLight = Color(.sRGB, red: 0.969, green: 0.969, blue: 0.980, opacity: 1)
    static let backgroundDark = Color(.sRGB, red: 0.024, green: 0.024, blue: 0.035, opacity: 1)

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? accentDark : accentLight
    }

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? backgroundDark : backgroundLight
    }
}
