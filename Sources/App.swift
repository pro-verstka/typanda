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
    static let settings: NSWindow = {
        let window = make("Typanda Settings", SettingsView())
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        return window
    }()

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
    @AppStorage("updateAutoCheckEnabled") private var autoCheckUpdates = true
    private let updates = UpdateService.shared
    private let repositoryURL = URL(string: "https://github.com/pro-verstka/typanda")!

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var updateButton: (title: String, enabled: Bool) {
        switch updates.state {
        case .idle: ("Check for Updates", true)
        case .checking: ("Checking…", false)
        case .available(let release): ("Update to \(release.version)", true)
        case .downloading: ("Downloading…", false)
        case .installing: ("Installing…", false)
        case .failed: ("Retry Update", true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 96, height: 96)
                        .padding(.bottom, 2)
                    Text("Typanda").font(.system(size: 22, weight: .semibold))
                    Text(versionText).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("Correct or translate selected text in any app with a hotkey.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Made by pro-verstka")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    HStack {
                        Text("Updates")
                        Spacer()
                        Button(updateButton.title) { updates.checkForUpdate(manual: true) }
                            .disabled(!updateButton.enabled)
                    }
                    .padding(12)
                    Divider().padding(.horizontal, 12)
                    HStack {
                        Text("Automatically check for updates")
                        Spacer()
                        Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(12)
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Links").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                    VStack(spacing: 0) {
                        link("GitHub", symbol: "globe", destination: repositoryURL)
                        Divider().padding(.horizontal, 12)
                        link("Changelog", symbol: "sparkles", destination: repositoryURL.appendingPathComponent("releases"))
                    }
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 24)
        }
    }

    private func link(_ title: String, symbol: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 20)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
