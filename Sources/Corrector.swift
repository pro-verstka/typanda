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

    static func correct(_ text: String) async throws -> String {
        let defaults = UserDefaults.standard
        let provider = Provider(rawValue: defaults.string(forKey: Prefs.provider) ?? "") ?? .openai
        let model = defaults.string(forKey: Prefs.model(provider)) ?? ""
        let prompt = defaults.string(forKey: Prefs.prompt) ?? ""
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
    var original: String?
    var fixed: String?
    var error: String?
}

@MainActor
enum Corrector {
    private static var task: Task<Void, Never>?
    private static let state = ResultState()
    private static let panel = makePanel()

    static func run() {
        task?.cancel()
        task = Task {
            guard AXIsProcessTrusted() else {
                return show(error: "Allow Typanda in System Settings → Privacy & Security → Accessibility")
            }
            guard let text = await copySelection(), !text.isEmpty else {
                return show(error: "Could not copy the selected text")
            }
            show(original: text)
            do {
                let fixed = try await LLM.correct(text)
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

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        let before = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
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

    private static func show(original: String? = nil, fixed: String? = nil, error: String? = nil) {
        state.original = original
        state.fixed = fixed
        state.error = error
        guard error != nil || UserDefaults.standard.bool(forKey: Prefs.showResult) else { return }
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
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
        let host = NSHostingView(rootView: ResultView(state: state) { [weak panel] in panel?.close() })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Typanda", systemImage: "text.badge.checkmark").font(.headline)
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
                            section("Corrected", Text(Diff.highlighted(state.original ?? "", fixed)))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
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
