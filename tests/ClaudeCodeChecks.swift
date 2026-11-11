import Foundation

@main
struct ClaudeCodeChecks {
    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func fakeExecutable(in folder: URL) throws -> String {
        let script = #"""
        #!/bin/sh
        set -eu
        fixture=${0%/*}
        mode=request
        for argument in "$@"; do
            if [ "$argument" = auth ]; then mode=auth; fi
        done
        printf '1' >> "$fixture/$mode-calls"
        printf '%s\0' "$@" > "$fixture/$mode-arguments"
        /usr/bin/env > "$fixture/$mode-environment"
        /bin/pwd > "$fixture/$mode-directory"
        /bin/cat > "$fixture/$mode-input"
        /bin/cat "$fixture/$mode.json"
        /bin/cat "$fixture/$mode.stderr" >&2
        status=$(/bin/cat "$fixture/$mode.exit")
        exit "$status"
        """#
        let file = folder.appendingPathComponent("claude-fixture")
        try data(script).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }

    static func prepare(_ folder: URL, auth: Data, authCode: Int32 = 0, result: Data, resultCode: Int32 = 0,
                        stderr: String = "") throws {
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("auth-") || file.lastPathComponent.hasPrefix("request-") {
            try FileManager.default.removeItem(at: file)
        }
        try auth.write(to: folder.appendingPathComponent("auth.json"))
        try data(String(authCode)).write(to: folder.appendingPathComponent("auth.exit"))
        try Data().write(to: folder.appendingPathComponent("auth.stderr"))
        try result.write(to: folder.appendingPathComponent("request.json"))
        try data(String(resultCode)).write(to: folder.appendingPathComponent("request.exit"))
        try data(stderr).write(to: folder.appendingPathComponent("request.stderr"))
    }

    static func arguments(_ folder: URL, mode: String) throws -> [String] {
        try Data(contentsOf: folder.appendingPathComponent("\(mode)-arguments"))
            .split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    static func contents(_ folder: URL, _ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    static func fails(_ operation: () throws -> Void) {
        do { try operation(); assertionFailure("Cette entrée doit être refusée.") }
        catch { assert(error is ClaudeCode.Failure) }
    }

    static func failsAsync(_ operation: () async throws -> Void) async {
        do { try await operation(); assertionFailure("Cet appel doit échouer.") }
        catch { assert(error is ClaudeCode.Failure) }
    }

    static func main() async throws {
        let login = data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"private@example.test","access_token":"do-not-expose"}"#)
        let success = data(#"{"type":"result","subtype":"success","is_error":false,"result":"  Bonjour.\n"}"#)
        let status = try ClaudeCode.parseStatus(login)
        try ClaudeCode.requireSubscription(status)
        for method in ["api_key", "api_key_helper", "oauth_token", "third_party", "none", "unknown", ""] {
            let fixture = try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": method])
            fails { try ClaudeCode.requireSubscription(ClaudeCode.parseStatus(fixture)) }
        }
        fails { try ClaudeCode.requireSubscription(ClaudeCode.parseStatus(data(#"{"loggedIn":false,"authMethod":"claude.ai"}"#))) }
        for fixture in ["", "not JSON", "[]", "{}", #"{"loggedIn":"true","authMethod":"claude.ai"}"#,
                        #"{"loggedIn":true}"#, #"{"loggedIn":true,"authMethod":null}"#] {
            fails { _ = try ClaudeCode.parseStatus(data(fixture)) }
        }
        fails { _ = try ClaudeCode.parseStatus(Data(repeating: 32, count: 65537)) }

        let parsed = try ClaudeCode.parseResult(success)
        assert(parsed == "Bonjour.")
        for fixture in ["", "not JSON", "[]", "{}", #"{"type":"assistant","subtype":"success","is_error":false,"result":"text"}"#,
                        #"{"type":"result","subtype":"success","is_error":"false","result":"text"}"#,
                        #"{"type":"result","subtype":"success","is_error":false,"result":"  "}"#,
                        #"{"type":"result","subtype":"success","is_error":false}"#,
                        #"{"type":"result","subtype":"error_max_turns","is_error":false,"result":"incomplet"}"#,
                        #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Quota atteint"]}"#] {
            fails { _ = try ClaudeCode.parseResult(data(fixture)) }
        }
        fails { _ = try ClaudeCode.parseResult(success, exitCode: 1) }
        fails { _ = try ClaudeCode.parseResult(Data(repeating: 32, count: 1024 * 1024 + 1)) }
        do {
            _ = try ClaudeCode.parseResult(data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Limite atteinte"}"#), exitCode: 2)
            assertionFailure()
        } catch {
            assert(error.localizedDescription.contains("Limite atteinte") && error.localizedDescription.contains("code 2"))
        }
        do {
            _ = try ClaudeCode.parseResult(data("not JSON"), exitCode: 4, stderr: "Erreur sk-ant-api03-secret Bearer oauth-secret\n" + String(repeating: "x", count: 2000))
            assertionFailure()
        } catch {
            assert(error.localizedDescription.contains("code 4"))
            assert(!error.localizedDescription.contains("sk-ant-api03-secret") && !error.localizedDescription.contains("oauth-secret"))
            assert(error.localizedDescription.count < 850)
        }
        let redacted = ClaudeCode.safeMessage(#"{"access_token":"opaque-secret","refresh_token":"private-refresh","api_key":"private-key"}"#)
        for secret in ["opaque-secret", "private-refresh", "private-key"] { assert(!redacted.contains(secret)) }

        var inherited = ["HOME": "/wrong-home", "USER": "fixture", "LANG": "fr_FR.UTF-8", "PATH": "/usr/bin"]
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
                    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_SIMPLE", "CLAUDECODE",
                    "CLAUDE_CODE_EFFORT_LEVEL",
                    "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                    "AWS_ACCESS_KEY_ID", "GOOGLE_APPLICATION_CREDENTIALS", "AZURE_CLIENT_SECRET", "HTTPS_PROXY",
                    "HTTP_PROXY", "ALL_PROXY", "NODE_OPTIONS", "OPENAI_API_KEY", "CODEX_API_KEY"] {
            inherited[key] = "secret-fixture"
        }
        let environment = ClaudeCode.environment(inherited: inherited)
        assert(!environment.values.contains("secret-fixture"))
        assert(environment["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        assert(environment["USER"] == "fixture" && environment["LANG"] == "fr_FR.UTF-8")
        assert(environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] == "1" && environment["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
        assert(!ClaudeCode.requestArguments.contains("--bare") && !ClaudeCode.requestArguments.contains("--dangerously-skip-permissions"))
        for flag in ["--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--no-chrome"] {
            assert(ClaudeCode.requestArguments.contains(flag))
        }
        for (flag, value) in [("--setting-sources", ""), ("--tools", ""), ("--disallowedTools", "*"),
                              ("--permission-mode", "dontAsk"), ("--output-format", "json"), ("--effort", "low"),
                              ("--mcp-config", #"{"mcpServers":{}}"#)] {
            let index = ClaudeCode.requestArguments.firstIndex(of: flag)!
            assert(ClaudeCode.requestArguments[index + 1] == value)
        }
        let settings = ClaudeCode.isolationArguments[ClaudeCode.isolationArguments.firstIndex(of: "--settings")! + 1]
        let settingsObject = try JSONSerialization.jsonObject(with: data(settings)) as! [String: String]
        assert(settingsObject["forceLoginMethod"] == "claudeai" && settingsObject["apiKeyHelper"] == "")
        assert(ClaudeCode.authArguments.suffix(2) == ["auth", "status"])
        assert(ClaudeCode.executableCandidates.count == 3 && ClaudeCode.executableCandidates[0].hasSuffix("/.local/bin/claude"))

        let prompt = "--model fake; `touch /tmp/injection` $(echo secret)\nUne question française."
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try fakeExecutable(in: folder)
        try prepare(folder, auth: login, result: success)
        let answer = try await ClaudeCode.ask(prompt, executable: executable)
        assert(answer == "Bonjour.")
        let authArguments = try arguments(folder, mode: "auth"), requestArguments = try arguments(folder, mode: "request")
        assert(authArguments == ClaudeCode.authArguments && requestArguments == ClaudeCode.requestArguments)
        let requestInput = try contents(folder, "request-input"), authInput = try contents(folder, "auth-input")
        assert(authInput.isEmpty && requestInput == prompt && !requestArguments.contains(prompt))
        let authDirectory = try contents(folder, "auth-directory").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestDirectory = try contents(folder, "request-directory").trimmingCharacters(in: .whitespacesAndNewlines)
        assert(authDirectory == requestDirectory && !FileManager.default.fileExists(atPath: requestDirectory))
        let childEnvironment = try contents(folder, "request-environment")
        assert(!childEnvironment.contains("ANTHROPIC_") && !childEnvironment.contains("OPENAI_API_KEY=") && !childEnvironment.contains("CLAUDE_CODE_SIMPLE="))
        assert(childEnvironment.contains("CLAUDE_CODE_DISABLE_FAST_MODE=1"))

        let loggedOut = data(#"{"loggedIn":false,"authMethod":"none"}"#)
        for (auth, code) in [(loggedOut, Int32(0)), (loggedOut, 1), (login, 2),
                             (data(#"{"loggedIn":true,"authMethod":"api_key"}"#), 0), (data("invalid JSON"), 0)] {
            try prepare(folder, auth: auth, authCode: code, result: success)
            await failsAsync { _ = try await ClaudeCode.ask(prompt, executable: executable) }
            assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("request-arguments").path))
            let directory = try contents(folder, "auth-directory").trimmingCharacters(in: .whitespacesAndNewlines)
            assert(!FileManager.default.fileExists(atPath: directory))
        }

        try prepare(folder, auth: login,
                    result: data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Quota atteint"]}"#), resultCode: 1)
        do { _ = try await ClaudeCode.ask(prompt, executable: executable); assertionFailure() }
        catch { assert(error.localizedDescription.contains("Quota atteint")) }
        let directory = try contents(folder, "request-directory").trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!FileManager.default.fileExists(atPath: directory))
        try prepare(folder, auth: login, result: Data(), resultCode: 2, stderr: "error: unknown option '--effort'")
        do { _ = try await ClaudeCode.ask(prompt, executable: executable); assertionFailure() }
        catch { assert(error.localizedDescription.contains("unknown option '--effort'")) }
        let requestCalls = try contents(folder, "request-calls")
        let refusedArguments = try arguments(folder, mode: "request")
        assert(requestCalls == "1" && refusedArguments == ClaudeCode.requestArguments,
               "Une option inconnue doit échouer sans réessayer ni changer d’authentification.")
        try prepare(folder, auth: login, result: success)
        await failsAsync { _ = try await ClaudeCode.ask(" \n", executable: executable) }
        await failsAsync { _ = try await ClaudeCode.ask(String(repeating: "x", count: 128 * 1024 + 1), executable: executable) }
        assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("auth-arguments").path))
        print("Tests Claude Code : OK (auth abonnement, isolation, JSON, erreurs, vrai subprocess avec faux CLI, nettoyage). Aucun appel réseau, compte ou Trousseau.")
    }
}
