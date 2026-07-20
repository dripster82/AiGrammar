import Foundation
import Combine
import AiGrammarCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Benchmarks a model across the four things AiGrammar asks of it — fix spelling/grammar, make
/// clearer, make more professional, make shorter — with 10 cases each, easy → complex. Scoring is
/// category-aware (similarity for grammar, brevity + meaning for shorter, casual-word removal for
/// professional) so different models actually spread out instead of all landing the same.
@MainActor
final class ModelTester: ObservableObject {
    enum Category: String, CaseIterable, Identifiable {
        case spelling = "Spelling & grammar"
        case clearer = "Clearer"
        case professional = "More professional"
        case shorter = "Shorter"
        var id: String { rawValue }
        var systemPrompt: String {
            switch self {
            case .spelling:     return "You are a text correction tool. Fix all spelling, grammar, capitalization and punctuation errors. Reply with ONLY the corrected text — no quotes, no explanation."
            case .clearer:      return "Rewrite the user's text to be clearer and easier to read, keeping the meaning. Reply with ONLY the rewrite — no quotes, no explanation."
            case .professional: return "Rewrite the user's text in a professional tone, removing slang and casual language. Reply with ONLY the rewrite — no quotes, no explanation."
            case .shorter:      return "Make the user's text much more concise, keeping the key meaning. Reply with ONLY the rewrite — no quotes, no explanation."
            }
        }
        /// Short task description for the AI judge.
        var judgeTask: String {
            switch self {
            case .spelling:     return "fix all spelling, grammar and punctuation errors without changing meaning"
            case .clearer:      return "rewrite it to be clearer and easier to read, keeping the meaning"
            case .professional: return "rewrite it in a professional tone, removing slang"
            case .shorter:      return "make it much more concise while keeping the key meaning"
            }
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let category: Category
        let prompt: String
        let expected: String
        var received = ""
        var score = 0.0          // heuristic 0…1
        var judge: Double?       // Apple-Intelligence quality rating 0…1 (if enabled)
        var judgeReason: String? // why Apple gave that rating
        var elapsedMs = 0
        var done = false
    }

    @Published private(set) var rows: [Row]
    @Published private(set) var running = false
    @Published private(set) var status = ""          // warmup / error message
    @Published private(set) var overall: Double?
    @Published private(set) var overallJudge: Double?
    private(set) var testedModelName = ""

    /// The AI judge (rate each reply with Apple's on-device model) is only offered when available.
    static var judgeAvailable: Bool { RewriteEngineChoice.appleAvailable() }

    private let models: ModelManager
    init(models: ModelManager) {
        self.models = models
        rows = Self.cases.map { Row(category: $0.0, prompt: $0.1, expected: $0.2) }
    }

    /// Average score for a category (finished rows only).
    func average(_ category: Category) -> Double? {
        let done = rows.filter { $0.category == category && $0.done }
        guard !done.isEmpty else { return nil }
        return done.map(\.score).reduce(0, +) / Double(done.count)
    }

    /// `judgeModelId` = "apple", a local model id, or nil for no judging.
    func run(modelId: String, modelName: String, judgeModelId: String?) async {
        guard !running else { return }
        running = true
        testedModelName = modelName
        overall = nil; overallJudge = nil
        for i in rows.indices {
            rows[i].received = ""; rows[i].score = 0; rows[i].judge = nil; rows[i].judgeReason = nil; rows[i].done = false
        }

        // #1 — verify the model is up and responding before running the real tests.
        status = "Checking model responds…"
        let warm = await complete("Reply with exactly: OK", system: "Reply with exactly the word: OK",
                                  modelId: modelId, purpose: "test")
        if warm.hasPrefix("[") {
            status = "Model not responding: \(warm)"
            running = false
            await LlamaServerPool.shared.release(purpose: "test")
            return
        }
        status = ""

        defer {
            running = false
            let s = rows.filter(\.done).map(\.score)
            overall = s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
            let j = rows.compactMap(\.judge)
            overallJudge = j.isEmpty ? nil : j.reduce(0, +) / Double(j.count)
            Task { await LlamaServerPool.shared.release(purpose: "test"); await LlamaServerPool.shared.release(purpose: "judge") }
        }
        for i in rows.indices {
            let start = Date()
            let reply = await complete(rows[i].prompt, system: rows[i].category.systemPrompt,
                                       modelId: modelId, purpose: "test")
            rows[i].elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            rows[i].received = reply
            rows[i].score = Self.score(reply, row: rows[i])
            if let jid = judgeModelId, !reply.hasPrefix("[") {
                if let (s, reason) = await judgeQuality(row: rows[i], judgeModelId: jid) {
                    rows[i].judge = s; rows[i].judgeReason = reason
                }
            }
            rows[i].done = true
        }
    }

