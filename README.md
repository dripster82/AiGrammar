# AiGrammar

A privacy-first macOS menu-bar app that watches the Slack message composer and helps you send
cleaner messages — catching spelling mistakes as you type, safely autocorrecting the obvious ones,
and rewriting selected sentences with a **local, on-device LLM**. Everything runs on your Mac: no
cloud calls, no telemetry of typed content, free to run.

## Features

- **Live spellcheck** in Slack's composer using the on-device macOS dictionary (`NSSpellChecker`).
- **Cautious autocorrect** — only very-high-confidence typos (`teh → the`) are fixed automatically,
  once the word is complete, always with a visible **undo chip**. Names, code, URLs, mentions,
  acronyms, and emoji shortcodes are never touched.
- **Suggestion popover** near the misspelled word — click to apply, or ignore.
- **On-demand rewrite** (`⌃⌘R`) of the selected sentence with tone presets (Fix grammar, Make
  clearer, Shorten, More professional), streaming the result into a popover to Accept or Reject.
- **Local LLM**: rewrites use Apple's on-device Foundation Model (Apple Intelligence) when enabled —
  a real ~3B model on Apple Silicon via Metal, nothing leaves the Mac. Falls back to deterministic
  on-device text cleanup when Apple Intelligence is off. The **AI Models** page also lets you manage
  downloadable / bring-your-own models.
- **Manual check** (`⌃⌘C` or menu) to re-run spellcheck on demand.

## Requirements

- macOS 14+ (rewrite via Apple's on-device model needs macOS 26 + Apple Intelligence enabled).
- Apple Silicon recommended.
- **Accessibility permission** (System Settings › Privacy & Security › Accessibility) — required to
  read and correct Slack's composer.

## Build & run

```sh
Scripts/build-app.sh          # builds build/AiGrammar.app (signed with a stable identity so the
open build/AiGrammar.app      # Accessibility grant persists across rebuilds)
```

On first launch, grant Accessibility permission when prompted (or via the app's Diagnostics page /
System Settings), then relaunch. The app lives in the menu bar (dotted-underline icon).

Run the pure-logic self-tests (no Xcode required):

```sh
swift run CoreSelfTest
```

## Usage

1. Click into Slack's message box and type. Misspellings surface a suggestion popover; high-confidence
   typos autocorrect with an undo chip.
2. **⌃⌘C** — check the composer on demand.
3. Select a sentence and press **⌃⌘R** — pick a tone preset and Accept the streamed rewrite.
4. Menu bar → **Open AiGrammar…** for the control panel (Dashboard, AI Models, Settings, Diagnostics).

Toggles for autocorrect and suggestions live in the menu bar and Settings.

## How it works

```
Menu-bar app (Swift + AppKit/SwiftUI)
├── AXInspector / FocusMonitor   read & write Slack's composer via the Accessibility API,
│                                forcing Slack's Electron a11y tree on (AXManualAccessibility)
├── AiGrammarCore (pure, tested) tokenizer, word classifier, autocorrect policy, edit distance
├── SpellEngine                  NSSpellChecker + curated high-confidence typo pass
├── ComposerPipeline             observe → debounce → spellcheck → autocorrect / suggest, with undo
├── OverlayUI                    non-activating popover + undo chip (never steal composer focus)
├── Rewrite + FoundationModels   selected-text rewrite streamed from Apple's on-device LLM
└── ModelManager + ControlPanel  model catalog / custom models, settings, diagnostics
```

Key design points, established during build:

- Slack's Electron composer exposes read **and** write via the Accessibility API — but only after
  `AXManualAccessibility` is set on Slack, and its composer node only appears once clicked.
- Writes use whole-text `AXValue` `setValue` (Slack's Quill editor ignores targeted `setSelectedText`),
  applied asynchronously — so reads-after-write settle before verifying.
- Corrections and undo verify the surrounding text still matches before writing, so a stale edit can
  never corrupt the message.

## Privacy

Local-only by default. Spelling never leaves the device. Rewrites use the on-device Apple model (no
network). No telemetry of typed content. Per-app allowlist, Slack-only for now.

## Verification status

- `AiGrammarCore` logic: 27 self-test checks pass.
- Spell engine, model manager, Foundation Models availability: in-app self-tests pass.
- **End-to-end against real Slack** (autonomous `DemoDriver`, synthesized input): autocorrect, undo,
  and click-to-apply all pass — verified by reading the composer back.
- Remaining: a human typing in Slack and visually confirming the popover — inherent user acceptance,
  not a testable code path.

## Local models (llama.cpp)

To run a downloaded GGUF model locally, install llama.cpp (`brew install llama.cpp`) or run
`Scripts/fetch-llama.sh` to fetch and embed `llama-server` into the app bundle. Then, in
**AI Models**, download a model (or add a local `.gguf` path) and select it in **Settings →
Parameters**. Rewrites run on-device via a local `llama-server` on `127.0.0.1`.

## License

MIT
