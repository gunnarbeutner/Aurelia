//
//  AureliaWidgetBundle.swift
//  AureliaWidgets
//
//  Widget, Live Activity and Control Center entries
//

import SwiftUI
import WidgetKit

@main
struct AureliaWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()

        if #available(iOS 18.0, *) {
            AureliaPlayPauseControl()
        }
    }
}
