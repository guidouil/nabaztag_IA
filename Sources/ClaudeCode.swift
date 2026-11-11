import Foundation

enum ClaudeCode {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct AuthStatus: Decodable {
        let loggedIn: Bool
        let authMethod: String
    }

    private struct ResultMessage: Decodable {
        let type: String
        let subtype: String
        let is_error: Bool
        let result: String?
        let errors: [String]?
    }

    static var executable: String? {
        executableCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var executableCandidates: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    static var isInstalled: Bool { executable != nil }

    // Safe mode retains the CLI's own OAuth login; --bare would disable it.
    // https://code.claude.com/docs/en/cli-reference
    static let isolationArguments = [
        "--safe-mode", "--setting-sources", "",
        "--settings", #"{"forceLoginMethod":"claudeai","apiKeyHelper":""}"#
    ]
    static let authArguments = isolationArguments + ["auth", "status"]
    static let requestArguments = isolationArguments + [
        "-p", "--effort", "low", "--output-format", "json", "--tools", "", "--disallowedTools", "*",
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        "--permission-mode", "dontAsk", "--no-session-persistence", "--no-chrome"
    ]

    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // A whitelist also excludes API helpers, gateways, cloud providers and injected OAuth tokens.
        let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE",
                           "SHELL", "TERM", "__CF_USER_TEXT_ENCODING", "XPC_SERVICE_NAME", "XPC_FLAGS"])
        var result = inherited.filter { allowed.contains($0.key) }
        result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        result["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
        result["CLAUDE_CODE_DISABLE_FAST_MODE"] = "1"
        result["DISABLE_AUTOUPDATER"] = "1"
        result["NO_COLOR"] = "1"
        return result
    }

    static func diagnostic() async throws -> String {
        guard let executable else {
            return "Claude Code : non installé. Installe le CLI officiel, puis lance claude auth login dans Terminal."
        }
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = try await authentication(executable: executable, directory: folder, environment: environment())
        if !status.loggedIn {
            return "Claude Code : non connecté. Lance claude auth login dans Terminal et choisis ton compte claude.ai. Aucun appel au modèle effectué."
        }
        guard status.authMethod == "claude.ai" else {
            return "Claude Code : authentification API, externe ou inconnue refusée. Reconnecte le CLI avec ton compte claude.ai. Aucun appel au modèle effectué."
        }
        return "Claude Code : connecté avec claude.ai. Aucun appel au modèle effectué. Les quotas et l’éventuel extra usage dépendent du compte Claude."
    }

    static func ask(_ prompt: String) async throws -> String {
        guard let executable else {
            throw Failure(message: "Claude Code n’est pas installé. Installe le CLI officiel, puis connecte ton compte avec claude auth login dans Terminal.")
        }
        return try await ask(prompt, executable: executable)
    }

    static func ask(_ prompt: String, executable: String) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "La question est vide.")
        }
        guard prompt.utf8.count <= 128 * 1024 else {
            throw Failure(message: "La question dépasse la taille maximale (128 Kio).")
        }
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = environment()
        let status = try await authentication(executable: executable, directory: folder, environment: environment)
        try requireSubscription(status)
        do {
            let data = try await Bridge.run(executable, requestArguments, input: Data(prompt.utf8),
                                            timeout: 180, directory: folder, environment: environment)
            return try parseResult(data)
        } catch let failure as Bridge.ProcessFailure {
            return try parseResult(failure.stdout, exitCode: failure.exitCode, stderr: failure.stderr)
        }
    }

    static func authentication(executable: String, directory: URL, environment: [String: String]) async throws -> AuthStatus {
        do {
            let data = try await Bridge.run(executable, authArguments, timeout: 30,
                                            directory: directory, environment: environment)
            return try parseStatus(data)
        } catch let failure as Bridge.ProcessFailure {
            // The documented exit code for a valid but logged-out status is 1.
            if failure.exitCode == 1, let status = try? parseStatus(failure.stdout), !status.loggedIn {
                return status
            }
            throw Failure(message: "Impossible de vérifier la connexion Claude Code (code \(failure.exitCode)). Mets le CLI à jour et lance claude auth status dans Terminal.")
        }
    }

    static func parseStatus(_ data: Data) throws -> AuthStatus {
        guard data.count <= 64 * 1024, let status = try? JSONDecoder().decode(AuthStatus.self, from: data) else {
            throw Failure(message: "Le statut de connexion Claude Code est invalide. Mets le CLI à jour et reconnecte ton compte claude.ai.")
        }
        return status
    }

    static func requireSubscription(_ status: AuthStatus) throws {
        guard status.loggedIn else {
            throw Failure(message: "Claude Code n’est pas connecté. Lance claude auth login dans Terminal et choisis ton compte claude.ai.")
        }
        guard status.authMethod == "claude.ai" else {
            throw Failure(message: "Ce mode exige la connexion claude.ai du CLI officiel. L’authentification API, externe ou inconnue est refusée.")
        }
    }

    static func parseResult(_ data: Data, exitCode: Int32 = 0, stderr: String = "") throws -> String {
        guard data.count <= 1024 * 1024 else {
            throw Failure(message: "La réponse Claude Code dépasse la taille maximale (1 Mio).")
        }
        guard let result = try? JSONDecoder().decode(ResultMessage.self, from: data), result.type == "result" else {
            if exitCode != 0 {
                let detail = safeMessage(stderr.isEmpty ? String(decoding: data, as: UTF8.self) : stderr)
                throw Failure(message: "Claude Code a échoué (code \(exitCode))." + (detail.isEmpty ? "" : " \(detail)"))
            }
            throw Failure(message: "Claude Code a renvoyé un résultat JSON invalide. Mets le CLI à jour.")
        }
        guard exitCode == 0, !result.is_error, result.subtype == "success" else {
            let detail = safeMessage(([result.result].compactMap { $0 } + (result.errors ?? [])).joined(separator: "\n"))
            let code = exitCode == 0 ? "" : " (code \(exitCode))"
            throw Failure(message: "Claude Code a échoué\(code)." + (detail.isEmpty ? " Quota, connexion ou limite de session à vérifier dans le CLI." : " \(detail)"))
        }
        let answer = result.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else { throw Failure(message: "Claude Code a renvoyé une réponse vide.") }
        return answer
    }

    static func safeMessage(_ text: String) -> String {
        var result = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            ($0.value >= 32 && $0.value != 127) || $0.value == 10
        }))
        for pattern in [
            #"(?i)\bsk-(?:ant-)?[a-z0-9_-]+"#,
            #"(?i)Bearer\s+[^\s\"']+"#,
            #"(?i)(access_token|refresh_token|api_key|authorization)[\"\s:=]+[^\s\",}]+"#,
            #"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[secret masqué]", options: .regularExpression)
        }
        return String(result.prefix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
