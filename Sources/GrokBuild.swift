import Foundation

enum GrokBuild {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".grok/bin/grok").path,
                home.appendingPathComponent(".local/bin/grok").path,
                "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
    }
    static var executable: String? {
        executableCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var isInstalled: Bool { executable != nil }

    static let configuration = """
    [models]
    default = "grok-4.7"
    default_reasoning_effort = "low"
    allowed_models = ["grok-4.7"]
    [grok_com_config]
    disable_api_key_auth = true
    [cli]
    auto_update = false
    [ui]
    permission_mode = "dontAsk"
    """

    // Empty/unknown allowlists keep tools enabled. A recognized but removed tool leaves none.
    // https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-agent/src/tool_list.rs
    static let requestArguments = [
        "--model", "grok-4.7", "--reasoning-effort", "low", "--output-format", "json", "--verbatim",
        "--tools", "read_file", "--disallowed-tools", "read_file,search_tool,use_tool,Agent",
        "--permission-mode", "dontAsk", "--sandbox", "strict", "--max-turns", "1",
        "--no-plan", "--no-subagents", "--disable-web-search"
    ]

    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE",
                           "SHELL", "TERM", "__CF_USER_TEXT_ENCODING", "XPC_SERVICE_NAME", "XPC_FLAGS"])
        var result = inherited.filter { allowed.contains($0.key) }
        result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        for name in ["GROK_DISABLE_API_KEY_AUTH", "GROK_DISABLE_AUTOUPDATER"] { result[name] = "1" }
        for name in ["GROK_MEMORY", "GROK_SUBAGENTS", "GROK_GOAL", "GROK_WORKFLOWS",
                     "GROK_WRITE_FILE", "GROK_WEB_FETCH", "GROK_LSP_TOOLS"] { result[name] = "0" }
        for product in ["CURSOR", "CLAUDE"] {
            for feature in ["SKILLS", "RULES", "AGENTS", "MCPS", "HOOKS", "SESSIONS"] {
                result["GROK_\(product)_\(feature)_ENABLED"] = "false"
            }
        }
        result["GROK_CODEX_SESSIONS_ENABLED"] = "false"
        result["NO_COLOR"] = "1"
        return result
    }

    static func isolatedEnvironment(in directory: URL) throws -> [String: String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for name in ["config.toml", "requirements.toml"] {
            try Data(configuration.utf8).write(to: directory.appendingPathComponent(name))
        }
        var result = environment()
        result["GROK_HOME"] = directory.path
        result["GROK_CONFIG_PATH"] = directory.appendingPathComponent("config.toml").path
        // The official CLI owns reads and atomic refresh writes; Swift never reads/copies tokens.
        result["GROK_AUTH_PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json").path
        return result
    }

    static func parseInspection(_ data: Data, directory: URL) throws {
        guard data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = object["loginPolicy"] as? [String: Any], login["disableApiKeyAuth"] as? Bool == true,
              let sources = object["configSources"] as? [String: Any], let layers = sources["layers"] as? [[String: Any]],
              let permissions = object["permissions"] as? [String: Any], permissions["managedSettingsActive"] as? Bool == false,
              let external = object["externalCompat"] as? [String: Any], external["remoteSettingsLoaded"] as? Bool == false,
              let cells = external["cells"] as? [[String: Any]], cells.allSatisfy({ $0["enabled"] as? Bool == false }),
              let agents = object["agents"] as? [[String: Any]], agents.allSatisfy({
                  ($0["source"] as? [String: Any])?["type"] as? String == "builtin"
              }) else { throw Failure(message: "Impossible de garantir l’isolation ou la connexion par abonnement de Grok Build. Mets le CLI à jour.") }
        for name in ["hooks", "skills", "plugins", "marketplaces", "mcpServers", "lspServers", "projectInstructions"] {
            guard let items = object[name] as? [Any], items.isEmpty else {
                throw Failure(message: "Grok Build a découvert une personnalisation externe. Ce mode vocal la refuse.")
            }
        }
        let expected = Set(["config.toml", "requirements.toml"].map { directory.appendingPathComponent($0).path })
        var found = Set<String>()
        for layer in layers where layer["note"] as? String != "empty" {
            guard let path = layer["path"] as? String, expected.contains(path) else {
                throw Failure(message: "Une configuration Grok externe empêche de garantir ce mode par abonnement.")
            }
            found.insert(path)
        }
        guard found == expected else { throw Failure(message: "La politique temporaire Grok Build n’a pas été chargée.") }
    }

    private static func inspect(executable: String, directory: URL, environment: [String: String]) async throws {
        do {
            let data = try await Bridge.run(executable, ["inspect", "--json"], timeout: 20,
                                            directory: directory.deletingLastPathComponent(), environment: environment)
            try parseInspection(data, directory: directory)
        } catch is Bridge.ProcessFailure {
            throw Failure(message: "Impossible de vérifier l’isolation Grok Build. Mets le CLI à jour ; aucun appel au modèle effectué.")
        }
    }

    static func diagnostic() async throws -> String {
        guard let executable else { return "Grok Build : non installé. Installe le CLI officiel depuis x.ai, puis lance grok login dans Terminal." }
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("grok-home")
        try await inspect(executable: executable, directory: home, environment: isolatedEnvironment(in: home))
        return "Grok Build : installé, isolation vérifiée. Connexion et abonnement non vérifiés sans appel au modèle. Lance grok login dans Terminal pour connecter SuperGrok. Aucun repli API ; les quotas et crédits supplémentaires dépendent du compte Grok."
    }

    static func ask(_ prompt: String) async throws -> String {
        guard let executable else { throw Failure(message: "Grok Build n’est pas installé. Installe le CLI officiel depuis x.ai, puis lance grok login dans Terminal.") }
        return try await ask(prompt, executable: executable)
    }

    static func ask(_ prompt: String, executable: String) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 128 * 1024 else {
            throw Failure(message: "La question doit être non vide et ne pas dépasser 128 Kio.")
        }
        // shortcut: Grok expands @file before tool permissions; remove this guard when a verified opt-out exists.
        guard !prompt.contains("@") else { throw Failure(message: "Le caractère @ est refusé dans ce mode : le CLI pourrait l’interpréter comme un fichier à lire.") }
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("grok-home")
        let environment = try isolatedEnvironment(in: home)
        try await inspect(executable: executable, directory: home, environment: environment)
        let file = folder.appendingPathComponent("prompt.txt")
        try Data(prompt.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            return try parseResult(await Bridge.run(executable, requestArguments + ["--prompt-file", file.path],
                                                    timeout: 180, directory: folder, environment: environment))
        } catch let failure as Bridge.ProcessFailure {
            return try parseResult(failure.stdout, exitCode: failure.exitCode, stderr: failure.stderr)
        }
    }

    static func parseResult(_ data: Data, exitCode: Int32 = 0, stderr: String = "") throws -> String {
        guard data.count <= 1024 * 1024 else { throw Failure(message: "La réponse Grok Build dépasse 1 Mio.") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if exitCode != 0 || object?["type"] as? String == "error" {
            let detail = safeMessage(object?["message"] as? String ?? stderr)
            throw Failure(message: "Grok Build a échoué (code \(exitCode))." + (detail.isEmpty ? " Lance grok login ou vérifie ton quota." : " \(detail)"))
        }
        guard let object, object["stopReason"] as? String == "end_turn", let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Résultat Grok Build invalide, vide ou interrompu. Mets le CLI à jour ou vérifie ton quota.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeMessage(_ text: String) -> String {
        var result = String(String.UnicodeScalarView(text.unicodeScalars.filter { ($0.value >= 32 && $0.value != 127) || $0.value == 10 }))
        for pattern in [#"(?i)\bxai-[a-z0-9_-]+"#, #"(?i)Bearer\s+[^\s\"']+"#,
                        #"(?i)(access_token|refresh_token|api_key|authorization)[\"\s:=]+[^\s\",}]+"#,
                        #"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#] {
            result = result.replacingOccurrences(of: pattern, with: "[secret masqué]", options: .regularExpression)
        }
        return String(result.prefix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
