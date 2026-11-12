import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case chatgpt, claudeCode, claude, grokBuild, grok, gemini, mistral, openAICompatible

    var id: String { rawValue }
    var usesAPI: Bool { ![AIProvider.chatgpt, .claudeCode, .grokBuild].contains(self) }

    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT · abonnement Codex"
        case .claudeCode: return "Claude · abonnement Claude Code"
        case .claude: return "Claude · API"
        case .grokBuild: return "Grok · abonnement Grok Build"
        case .grok: return "Grok · API"
        case .gemini: return "Gemini · API"
        case .mistral: return "Mistral · API"
        case .openAICompatible: return "API compatible OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .chatgpt, .claudeCode, .grokBuild, .openAICompatible: return ""
        case .claude: return "claude-haiku-5-5"
        case .grok: return "grok-4.7"
        case .gemini: return "gemini-3.8-flash"
        case .mistral: return "mistral-small-latest"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .chatgpt, .claudeCode, .grokBuild: return ""
        case .claude: return "https://api.anthropic.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .mistral: return "https://api.mistral.ai/v1"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }
}

enum RemoteAI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func ask(_ prompt: String, provider: AIProvider, model: String,
                    apiKey: String, baseURL: String) async throws -> String {
        let request = try makeRequest(prompt, provider: provider, model: model,
                                      apiKey: apiKey, baseURL: baseURL)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectBlocker())
        } catch {
            throw Failure(message: "Connexion à \(provider.title) impossible : \(safeMessage(error.localizedDescription, apiKey: apiKey))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "Réponse HTTP absente de \(provider.title).")
        }
        return try readResponse(data, statusCode: http.statusCode, provider: provider, apiKey: apiKey)
    }

    static func makeRequest(_ prompt: String, provider: AIProvider, model: String,
                            apiKey: String, baseURL: String) throws -> URLRequest {
        guard provider.usesAPI else {
            throw Failure(message: "Les modes abonnement utilisent leur outil officiel, pas une clé API.")
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isEmpty else {
            throw Failure(message: "Une question et un identifiant de modèle sont requis.")
        }
        guard let components = URLComponents(string: base), let url = components.url,
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw Failure(message: "URL de base invalide : utilise une URL sans identifiants, paramètres ni fragment.")
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard components.scheme?.lowercased() == "https" ||
                (components.scheme?.lowercased() == "http" && local) else {
            throw Failure(message: "HTTPS est requis, sauf pour un serveur local sur localhost, 127.0.0.1 ou ::1.")
        }
        guard !key.isEmpty || (provider == .openAICompatible && local) else {
            throw Failure(message: "Une clé API est requise pour ce fournisseur.")
        }
        guard key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure(message: "La clé API contient des caractères non autorisés.")
        }

        let endpoint: URL
        var body: [String: Any]
        switch provider {
        case .claude:
            // https://platform.claude.com/docs/en/api/messages/create (2026-10-21)
            endpoint = url.appendingPathComponent("messages")
            body = ["model": model, "max_tokens": 2048,
                    "messages": [["role": "user", "content": prompt]]]
            if model == AIProvider.claude.defaultModel {
                body["thinking"] = ["type": "disabled"]
                body["output_config"] = ["effort": "low"]
            }
        case .gemini:
            // https://aistudio.google.com/api-reference/generate-content/generate-content
            guard model.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$", options: .regularExpression) != nil else {
                throw Failure(message: "Identifiant Gemini invalide : indique uniquement le nom du modèle, sans chemin ni paramètres.")
            }
            endpoint = url.appendingPathComponent("models").appendingPathComponent(model + ":generateContent")
            body = ["contents": [["role": "user", "parts": [["text": prompt]]]],
                    "generationConfig": ["maxOutputTokens": 2048]]
            if model == AIProvider.gemini.defaultModel {
                body["generationConfig"] = ["maxOutputTokens": 2048,
                                            "thinkingConfig": ["thinkingLevel": "low"]]
            }
        case .grok, .mistral, .openAICompatible:
            // https://docs.x.ai/developers/rest-api-reference/inference/chat-completions
            endpoint = url.appendingPathComponent("chat/completions")
            body = ["model": model, "messages": [["role": "user", "content": prompt]],
                    provider == .grok ? "max_completion_tokens" : "max_tokens": 2048,
                    "stream": false]
            if provider == .grok, model == AIProvider.grok.defaultModel {
                body["reasoning_effort"] = "low"
            }
        case .chatgpt, .claudeCode, .grokBuild:
            throw Failure(message: "Ce mode abonnement n’utilise pas l’API.")
        }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .gemini {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else if !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        if provider == .claude { request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func readResponse(_ data: Data, statusCode: Int, provider: AIProvider, apiKey: String) throws -> String {
        // shortcut: data(for:) buffers before this size check; use streaming if an untrusted server needs a hard download cap.
        guard data.count <= 1024 * 1024 else {
            throw Failure(message: "Réponse du fournisseur supérieure à 1 Mio.")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(statusCode) else {
            if (300...399).contains(statusCode) {
                throw Failure(message: "Redirection HTTP \(statusCode) refusée pour protéger la clé API.")
            }
            let detail = (object?["error"] as? [String: Any])?["message"] as? String
                ?? object?["error"] as? String ?? object?["message"] as? String
            let suffix = detail.map { " : " + safeMessage($0, apiKey: apiKey) } ?? ""
            throw Failure(message: "\(provider.title) — erreur HTTP \(statusCode)\(suffix)")
        }
        guard let object else { throw Failure(message: "Réponse JSON invalide du fournisseur.") }
        let text: String
        switch provider {
        case .claude:
            guard object["stop_reason"] as? String != "max_tokens" else {
                throw Failure(message: "Claude a atteint la limite de réponse ; reformule une question plus courte.")
            }
            text = textBlocks(object["content"])
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            guard candidate?["finishReason"] as? String != "MAX_TOKENS" else {
                throw Failure(message: "Gemini a atteint la limite de réponse ; reformule une question plus courte.")
            }
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .grok, .mistral, .openAICompatible:
            let choice = (object["choices"] as? [[String: Any]])?.first
            guard choice?["finish_reason"] as? String != "length" else {
                throw Failure(message: "Le fournisseur a atteint la limite de réponse ; reformule une question plus courte.")
            }
            let content = (choice?["message"] as? [String: Any])?["content"]
            text = content as? String ?? textBlocks(content)
        case .chatgpt, .claudeCode, .grokBuild:
            throw Failure(message: "Ce mode abonnement n’utilise pas l’API.")
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure(message: "Le fournisseur n’a renvoyé aucun texte utilisable.") }
        return answer
    }

    private static func textBlocks(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func safeMessage(_ message: String, apiKey: String) -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[clé masquée]")
        return String(redacted.prefix(400))
    }

    final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
