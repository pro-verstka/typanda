import Carbon
import SwiftUI

enum SelfTest {
    static func run() {
        func parse(_ provider: Provider, _ json: String, _ status: Int = 200) -> String {
            do { return try LLM.parse(Data(json.utf8), status: status, provider: provider) } catch { return "ERR " + error.localizedDescription }
        }

        precondition(parse(.openai, #"{"choices":[{"message":{"content":"Привет, мир."},"finish_reason":"stop"}]}"#) == "Привет, мир.")
        precondition(parse(.openai, #"{"choices":[{"message":{"content":"Обре"},"finish_reason":"length"}]}"#).hasPrefix("ERR"))
        precondition(parse(.anthropic, #"{"content":[{"type":"text","text":"Ок."}],"stop_reason":"end_turn"}"#) == "Ок.")
        precondition(parse(.anthropic, #"{"content":[{"type":"text","text":"Обре"}],"stop_reason":"max_tokens"}"#).hasPrefix("ERR"))
        precondition(parse(.anthropic, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, 401) == "ERR invalid x-api-key")
        precondition(parse(.openai, "<html>Bad Gateway</html>", 502) == "ERR HTTP 502")
        precondition(parse(.anthropic, #"{"content":[]}"#) == "ERR The model returned an empty response")

        precondition(Diff.marked("Превет мир", "Привет, мир").filter(\.1).map(\.0) == ["Привет", ","])
        precondition(Diff.marked("Всё ок.", "Всё ок.").allSatisfy { !$0.1 })

        let left = kVK_Shift, right = kVK_RightShift
        var tap = DoubleTap()
        _ = (tap.feed(right, .shift, at: 0), tap.feed(right, [], at: 0.1), tap.feed(right, .shift, at: 0.2))
        precondition(tap.feed(right, [], at: 0.3) == right)
        var mixed = DoubleTap()
        _ = (mixed.feed(left, .shift, at: 0), mixed.feed(left, [], at: 0.1), mixed.feed(right, .shift, at: 0.2))
        precondition(mixed.feed(right, [], at: 0.3) == nil)
        var slow = DoubleTap()
        _ = (slow.feed(right, .shift, at: 0), slow.feed(right, [], at: 0.1), slow.feed(right, .shift, at: 1))
        precondition(slow.feed(right, [], at: 1.1) == nil)
        var typing = DoubleTap()
        _ = (typing.feed(right, .shift, at: 0), typing.feed(right, [], at: 0.1), typing.feed(nil, [], at: 0.15), typing.feed(right, .shift, at: 0.2))
        precondition(typing.feed(right, [], at: 0.3) == nil)
        var held = DoubleTap()
        _ = (held.feed(right, .shift, at: 0), held.feed(right, [], at: 0.1), held.feed(right, .shift, at: 0.15))
        precondition(held.feed(right, [], at: 0.9) == nil)

        precondition(carbonModifiers([.command, .option]) == cmdKey | optionKey)
        precondition(modifierSymbols([.command, .shift, .control]) == "⌃⇧⌘")
        precondition(UpdateService.shared.compareVersions("1.0.10", isNewerThan: "1.0.9"))
        precondition(!UpdateService.shared.compareVersions("1.0", isNewerThan: "1.0.0"))
        print("selftest ok")
    }
}
