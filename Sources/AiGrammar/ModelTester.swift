import Foundation
import Combine
import AiGrammarCore

/// Runs a fixed set of correction test cases against a downloaded model and scores how close each
/// reply is to the expected answer — a quick "is this model any good for AiGrammar?" benchmark.
@MainActor
final class ModelTester: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let prompt: String
        let expected: String
        var received = ""
        var score = 0.0          // 0…1 similarity to expected
        var done = false
    }

    @Published private(set) var rows: [Row]
    @Published private(set) var running = false
    @Published private(set) var overall: Double?     // average score once finished

    private let models: ModelManager
    init(models: ModelManager) {
        self.models = models
        rows = Self.cases.map { Row(prompt: $0.prompt, expected: $0.expected) }
    }

    static let systemPrompt =
        "You are a text correction tool. Fix all spelling, grammar, capitalization, and punctuation "
        + "errors in the user's message. Reply with ONLY the corrected text — no quotes, no explanation."

    /// 20 messages with a canonical corrected form. Answers can phrase slightly differently, so we
    /// score by similarity rather than exact match.
    static let cases: [(prompt: String, expected: String)] = [
        ("i cant beleive its friday alredy", "I can't believe it's Friday already."),
        ("she have three cat and two dog", "She has three cats and two dogs."),
        ("we was at the park yesteday", "We were at the park yesterday."),
        ("their going to they're house over their", "They're going to their house over there."),
        ("i should of gone to the meeting", "I should have gone to the meeting."),
        ("your the best freind i ever had", "You're the best friend I ever had."),
        ("he dont no the anser", "He doesn't know the answer."),
        ("the reciept was in my poket", "The receipt was in my pocket."),
        ("can you send me the adress", "Can you send me the address?"),
        ("its been alot of fun definately", "It's been a lot of fun, definitely."),
        ("their is no reason to worry", "There is no reason to worry."),
        ("i seen that movie last weak", "I saw that movie last week."),
        ("please bring you're laptop tommorow", "Please bring your laptop tomorrow."),
        ("wich one do you prefere", "Which one do you prefer?"),
        ("im not sure weather it will rain", "I'm not sure whether it will rain."),
        ("he runned all the way home", "He ran all the way home."),
        ("there dog is bigger then ours", "Their dog is bigger than ours."),
        ("let me no if you need anythng", "Let me know if you need anything."),
        ("we need to discus this futher", "We need to discuss this further."),
        ("thats a realy intresting idae", "That's a really interesting idea."),
    ]

    func run(modelId: String) async {
        guard !running else { return }
        running = true
        overall = nil
        for i in rows.indices { rows[i].received = ""; rows[i].score = 0; rows[i].done = false }
        defer {
            running = false
            let scores = rows.map(\.score)
            overall = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            Task { await LlamaServerPool.shared.release(purpose: "test") }
        }

        guard let path = models.path(forID: modelId) else { return }
        for i in rows.indices {
            let reply = await complete(rows[i].prompt, modelPath: path)
            rows[i].received = reply
            rows[i].score = Self.similarity(reply, rows[i].expected)
            rows[i].done = true
        }
    }

    private func complete(_ prompt: String, modelPath: String) async -> String {
        do {
            let port = try await LlamaServerPool.shared.ensureRunning(
                purpose: "test", modelPath: modelPath, reasoningOff: true)
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let body: [String: Any] = [
                "model": "local", "stream": false, "temperature": 0, "max_tokens": 200,
                "messages": [
                    ["role": "system", "content": Self.systemPrompt],
                    ["role": "user", "content": prompt],
                ],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return "[HTTP \(http.statusCode)]"
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
            else { return "[no reply]" }
            return RewriteText.finalDisplay(content)   // strip <think> / preamble / quotes
        } catch {
            return "[error: \(error.localizedDescription)]"
        }
    }

    /// 0…1 similarity, punctuation/case-insensitive, via normalized edit distance.
    static func similarity(_ received: String, _ expected: String) -> Double {
        func norm(_ s: String) -> String {
            let lowered = s.lowercased()
            let stripped = lowered.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == " "
            }
            return String(String.UnicodeScalarView(stripped))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let r = norm(received), e = norm(expected)
        guard !e.isEmpty else { return r.isEmpty ? 1 : 0 }
        if r == e { return 1 }
        let d = EditDistance.levenshtein(r, e)
        return max(0, 1 - Double(d) / Double(max(r.count, e.count)))
    }

    static func label(_ score: Double) -> String {
        if score >= 0.95 { return "Perfect" }
        if score >= 0.85 { return "Good" }
        if score >= 0.70 { return "Fair" }
        return "Poor"
    }
}
