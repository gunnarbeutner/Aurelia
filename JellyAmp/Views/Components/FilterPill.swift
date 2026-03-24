import SwiftUI

struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .black : .jellyAmpTextSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.jellyAmpAccent : Color.jellyAmpElevated)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: isSelected ? Color.jellyAmpAccent.opacity(0.3) : .clear, radius: 8, x: 0, y: 0)
        }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