    /// Grade the reply with the chosen judge model. The prompt is deliberately harsh and
    /// failure-focused: find what's WRONG first (especially the model answering the message instead
    /// of editing it), then score. A brief note of the main problem is returned.
    private func judgeQuality(row: Row, judgeModelId: String) async -> (Double, String)? {
        let system = """
            You are a harsh grader of ONE text edit. First find what is WRONG with RESULT, then score.
            TASK is what the writer was asked to do. REFERENCE is one correct example — RESULT may be \
            worded differently but must accomplish the TASK and keep the original meaning.

            Deduct heavily for these failures:
            - RESULT answers, replies to, or acts on the message instead of EDITING it → score 0-15.
            - RESULT changes or loses the original meaning → score 0-30.
            - RESULT does not actually do the TASK (not shorter, still casual/slang, still has errors) → 0-40.
            - RESULT adds new information that wasn't in the original → deduct.
            - Leftover spelling/grammar errors or awkward phrasing → deduct.
            Only give 90-100 if RESULT fully does the TASK, keeps the meaning, and reads naturally.

            Reply on ONE line exactly as:
            PROBLEM: <the main problem, or "none"> | SCORE: <0-100>
            """
        let user = "TASK: \(row.category.judgeTask)\nORIGINAL: \(row.prompt)\nREFERENCE: \(row.expected)\nRESULT: \(row.received)"
        let reply = await complete(user, system: system, modelId: judgeModelId, purpose: "judge")
        guard !reply.hasPrefix("["),
              let n = firstNumber(after: "SCORE", in: reply) ?? firstNumber(in: reply) else { return nil }
        let reason = textAfter("PROBLEM:", in: reply)?.components(separatedBy: "| SCORE").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return (min(1, max(0, n / 100)), reason)
    }

    private func firstNumber(after key: String, in s: String) -> Double? {
        guard let r = s.range(of: key) else { return nil }
        return firstNumber(in: String(s[r.upperBound...]))
    }
    private func firstNumber(in s: String) -> Double? {
        let parts = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
        return parts.first(where: { !$0.isEmpty }).flatMap(Double.init)
    }
    private func textAfter(_ key: String, in s: String) -> String? {
        guard let r = s.range(of: key) else { return nil }
        let t = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Average judge rating for a category (rated rows only).
    func averageJudge(_ category: Category) -> Double? {
        let j = rows.filter { $0.category == category }.compactMap(\.judge)
        guard !j.isEmpty else { return nil }
        return j.reduce(0, +) / Double(j.count)
    }

    /// Average response time in ms, EXCLUDING the first case (it includes the one-off model load).
    var averageMs: Int? {
        let done = rows.filter(\.done)
        guard done.count > 1 else { return done.first?.elapsedMs }
        let rest = done.dropFirst().map(\.elapsedMs)
        return rest.reduce(0, +) / rest.count
    }

    // MARK: Model call

    private func complete(_ prompt: String, system: String, modelId: String, purpose: String) async -> String {
        if modelId == "apple" { return await completeApple(prompt, system: system) }
        guard let path = models.path(forID: modelId) else { return "[model not found]" }
        do {
            let port = try await LlamaServerPool.shared.ensureRunning(
                purpose: purpose, modelPath: path, reasoningOff: true)
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let body: [String: Any] = [
                "model": "local", "stream": false, "temperature": 0, "max_tokens": 200,
                "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return "[HTTP \(http.statusCode)]" }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
            else { return "[no reply]" }
            return RewriteText.finalDisplay(content)
        } catch {
            return "[error: \(error.localizedDescription)]"
        }
    }

    private func completeApple(_ prompt: String, system: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: system)
                let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
                return RewriteText.finalDisplay(r.content)
            } catch { return "[error: \(error.localizedDescription)]" }
        }
        #endif
        return "[Apple model unavailable]"
    }

