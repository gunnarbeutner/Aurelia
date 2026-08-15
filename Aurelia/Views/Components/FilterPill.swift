import SwiftUI

struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                // Black only reads on the accent in dark mode, where it is a
                // bright mint. In light mode the accent is a deep green and
                // needs white on top; `appAccentText` is that pairing.
                .foregroundColor(isSelected ? .appAccentText : .appTextSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.appAccent : Color.appElevated)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.appControlFill, lineWidth: 1)
                )
                .shadow(color: isSelected ? Color.appAccent.opacity(0.3) : .clear, radius: 8, x: 0, y: 0)
        }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

