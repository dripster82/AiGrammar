# AiGrammar

A privacy-first macOS menu-bar app that watches the Slack message composer and helps you send
cleaner messages — catching spelling mistakes as you type, safely autocorrecting the obvious ones,
and rewriting selected sentences with a **local, on-device LLM**. Everything runs on your Mac: no
cloud calls, no telemetry of typed content, free to run.

## Features

### Spelling & autocorrect
- **Live spellcheck** in Slack's composer using the on-device macOS dictionary (`NSSpellChecker`).
- **Cautious autocorrect** — only very-high-confidence typos (`teh → the`) are fixed automatically,
  once the word is complete, always with a visible **undo chip**. Names, code, URLs, mentions,
  acronyms, and emoji shortcodes are never touched.
- **Suggestion popover** near the misspelled word — click to apply, step through multiple
  misspellings, or ignore.
- **Manual check** (`⌃⌘C` or menu) to re-run spellcheck on demand.

### On-demand rewrite (local LLM)
- **Rewrite the selected sentence** (`⌃⌘R`) with tone presets (Fix grammar, Make clearer, Shorten,
  More professional), streamed live into a popover to **Accept** or **Reject**.
- **Cancel actually stops generation** — hitting Cancel aborts the in-flight request so the model
  stops working immediately instead of finishing in the background.
- **Focus-aware popover** — while the model is generating, the popover won't vanish if you click
  away; it only dismisses once the result is ready and you move on.
- **Timing readout** — shows total time, and thinking-vs-total for reasoning models.

### Two on-device engines
- **Apple on-device model** (Apple Intelligence, macOS 26+) — a real ~3B model on Apple Silicon via
  Metal, nothing leaves the Mac.
- **Local GGUF models via llama.cpp** — bring your own `.gguf` (or download one from the **AI
  Models** catalog) and run it through a bundled `llama-server` on `127.0.0.1`. Works on Intel Macs
  and when Apple Intelligence is off.
- Falls back to deterministic on-device text cleanup when no LLM is available.
- **Process hygiene** — the local model server is shut down on quit, on model change, and on
  termination signals; a stale server left by a crash is cleaned up on next launch (no orphaned
  multi-GB processes).

### Tunable model parameters (**Settings → Parameters**)
- **Temperature**, **Top-p**, and **Max tokens** — apply to both the Apple and llama.cpp engines.
- **Reasoning effort** (None / Low / Medium / High) for reasoning models. *None* launches the local
  server with reasoning disabled (`--reasoning off`); Low/Medium/High map to `reasoning_effort`.
- **Short-circuit thinking** — prefills an empty `<think></think>` block so models with baked-in
  reasoning (e.g. MiMo) skip straight to the answer.
- **Advanced (extra JSON)** — merged into the llama.cpp request for any model-specific option
  (`top_k`, `min_p`, `repeat_penalty`, …).

### Menu bar & system
- Menu-bar app with quick toggles for autocorrect and suggestions.
- **Launch at Login** (via `SMAppService`).
- **Open AiGrammar** opens the control panel centered on the screen your mouse is on.
- **AX Debug Panel** with a **live AI stream** view — watch the model's raw output (including any
  `<think>` reasoning) token-by-token as it generates, for debugging.

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
3. Select a sentence and press **⌃⌘R** — pick a tone preset and Accept the streamed rewrite (or
   Cancel to stop generation).
4. Menu bar → **Open AiGrammar…** for the control panel (Dashboard, AI Models, Settings, Diagnostics).

Toggles for autocorrect and suggestions live in the menu bar and Settings. Model choice and
parameters live under **Settings → Parameters**; **Launch at Login** is in the menu bar.

## How it works

```
Menu-bar app (Swift + AppKit/SwiftUI)
├── AXInspector / FocusMonitor   read & write Slack's composer via the Accessibility API,
│                                forcing Slack's Electron a11y tree on (AXManualAccessibility)
├── AiGrammarCore (pure, tested) tokenizer, word classifier, autocorrect policy, edit distance
├── SpellEngine                  NSSpellChecker + curated high-confidence typo pass
├── ComposerPipeline             observe → debounce → spellcheck → autocorrect / suggest, with undo
├── OverlayUI                    non-activating popover + undo chip (never steal composer focus)
├── Rewrite (engine-agnostic)    selected-text rewrite streamed via AsyncStream; cancellable
│   ├── FoundationModelsRewriter Apple's on-device LLM (Apple Intelligence)
│   ├── GGUFRewriter + LlamaServer  local .gguf via a managed llama-server on 127.0.0.1
│   └── InferenceParams          temperature / top-p / max tokens / reasoning / extra JSON
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

Local-only by default. Spelling never leaves the device. Rewrites run on-device — either Apple's
model or a local `llama-server` bound to `127.0.0.1` (no outbound network). No telemetry of typed
content. Per-app allowlist, Slack-only for now.

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
