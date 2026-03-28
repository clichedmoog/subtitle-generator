import SwiftUI

@main
struct SubtitleGeneratorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 640, height: 720)
        .windowResizability(.contentSize)
    }
}
