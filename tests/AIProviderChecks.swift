import Foundation

@main
struct AIProviderChecks {
    static func check(_ condition: Bool) { assert(condition) }

    static func fails(_ operation: () throws -> Void) {
        do { try operation(); assertionFailure("Cette entrée doit être refusée.") }
        catch { assert(error is RemoteAI.Failure) }
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }

    static func fixture(_ text: String, provider: AIProvider, status: Int = 200, key: String = "test-key") throws -> String {
        try RemoteAI.readResponse(Data(text.utf8), statusCode: status, provider: provider, apiKey: key)
    }

    static func main() throws {
        let prompt = "Une question française — `$(echo test)`"
        for provider in AIProvider.allCases {
            check(try JSONDecoder().decode(AIProvider.self, from: JSONEncoder().encode(provider)) == provider)
            assert(provider.usesAPI == ![AIProvider.chatgpt, .claudeCode, .grokBuild].contains(provider))
        }
        assert(AIProvider.allCases.first == .chatgpt)
        let claude = try RemoteAI.makeRequest(prompt, provider: .claude, model: AIProvider.claude.defaultModel,
                                              apiKey: "test-key", baseURL: AIProvider.claude.defaultBaseURL)
        assert(claude.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        assert(claude.httpMethod == "POST" && claude.timeoutInterval == 60)
        assert(claude.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        assert(claude.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let claudeBody = try body(claude)
        assert((claudeBody["messages"] as? [[String: String]])?.first?["content"] == prompt)
        assert(claudeBody["max_tokens"] as? Int == 2048)
        assert((claudeBody["thinking"] as? [String: String])?["type"] == "disabled")
        assert((claudeBody["output_config"] as? [String: String])?["effort"] == "low")

        let gemini = try RemoteAI.makeRequest(prompt, provider: .gemini, model: AIProvider.gemini.defaultModel,
                                              apiKey: "test-key", baseURL: AIProvider.gemini.defaultBaseURL)
        assert(gemini.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        assert(gemini.url?.query == nil && gemini.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        assert(gemini.value(forHTTPHeaderField: "Authorization") == nil)
        let contents = try body(gemini)["contents"] as! [[String: Any]]
        assert((contents[0]["parts"] as? [[String: String]])?.first?["text"] == prompt)
        let generation = try body(gemini)["generationConfig"] as! [String: Any]
        assert(generation["maxOutputTokens"] as? Int == 2048)
        assert((generation["thinkingConfig"] as? [String: String])?["thinkingLevel"] == "low")

        let grok = try RemoteAI.makeRequest(prompt, provider: .grok, model: AIProvider.grok.defaultModel,
                                            apiKey: "test-key", baseURL: AIProvider.grok.defaultBaseURL)
        assert(grok.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        check(try body(grok)["max_completion_tokens"] as? Int == 2048)
        check(try body(grok)["reasoning_effort"] as? String == "low")
        let mistral = try RemoteAI.makeRequest(prompt, provider: .mistral, model: AIProvider.mistral.defaultModel,
                                               apiKey: "test-key", baseURL: AIProvider.mistral.defaultBaseURL)
        assert(AIProvider.mistral.title == "Mistral · API")
        assert(mistral.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
        assert(mistral.httpMethod == "POST" && mistral.timeoutInterval == 60)
        assert(mistral.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let mistralBody = try body(mistral)
        assert(mistralBody["model"] as? String == "mistral-small-latest")
        assert((mistralBody["messages"] as? [[String: String]])?.first == ["role": "user", "content": prompt])
        assert(mistralBody["max_tokens"] as? Int == 2048 && mistralBody["stream"] as? Bool == false)
        assert(mistralBody["reasoning_effort"] == nil && mistralBody["max_completion_tokens"] == nil)
        for provider in [AIProvider.claude, .gemini, .grok, .mistral, .openAICompatible] {
            let custom = try RemoteAI.makeRequest(prompt, provider: provider, model: "custom-model",
                                                  apiKey: "test-key", baseURL: "https://example.com/v1")
            let customBody = try body(custom)
            assert(customBody["thinking"] == nil && customBody["output_config"] == nil)
            assert(customBody["reasoning_effort"] == nil)
            assert((customBody["generationConfig"] as? [String: Any])?["thinkingConfig"] == nil)
        }
        for base in ["http://127.0.0.1:11434/v1", "http://localhost:1234/v1", "http://[::1]:1234/v1"] {
            let local = try RemoteAI.makeRequest(prompt, provider: .openAICompatible, model: "local-model", apiKey: "", baseURL: base)
            assert(local.value(forHTTPHeaderField: "Authorization") == nil)
            assert(local.url!.path.hasSuffix("/v1/chat/completions"))
        }
        let compatible = try RemoteAI.makeRequest(prompt, provider: .openAICompatible, model: "chosen-model",
                                                  apiKey: "test-key", baseURL: "https://example.com/v1/")
        assert(compatible.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        check(try body(compatible)["max_tokens"] as? Int == 2048)
        for base in ["http://example.com/v1", "ftp://localhost/v1", "https://user:secret@example.com/v1",
                     "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "not a URL"] {
            fails { _ = try RemoteAI.makeRequest(prompt, provider: .openAICompatible, model: "model", apiKey: "test-key", baseURL: base) }
        }
        for provider in [AIProvider.claude, .grok, .gemini, .mistral, .openAICompatible] {
            fails { _ = try RemoteAI.makeRequest(prompt, provider: provider, model: "model", apiKey: "", baseURL: provider.defaultBaseURL) }
        }
        for model in ["../model", "models/model", "model?key=value", "model:generateContent", "model%2Fother", ""] {
            fails { _ = try RemoteAI.makeRequest(prompt, provider: .gemini, model: model, apiKey: "test-key", baseURL: AIProvider.gemini.defaultBaseURL) }
        }
        fails { _ = try RemoteAI.makeRequest(prompt, provider: .grok, model: "model", apiKey: "test\r\nInjected: header", baseURL: AIProvider.grok.defaultBaseURL) }
        fails { _ = try RemoteAI.makeRequest(prompt, provider: .chatgpt, model: "", apiKey: "", baseURL: "") }
        fails { _ = try RemoteAI.makeRequest(prompt, provider: .claudeCode, model: "", apiKey: "test-key", baseURL: "https://api.anthropic.com/v1") }
        fails { _ = try RemoteAI.makeRequest(prompt, provider: .grokBuild, model: "", apiKey: "test-key", baseURL: "https://api.x.ai/v1") }
        fails { _ = try RemoteAI.makeRequest("   ", provider: .claude, model: "model", apiKey: "test-key", baseURL: AIProvider.claude.defaultBaseURL) }

        check(try fixture(#"{"content":[{"type":"thinking","thinking":"privé"},{"type":"text","text":"Bonjour."}],"stop_reason":"end_turn"}"#, provider: .claude) == "Bonjour.")
        check(try fixture(#"{"candidates":[{"content":{"parts":[{"text":"pensée","thought":true},{"text":"Bonjour."}]},"finishReason":"STOP"}]}"#, provider: .gemini) == "Bonjour.")
        check(try fixture(#"{"choices":[{"message":{"content":"Bonjour."},"finish_reason":"stop"}]}"#, provider: .grok) == "Bonjour.")
        check(try fixture(#"{"choices":[{"message":{"content":"  Bonjour.\n"},"finish_reason":"stop"}]}"#, provider: .mistral) == "Bonjour.")
        check(try fixture(#"{"choices":[{"message":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"privé"}]},{"type":"text","text":"Bonjour."}]},"finish_reason":"stop"}]}"#, provider: .mistral) == "Bonjour.")
        check(try fixture(#"{"choices":[{"message":{"content":[{"type":"text","text":"Bonjour."}]}}]}"#, provider: .openAICompatible) == "Bonjour.")
        for provider in [AIProvider.claude, .gemini, .grok, .mistral, .openAICompatible] {
            fails { _ = try fixture("{}", provider: provider) }
            fails { _ = try fixture("not JSON", provider: provider) }
            fails { _ = try fixture("[]", provider: provider) }
            fails { _ = try RemoteAI.readResponse(Data(repeating: 32, count: 1024 * 1024 + 1), statusCode: 200, provider: provider, apiKey: "") }
        }
        fails { _ = try fixture(#"{"choices":[{"message":{"content":"  "}}]}"#, provider: .grok) }
        fails { _ = try fixture(#"{"content":[{"type":"text","text":"tronqué"}],"stop_reason":"max_tokens"}"#, provider: .claude) }
        fails { _ = try fixture(#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#, provider: .gemini) }
        fails { _ = try fixture(#"{"choices":[{"finish_reason":"length"}]}"#, provider: .grok) }
        fails { _ = try fixture(#"{"choices":[{"message":{"content":"tronqué"},"finish_reason":"length"}]}"#, provider: .mistral) }
        do { _ = try fixture(#"{"message":"Clé test-key invalide"}"#, provider: .mistral, status: 401); assertionFailure() }
        catch {
            assert(error.localizedDescription.contains("Mistral · API") && error.localizedDescription.contains("401"))
            assert(error.localizedDescription.contains("[clé masquée]") && !error.localizedDescription.contains("test-key"))
        }

        let reflectedKey = "secret-\"slash\\token"
        let reflected = try JSONSerialization.data(withJSONObject: ["error": ["message": reflectedKey + String(repeating: " échec", count: 100)]])
        do {
            _ = try RemoteAI.readResponse(reflected, statusCode: 401, provider: .claude, apiKey: reflectedKey)
            assertionFailure("HTTP 401 doit échouer.")
        } catch {
            assert(!error.localizedDescription.contains(reflectedKey))
            assert(error.localizedDescription.contains("[clé masquée]"))
            assert(error.localizedDescription.count < 500 && error.localizedDescription.contains("401"))
        }
        do { _ = try fixture("raw test-key", provider: .grok, status: 503); assertionFailure() }
        catch { assert(!error.localizedDescription.contains("test-key")) }
        do { _ = try fixture("", provider: .grok, status: 302); assertionFailure() }
        catch { assert(error.localizedDescription.contains("Redirection")) }

        let request = URLRequest(url: URL(string: "https://example.com")!)
        let task = URLSession.shared.dataTask(with: request)
        let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example.com"])!
        var redirectBlocked = false
        RemoteAI.RedirectBlocker().urlSession(.shared, task: task, willPerformHTTPRedirection: redirect, newRequest: request) { redirectBlocked = $0 == nil }
        assert(redirectBlocked)
        task.cancel()
        print("Tests AIProvider : OK (requêtes REST, URL, clés, réponses, erreurs, redirections). Aucun appel réseau.")
    }
}