    // MARK: Scoring

    static func score(_ received: String, row: Row) -> Double {
        let clean = received.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("[") else { return 0 }
        switch row.category {
        case .spelling:     return similarity(clean, row.expected)
        case .clearer:      return 0.7 * similarity(clean, row.expected) + 0.3 * brevity(clean, vs: row.prompt, lenient: true)
        case .shorter:      return 0.5 * brevity(clean, vs: row.prompt, lenient: false) + 0.5 * overlap(clean, row.expected)
        case .professional: return 0.6 * casualRemoval(clean, from: row.prompt) + 0.4 * similarity(clean, row.expected)
        }
    }

    /// CSV of the run for later analysis (opens cleanly in a spreadsheet).
    func exportCSV() -> String {
        func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var lines = ["Category,Prompt,Expected,Received,Score %,Judge %,Judge notes,Time ms"]
        for r in rows {
            lines.append([
                q(r.category.rawValue), q(r.prompt), q(r.expected), q(r.received),
                String(Int(r.score * 100)),
                r.judge.map { String(Int($0 * 100)) } ?? "",
                q(r.judgeReason ?? ""),
                String(r.elapsedMs),
            ].joined(separator: ","))
        }
        lines.append("")
        lines.append("Model,\(q(testedModelName))")
        lines.append("Overall score %,\(overall.map { String(Int($0 * 100)) } ?? "")")
        lines.append("Overall judge %,\(overallJudge.map { String(Int($0 * 100)) } ?? "")")
        lines.append("Avg response ms (excl. load),\(averageMs.map(String.init) ?? "")")
        return lines.joined(separator: "\n")
    }

    static func label(_ score: Double) -> String {
        if score >= 0.9 { return "Excellent" }
        if score >= 0.75 { return "Good" }
        if score >= 0.55 { return "Fair" }
        return "Poor"
    }

    // MARK: Scoring helpers

