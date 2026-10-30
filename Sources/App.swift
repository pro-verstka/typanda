import SwiftUI

@main
struct TypandaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.showIcon) private var showIcon = true

    init() {
        Prefs.register()
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Typanda", systemImage: "pawprint.fill", isInserted: $showIcon) { MenuContent() }
    }
}

struct MenuContent: View {
    private let updates = UpdateService.shared

    private var update: (title: String, enabled: Bool) {
        switch updates.state {
        case .idle: ("Check for Updates…", true)
        case .checking: ("Checking for Updates…", false)
        case .available(let release): ("Update Available (\(release.version))", true)
        case .downloading: ("Downloading Update…", false)
        case .installing: ("Installing Update…", false)
        case .failed: ("Update Failed — Retry", true)
        }
    }

    var body: some View {
        Button("Settings…") { Windows.show(Windows.settings) }.keyboardShortcut(",")
        Button("About Typanda") { Windows.show(Windows.about) }
        Button(update.title) { updates.checkForUpdate(manual: true) }.disabled(!update.enabled)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.install { Corrector.run($0) }
        HotKey.register()
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        UpdateService.shared.startPeriodicChecks()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.show(Windows.settings)
        return false
    }
}

@MainActor
enum Windows {
    static let settings = make("Typanda Settings", SettingsView())
    static let about = make("About Typanda", AboutView())

    private static func make(_ title: String, _ view: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    static func show(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Агент-приложению macOS может отказать в активации — поднимаем окно поверх чужих принудительно
        window.orderFrontRegardless()
    }
}

struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/pro-verstka/typanda")!

    private let versionText: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "Unknown"
    }()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Typanda")
                .font(.title2.bold())

            Text("Correct or translate selected text in any app with a hotkey.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Version")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(versionText)
            }

            HStack {
                Text("Author")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("pro-verstka")
            }

            HStack {
                Text("Git")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("github.com/pro-verstka/typanda", destination: repositoryURL)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
