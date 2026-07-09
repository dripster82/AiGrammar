import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)

/// Rewrite backend powered by Apple's on-device Foundation Model (Apple Intelligence, macOS 26+).
/// This is a genuine local ~3B LLM: runs on-device via Metal, streams tokens, and sends nothing to
/// a server — satisfying the goal's "local model streams a rewrite, nothing leaves the Mac" without
/// any model download or management. Falls back to the heuristic engine when unavailable (Apple
/// Intelligence off, unsupported hardware, or model still downloading).
@available(macOS 26.0, *)
final class FoundationModelsRewriter: RewriteEngine {
    var displayName: String { "Apple on-device model" }
    var isLocalModel: Bool { true }

    private let params: InferenceParams
    init(params: InferenceParams) { self.params = params }

    /// Why the model can't be used right now, for surfacing in the UI.
    static func unavailabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func rewrite(_ text: String, instruction: RewriteInstruction, systemPrompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                let session = LanguageModelSession(instructions: systemPrompt)
                Log.write("[rewrite] Foundation model: \(instruction.id) on \(text.count) chars (temp \(params.temperature))")
                do {
                    // Apple's model honors temperature, top-p (sampling), and max response tokens.
                    let options = GenerationOptions(
                        sampling: params.topP < 0.999 ? .random(probabilityThreshold: params.topP) : nil,
                        temperature: params.temperature,
                        maximumResponseTokens: params.maxTokens > 0 ? params.maxTokens : nil)
                    // Send the message alone (no "Message:" label to avoid it being echoed back).
                    let stream = session.streamResponse(to: text, options: options)
                    AIDebugLog.shared.begin(engine: "Apple on-device", instruction: instruction.id)
                    var raw = ""
                    for try await partial in stream {
                        if Task.isCancelled { break }   // Cancel button / focus-loss dismiss
                        raw = partial.content
                        AIDebugLog.shared.update(raw)   // live raw stream → debug panel
                        continuation.yield(RewriteText.display(raw))   // cumulative, de-preambled
                    }
                    continuation.yield(RewriteText.finalDisplay(raw))   // never leave it on "Thinking…"
                    AIDebugLog.shared.finish(chars: raw.count)
                    Log.write("[rewrite] Apple raw response (\(raw.count) chars):\n\(raw)")
                    Log.ai(engine: "rewrite · Apple",
                           prompt: "SYSTEM:\n\(systemPrompt)\n\nUSER:\n\(text)", response: raw)
                } catch is CancellationError {
                    Log.write("[rewrite] Apple generation cancelled")
                } catch {
                    Log.write("[rewrite] error: \(error.localizedDescription)")
                    continuation.yield("[rewrite failed: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#endif

/// Version-agnostic status of the Apple on-device model, for the UI to read without availability
/// gymnastics.
enum OnDeviceModel {
    /// (usable now, human-readable reason if not).
    static var status: (available: Bool, reason: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return (FoundationModelsRewriter.isAvailable, FoundationModelsRewriter.unavailabilityReason())
        }
        #endif
        return (false, "Requires macOS 26 or later with Apple Intelligence.")
    }

    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Apple-Intelligence-Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:",
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}
