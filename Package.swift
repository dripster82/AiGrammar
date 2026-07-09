// swift-tools-version:5.9
import PackageDescription

// Local GGUF models run via llama.cpp's `llama-server` as a localhost subprocess (see
// LlamaServer.swift + docs/llama-setup.md) — no C-interop or package linking needed, so nothing
// special here.

let package = Package(
    name: "AiGrammar",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (tokenizer, spellcheck, confidence rules) — kept out of the app target so
        // it's unit-testable without the AppKit event loop.
        .target(name: "AiGrammarCore"),
        .executableTarget(
            name: "AiGrammar",
            dependencies: ["AiGrammarCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                // Weak-linked: FoundationModels exists only on macOS 26+, but the app deploys to 14.
                // Guarded at runtime by `if #available(macOS 26.0, *)`.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        // XCTest needs full Xcode (only Command Line Tools are installed here), so core logic is
        // covered by a runnable self-test executable instead: `swift run CoreSelfTest`.
        .executableTarget(name: "CoreSelfTest", dependencies: ["AiGrammarCore"]),
    ]
)