    private static func words(_ s: String) -> [String] {
        norm(s).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private static func norm(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 0…1 normalized edit-distance similarity (case/punctuation-insensitive).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = norm(a), y = norm(b)
        guard !y.isEmpty else { return x.isEmpty ? 1 : 0 }
        if x == y { return 1 }
        let d = EditDistance.levenshtein(x, y)
        return max(0, 1 - Double(d) / Double(max(x.count, y.count)))
    }

    /// Reward being shorter than the input while not collapsing to nothing.
    private static func brevity(_ received: String, vs original: String, lenient: Bool) -> Double {
        let inW = max(1, words(original).count), outW = words(received).count
        guard outW > 0 else { return 0 }
        let ratio = Double(outW) / Double(inW)
        if lenient { return ratio <= 1 ? 1 : max(0, 1 - (ratio - 1)) }          // clearer: just don't get longer
        // shorter: reward reduction; too short (<20%) starts to lose meaning.
        if ratio > 1 { return max(0, 1 - (ratio - 1) * 2) }
        if ratio < 0.2 { return 0.4 }
        return min(1, (1 - ratio) / 0.6 + 0.2)
    }

    /// Fraction of the expected answer's content words present in the reply (meaning retained).
    private static func overlap(_ received: String, _ expected: String) -> Double {
        let stop: Set<String> = ["the","a","an","to","of","and","is","are","in","on","for","it","i","we","you"]
        let exp = Set(words(expected).filter { $0.count > 2 && !stop.contains($0) })
        guard !exp.isEmpty else { return 1 }
        let got = Set(words(received))
        return Double(exp.intersection(got).count) / Double(exp.count)
    }

    /// Fraction of the input's casual markers that were removed.
    private static func casualRemoval(_ received: String, from original: String) -> Double {
        let casual = ["lol","haha","gonna","wanna","kinda","dunno","srry","thx","plz","tbh","ngl",
                      "asap","yeah","yep","nope","mate","gotta","u ","ur ","!!"]
        let o = original.lowercased(), r = received.lowercased()
        let present = casual.filter { o.contains($0) }
        guard !present.isEmpty else { return 1 }
        let removed = present.filter { !r.contains($0) }.count
        return Double(removed) / Double(present.count)
    }

    // MARK: - Cases (10 per category, easy → complex)

    static let cases: [(Category, String, String)] = [
        // --- Spelling & grammar ---
        (.spelling, "i has a apple", "I have an apple."),
        (.spelling, "she dont like it", "She doesn't like it."),
        (.spelling, "we was late agian", "We were late again."),
        (.spelling, "their going too they're house", "They're going to their house."),
        (.spelling, "i should of went earlyer", "I should have gone earlier."),
        (.spelling, "the datas are not consistant", "The data is not consistent."),
        (.spelling, "me and him was going to the shops but we forgetted the list", "He and I were going to the shops, but we forgot the list."),
        (.spelling, "if i would have knew, i wouldnt of came", "If I had known, I wouldn't have come."),
        (.spelling, "each of the students have they're own laptop wich they bring everyday", "Each of the students has their own laptop, which they bring every day."),
        (.spelling, "neither the manager nor the staff was aware that the reports was due, wich caused alot of confusion", "Neither the manager nor the staff was aware that the reports were due, which caused a lot of confusion."),
        // --- Clearer ---
        (.clearer, "he made a decision to leave", "He decided to leave."),
        (.clearer, "at this point in time we are ready", "We are ready now."),
        (.clearer, "due to the fact that it rained, we stayed in", "Because it rained, we stayed in."),
        (.clearer, "the report was read by the whole team", "The whole team read the report."),
        (.clearer, "there are many people who believe this to be true", "Many people believe this is true."),
        (.clearer, "in the event that you are running late, please call me", "If you are running late, please call me."),
        (.clearer, "it is important to note that the deadline has been moved forward", "Note that the deadline has moved forward."),
        (.clearer, "we had a conversation about the matter of the budget for next year", "We discussed next year's budget."),
        (.clearer, "the reason why the project failed is because of poor planning and communication", "The project failed because of poor planning and communication."),
        (.clearer, "a large number of the participants expressed the opinion that the session was, on the whole, quite beneficial", "Most participants found the session beneficial."),
        // --- More professional ---
        (.professional, "hey can u send me that", "Could you please send me that?"),
        (.professional, "yeah that works for me", "Yes, that works for me."),
        (.professional, "gonna be late srry", "I will be late; apologies."),
        (.professional, "thx for the help!!", "Thank you for your help."),
        (.professional, "lol no worries mate", "No problem at all."),
        (.professional, "i dunno what happened tbh", "I am not sure what happened."),
        (.professional, "can you get this done asap plz", "Could you please complete this as soon as possible?"),
        (.professional, "we kinda messed up the numbers", "We made an error in the figures."),
        (.professional, "just wanted to give u a heads up that stuff is delayed", "I wanted to let you know that the project is delayed."),
        (.professional, "ngl the client was super annoyed and we gotta fix it real quick", "To be honest, the client was very frustrated, and we need to resolve this promptly."),
        // --- Shorter ---
        (.shorter, "I just wanted to quickly check in and see how things are going", "How are things going?"),
        (.shorter, "we should probably think about maybe rescheduling the meeting", "We should reschedule the meeting."),
        (.shorter, "there is a possibility that we might be able to help you", "We might be able to help."),
        (.shorter, "I would like to take this opportunity to thank you all", "Thank you all."),
        (.shorter, "in order to complete the task, you will need to log in first", "To finish, log in first."),
        (.shorter, "it would be greatly appreciated if you could respond as soon as you can", "Please respond soon."),
        (.shorter, "we are currently in the process of reviewing your application", "We are reviewing your application."),
        (.shorter, "despite the fact that it was raining heavily, we decided to go ahead with the event", "Despite the heavy rain, we held the event."),
        (.shorter, "I am reaching out to you today because I wanted to ask whether you would be available next week", "Are you available next week?"),
        (.shorter, "for all intents and purposes, the project has essentially been completed at this point in time", "The project is basically complete."),
    ]
}
