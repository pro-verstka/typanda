import Carbon
import SwiftUI

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum LLM {
    private static func request(_ provider: Provider, _ path: String) -> URLRequest {
        let key = Keychain.get(provider.rawValue)
        switch provider {
        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return request
        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/\(path)")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        }
    }

    static func models(_ provider: Provider) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request(provider, provider == .anthropic ? "models?limit=1000" : "models"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("HTTP") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    static func process(_ text: String, action: TextAction) async throws -> String {
        let defaults = UserDefaults.standard
        let provider = Provider(rawValue: defaults.string(forKey: action.providerKey) ?? "") ?? .openai
        let model = defaults.string(forKey: action.modelKey(provider)) ?? ""
        let prompt = try systemPrompt(action, defaults: defaults)
        guard !Keychain.get(provider.rawValue).isEmpty else { throw Failure("Add your \(provider.rawValue) API key in Settings") }

        let body: [String: Any] = switch provider {
        case .openai:
            ["model": model, "messages": [["role": "system", "content": prompt], ["role": "user", "content": text]]]
        case .anthropic:
            ["model": model, "max_tokens": 8192, "system": prompt, "messages": [["role": "user", "content": text]]]
        }
        var request = request(provider, provider == .openai ? "chat/completions" : "messages")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: provider)
    }

    static func systemPrompt(_ action: TextAction, defaults: UserDefaults = .standard) throws -> String {
        let prompt = defaults.string(forKey: action.promptKey) ?? ""
        guard action == .translation else { return prompt }
        let language = (defaults.string(forKey: Prefs.targetLanguage) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty else { throw Failure("Choose a target language in Translation settings") }
        return prompt + "\n\nTarget language: " + language
    }

    static func parse(_ data: Data, status: Int, provider: Provider) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] {
            throw Failure(error["message"] as? String ?? "HTTP \(status)")
        }
        guard status == 200 else { throw Failure("HTTP \(status)") }

        let text: String?
        let truncated: Bool
        switch provider {
        case .openai:
            let choice = (json["choices"] as? [[String: Any]])?.first
            text = (choice?["message"] as? [String: Any])?["content"] as? String
            truncated = choice?["finish_reason"] as? String == "length"
        case .anthropic:
            text = (json["content"] as? [[String: Any]])?
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined()
            truncated = json["stop_reason"] as? String == "max_tokens"
        }
        // Обрезанный ответ в буфере обмена = потеря хвоста текста при вставке
        if truncated { throw Failure("The model response was cut off: the text is too long") }
        guard let text, !text.isEmpty else { throw Failure("The model returned an empty response") }
        return text
    }
}

@Observable
final class ResultState {
    var action: TextAction = .correction
    var original: String?
    var fixed: String?
    var error: String?
}

@MainActor
enum Corrector {
    private static var task: Task<Void, Never>?
    private static var target: NSRunningApplication?
    private static let state = ResultState()
    private static let panel = makePanel()

    static func run(_ action: TextAction = .correction) {
        task?.cancel()
        state.action = action
        target = NSWorkspace.shared.frontmostApplication
        task = Task {
            guard AXIsProcessTrusted() else {
                return show(error: "Allow Typanda in System Settings → Privacy & Security → Accessibility")
            }
            guard let text = await copySelection(), !text.isEmpty else {
                return show(error: "Could not copy the selected text")
            }
            guard !Task.isCancelled else { return }
            show(original: text)
            do {
                let fixed = try await LLM.process(text, action: action)
                try Task.checkCancellation()
                if UserDefaults.standard.bool(forKey: Prefs.copyResult) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fixed, forType: .string)
                }
                show(original: text, fixed: fixed)
            } catch {
                if !Task.isCancelled { show(error: error.localizedDescription) }
            }
        }
    }

    static func apply() {
        guard let fixed = state.fixed else { return }
        panel.close()
        Task {
            let pasteboard = NSPasteboard.general
            let saved = snapshot()
            pasteboard.clearContents()
            pasteboard.setString(fixed, forType: .string)
            target?.activate()
            try? await Task.sleep(for: .milliseconds(100))
            press(kVK_ANSI_V)
            // Приложение читает буфер после ⌘V асинхронно — восстановим раньше, вставится старое содержимое
            try? await Task.sleep(for: .milliseconds(500))
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot()
        let before = pasteboard.changeCount
        press(kVK_ANSI_C)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before {
                let text = pasteboard.string(forType: .string)
                // ⌘C нужен только чтобы прочитать выделение — возвращаем буфер, каким он был
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
                return text
            }
        }
        return nil
    }

    private static func snapshot() -> [NSPasteboardItem] {
        NSPasteboard.general.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
    }

    private static func press(_ key: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func show(original: String? = nil, fixed: String? = nil, error: String? = nil) {
        state.original = original
        state.fixed = fixed
        state.error = error
        guard error != nil || UserDefaults.standard.bool(forKey: Prefs.showResult) else { return }
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
        // Nonactivating-панель забирает клавиатуру, не активируя приложение: Enter/Esc не уйдут в исходное окно
        panel.makeKey()
    }

    private static func makePanel() -> NSPanel {
        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень borderless-окна строится по прямоугольнику и рисует рамку вокруг стекла
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: ResultView(state: state, close: { [weak panel] in panel?.close() }, apply: apply))
        host.sizingOptions = [.minSize]
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.contentView = host
        glass.autoresizingMask = [.width, .height]
        // Тень стекла выходит за скругления и обрезается прямоугольником окна — режем по форме стекла
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = glass.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.addSubview(glass)
        panel.contentView = clip
        glass.frame = clip.bounds
        return panel
    }
}

final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

struct ResultView: View {
    let state: ResultState
    let close: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(state.action.title, systemImage: state.action == .correction ? "text.badge.checkmark" : "character.bubble").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .gesture(WindowDragGesture())

            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Original", Text(state.original ?? "").foregroundStyle(.secondary))
                        Divider()
                        if let fixed = state.fixed {
                            if state.action == .translation {
                                section("Translation", Text(fixed))
                            } else {
                                section("Corrected", Text(Diff.highlighted(state.original ?? "", fixed)))
                            }
                        } else {
                            section(state.action == .correction ? "Corrected" : "Translation", skeleton)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if state.fixed != nil {
                    HStack {
                        Spacer()
                        Button("Replace", action: apply).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<3) { line in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 12)
                    .padding(.trailing, line == 2 ? 120 : 0)
            }
        }
        .padding(.vertical, 2)
        .phaseAnimator([1, 0.4]) { content, opacity in content.opacity(opacity) }
    }

    private func section(_ title: String, _ content: some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content.font(.body).lineSpacing(3).textSelection(.enabled)
        }
    }
}

enum Diff {
    static func highlighted(_ original: String, _ fixed: String) -> AttributedString {
        var result = AttributedString()
        for (token, changed) in marked(original, fixed) {
            var part = AttributedString(token)
            if changed { part.backgroundColor = Color.green.opacity(0.3) }
            result += part
        }
        return result
    }

    static func marked(_ original: String, _ fixed: String) -> [(Substring, Bool)] {
        let tokens = { (text: String) in text.matches(of: #/\w+|\W/#).map(\.output) }
        let new = tokens(fixed)
        let inserted = Set(new.difference(from: tokens(original)).insertions.compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change { return offset }
            return nil
        })
        return new.enumerated().map { ($1, inserted.contains($0)) }
    }
}
