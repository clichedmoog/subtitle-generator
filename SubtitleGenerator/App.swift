import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let allowed = ["mp4", "mov", "mkv", "m4v", "m4a", "wav", "mp3", "avi", "webm", "flv"]
        let validURLs = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        guard !validURLs.isEmpty else { return }

        NotificationCenter.default.post(
            name: .addFilesToQueue,
            object: nil,
            userInfo: ["urls": validURLs]
        )
    }
}

extension Notification.Name {
    static let addFilesToQueue = Notification.Name("addFilesToQueue")
}

@main
struct SubtitleGeneratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("자막 생성기", id: "main") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 720)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
