import Foundation

class TranslationEngine {
    let authMethod: AuthMethod
    let claudeApiKey: String
    let claudeOAuthToken: String
    let openaiApiKey: String

    init(authMethod: AuthMethod, claudeApiKey: String = "", claudeOAuthToken: String = "", openaiApiKey: String = "") {
        self.authMethod = authMethod
        self.claudeApiKey = claudeApiKey
        self.claudeOAuthToken = claudeOAuthToken
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
                case .claudeOAuth, .claudeApiKey:
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

    private func translationPrompt(targetLang: TranslationLanguage, srtContent: String) -> String {
        """
        Translate the following SRT subtitle file to \(targetLang.langName).
        Keep the exact same SRT format: preserve all sequence numbers, timestamps, and blank lines.
        Only translate the text content. Do not add any explanation or commentary.
        Output ONLY the translated SRT content.

        \(srtContent)
        """
    }

    // MARK: - Claude API

    private func callClaudeAPI(srtContent: String, targetLang: TranslationLanguage) -> String? {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300

        if authMethod == .claudeOAuth {
            request.setValue("Bearer \(claudeOAuthToken)", forHTTPHeaderField: "authorization")
        } else {
            request.setValue(claudeApiKey, forHTTPHeaderField: "x-api-key")
        }

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
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

    // MARK: - OpenAI API

    private func callOpenAIAPI(srtContent: String, targetLang: TranslationLanguage) -> String? {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(openaiApiKey)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
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
