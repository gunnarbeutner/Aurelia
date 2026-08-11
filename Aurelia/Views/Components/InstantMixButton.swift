import SwiftUI

struct InstantMixButton: View {
    let itemId: String
    let itemName: String

    var body: some View {
        Button {
            InstantMixCoordinator.shared.play(itemId: itemId, itemName: itemName)
        } label: {
            Label("Instant Mix", systemImage: "wand.and.stars")
        }
    }
}
