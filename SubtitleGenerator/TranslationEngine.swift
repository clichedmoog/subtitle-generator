import Foundation

class TranslationEngine {
    let authMethod: AuthMethod
    let translationModel: String
    let claudeApiKey: String
    let openaiApiKey: String

    init(authMethod: AuthMethod, translationModel: String = "", claudeApiKey: String = "", openaiApiKey: String = "") {
        self.authMethod = authMethod
        self.translationModel = translationModel
        self.claudeApiKey = claudeApiKey
        self.openaiApiKey = openaiApiKey
    }

    func translateSrt(srtContent: String, sourceLang: String, targetLangs: [TranslationLanguage], onProgress: @escaping (String) -> Void) -> [TranslationLanguage: String] {
        var results: [TranslationLanguage: String] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for lang in targetLangs {
            if lang.rawValue == sourceLang { continue }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                onProgress("\(lang.label) 번역 중...")

                let translated: String?
                switch self.authMethod {
                case .claudeCode:
                    translated = self.callClaudeCodeCLI(srtContent: srtContent, targetLang: lang)
                case .claudeApiKey:
                    translated = self.callClaudeAPI(srtContent: srtContent, targetLang: lang)
                case .openaiApiKey:
                    translated = self.callOpenAIAPI(srtContent: srtContent, targetLang: lang)
                }

                if let translated = translated {
                    lock.lock()
                    results[lang] = translated
                    lock.unlock()
                    onProgress("\(lang.label) 번역 완료")
                } else {
                    onProgress("\(lang.label) 번역 실패")
                }

                group.leave()
            }
        }

        group.wait()
        return results
    }

    /// Check if authentication is working
    func verifyAuth() -> Bool {
        switch authMethod {
        case .claudeCode:
            return verifyClaudeCode()
        case .claudeApiKey:
            return verifyClaudeAPI()
        case .openaiApiKey:
            return verifyOpenAIAPI()
        }
    }

    private func translationPrompt(targetLang: TranslationLanguage, srtContent: String) -> String {
        """
        Translate the following SRT subtitle file to \(targetLang.langName).
        Keep the exact same SRT format: preserve all sequence numbers, timestamps, and blank lines.
        Only translate the text content. Do not add any explanation or commentary.
        Output ONLY the translated SRT content.

        \(srtContent)
        """
    }

    // MARK: - Claude Code CLI (uses subscription auth)

    private func findClaudeBinary() -> String? {
        let paths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func callClaudeCodeCLI(srtContent: String, targetLang: TranslationLanguage) -> String? {
        guard let claude = findClaudeBinary() else {
            logDebug("claude binary not found")
            return nil
        }

        let prompt = translationPrompt(targetLang: targetLang, srtContent: srtContent)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--model", translationModel, prompt]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logDebug("claude CLI error: \(error)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            logDebug("claude CLI exit: \(process.terminationStatus)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func verifyClaudeCode() -> Bool {
        guard let claude = findClaudeBinary() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "status"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else { return false }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.contains("\"loggedIn\": true") || output.contains("\"loggedIn\":true")
    }

    // MARK: - Claude API (direct)

    private func callClaudeAPI(srtContent: String, targetLang: TranslationLanguage) -> String? {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(claudeApiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": translationModel,
            "max_tokens": 8192,
            "messages": [
                ["role": "user", "content": translationPrompt(targetLang: targetLang, srtContent: srtContent)]
            ]
        ]

        return sendRequest(request, body: body) { json in
            if let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
    }

    private func verifyClaudeAPI() -> Bool {
        let result = callClaudeAPI(
            srtContent: "1\n00:00:00,000 --> 00:00:01,000\nhello\n",
            targetLang: .ko
        )
        return result != nil
    }

    // MARK: - OpenAI API

    private func callOpenAIAPI(srtContent: String, targetLang: TranslationLanguage) -> String? {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(openaiApiKey)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": translationModel,
            "messages": [
                ["role": "user", "content": translationPrompt(targetLang: targetLang, srtContent: srtContent)]
            ]
        ]

        return sendRequest(request, body: body) { json in
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
    }

    private func verifyOpenAIAPI() -> Bool {
        let result = callOpenAIAPI(
            srtContent: "1\n00:00:00,000 --> 00:00:01,000\nhello\n",
            targetLang: .ko
        )
        return result != nil
    }

    // MARK: - Common

    private func sendRequest(_ request: URLRequest, body: [String: Any], parse: @escaping ([String: Any]) -> String?) -> String? {
        var request = request
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil else {
                logDebug("Translation API error: \(error?.localizedDescription ?? "unknown")")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let parsed = parse(json) {
                    result = parsed
                } else if let error = json["error"] as? [String: Any] {
                    logDebug("Translation API error: \(error)")
                }
            }
        }.resume()

        semaphore.wait()
        return result
    }
}
