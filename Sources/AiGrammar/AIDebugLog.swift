import Foundation
import Combine

/// Live feed of the current rewrite's RAW model output (including any `<think>` reasoning), shown in
/// the AX Debug Panel so you can watch exactly what the model produces as it streams.
final class AIDebugLog: ObservableObject {
    static let shared = AIDebugLog()

    @Published var header = "(no rewrite yet)"
    @Published var raw = ""

    func begin(engine: String, instruction: String) {
        DispatchQueue.main.async {
            self.header = "\(engine) · \(instruction) · streaming…"
            self.raw = ""
        }
    }

    func update(_ raw: String) {
        DispatchQueue.main.async { self.raw = raw }
    }

    func finish(chars: Int) {
        DispatchQueue.main.async {
            self.header = self.header.replacingOccurrences(of: "streaming…", with: "done (\(chars) chars)")
        }
    }
}
