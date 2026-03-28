import SwiftUI
import AppKit

@main
struct SubtitleGeneratorApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 720)
        .windowResizability(.contentSize)
    }
}
