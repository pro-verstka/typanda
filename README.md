<img src="icon.png" alt="Typanda icon" width="128">

# Typanda

Spelling and grammar fixer in your macOS menu bar. Select text in any app, press a hotkey — Typanda fixes typos and grammar without rewriting your style and copies the result to the clipboard.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![No dependencies](https://img.shields.io/badge/dependencies-none-green)

## Setup

1. Settings → pick OpenAI or Anthropic, paste an API key, choose a model.
2. Allow Typanda in System Settings → Privacy & Security → Accessibility.
3. Select text and press the hotkey (⌥⌘G by default, a double ⇧ works too).
4. Press Enter in the result window to replace the selection (or insert at the cursor), Esc to dismiss.

## Releases

Download the latest build from [Releases](https://github.com/pro-verstka/typanda/releases). It is unsigned and not notarized; if macOS says the app is damaged:

```bash
xattr -rd com.apple.quarantine /Applications/Typanda.app
```

## Build

Requires macOS 26+ and Xcode 26.

```bash
./scripts/build.sh && open build/Typanda.app
```
