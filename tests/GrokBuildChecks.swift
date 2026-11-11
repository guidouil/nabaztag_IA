import Foundation
import Darwin

@main
struct GrokBuildChecks {
    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func fakeExecutable(in folder: URL) throws -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let script = "#!/bin/sh\nexec \(quote(binary)) --fixture \(quote(folder.path)) \"$@\"\n"
        let path = folder.appendingPathComponent("grok-fixture")
        try data(script).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }

    static func inspection(_ directory: URL) -> [String: Any] {
        ["loginPolicy": ["disableApiKeyAuth": true],
         "configSources": ["layers": [["role": "user", "path": directory.appendingPathComponent("config.toml").path],
                                        ["role": "requirements", "path": directory.appendingPathComponent("requirements.toml").path]]],
         "hooks": [], "skills": [], "plugins": [], "marketplaces": [], "mcpServers": [], "lspServers": [],
         "projectInstructions": [], "agents": [["source": ["type": "builtin"]]],
         "permissions": ["managedSettingsActive": false],
         "externalCompat": ["remoteSettingsLoaded": false, "cells": []]]
    }

    static func runFixture(_ folder: URL, arguments: [String]) throws -> Never {
        let isInspection = arguments.contains("inspect")
        let prefix = isInspection ? "inspect-" : ""
        let count = folder.appendingPathComponent(prefix + "calls")
        var calls = (try? Data(contentsOf: count)) ?? Data()
        calls.append(data("1"))
        try calls.write(to: count)
        try data(arguments.joined(separator: "\0") + "\0").write(to: folder.appendingPathComponent(prefix + "arguments"))
        let environment = ProcessInfo.processInfo.environment
        try data(environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")).write(to: folder.appendingPathComponent(prefix + "environment"))
        try data(FileManager.default.currentDirectoryPath).write(to: folder.appendingPathComponent(prefix + "directory"))
        try FileHandle.standardInput.readDataToEndOfFile().write(to: folder.appendingPathComponent(prefix + "input"))
        if let index = arguments.firstIndex(of: "--prompt-file"), index + 1 < arguments.count {
            try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])).write(to: folder.appendingPathComponent("prompt"))
        }
        if let home = environment["GROK_HOME"] {
            for name in ["config.toml", "requirements.toml"] {
                try Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent(name))
                    .write(to: folder.appendingPathComponent(name))
            }
        }
        if isInspection {
            let override = folder.appendingPathComponent("inspection.json")
            let output = FileManager.default.fileExists(atPath: override.path) ? try Data(contentsOf: override)
                : try JSONSerialization.data(withJSONObject: inspection(URL(fileURLWithPath: environment["GROK_HOME"]!)))
            FileHandle.standardOutput.write(output)
            exit(0)
        }
        FileHandle.standardOutput.write(try Data(contentsOf: folder.appendingPathComponent("result.json")))
        FileHandle.standardError.write(try Data(contentsOf: folder.appendingPathComponent("stderr")))
        exit(Int32(try contents(folder, "exit"))!)
    }

    static func prepare(_ folder: URL, result: Data, exitCode: Int32 = 0, stderr: String = "") throws {
        for name in ["arguments", "environment", "directory", "input", "prompt", "config.toml", "requirements.toml",
                     "inspect-arguments", "inspect-environment", "inspect-directory", "inspect-input", "inspection.json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        try result.write(to: folder.appendingPathComponent("result.json"))
        try data(String(exitCode)).write(to: folder.appendingPathComponent("exit"))
        try data(stderr).write(to: folder.appendingPathComponent("stderr"))
        for name in ["calls", "inspect-calls"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    static func contents(_ folder: URL, _ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    static func fails(_ operation: () throws -> Void) {
        do { try operation(); assertionFailure("Cette entrée doit être refusée.") }
        catch { assert(error is GrokBuild.Failure) }
    }

    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--fixture" {
            try runFixture(URL(fileURLWithPath: CommandLine.arguments[2]), arguments: Array(CommandLine.arguments.dropFirst(3)))
        }
        let success = data(#"{"text":"  Bonjour.\n","stopReason":"end_turn","sessionId":"fixture-session","requestId":"fixture-request"}"#)
        let answer = try GrokBuild.parseResult(success)
        assert(answer == "Bonjour.")
        for fixture in ["", "not JSON", "[]", "{}", #"{"text":42,"stopReason":"end_turn"}"#,
                        #"{"text":"  ","stopReason":"end_turn"}"#, #"{"stopReason":"end_turn"}"#,
                        #"{"text":"incomplet","stopReason":"max_tokens"}"#,
                        #"{"text":"incomplet","stopReason":"max_turn_requests"}"#,
                        #"{"text":"incomplet","stopReason":"cancelled"}"#,
                        #"{"type":"error","message":"Connexion nécessaire"}"#] {
            fails { _ = try GrokBuild.parseResult(data(fixture)) }
        }
        fails { _ = try GrokBuild.parseResult(success, exitCode: 1) }
        fails { _ = try GrokBuild.parseResult(Data(repeating: 32, count: 1024 * 1024 + 1)) }
        do {
            _ = try GrokBuild.parseResult(data(#"{"type":"error","message":"Quota atteint"}"#), exitCode: 3)
            assertionFailure()
        } catch {
            assert(error.localizedDescription.contains("Quota atteint") && error.localizedDescription.contains("3"))
        }
        do {
            _ = try GrokBuild.parseResult(data("not JSON"), exitCode: 4,
                                          stderr: "Erreur xai-private-key Bearer private-token\n" + String(repeating: "x", count: 2000))
            assertionFailure()
        } catch {
            assert(!error.localizedDescription.contains("xai-private-key") && !error.localizedDescription.contains("private-token"))
            assert(error.localizedDescription.count < 1000)
        }

        var inherited = ["HOME": "/wrong-home", "USER": "fixture", "LANG": "fr_FR.UTF-8", "PATH": "/usr/bin"]
        for key in ["XAI_API_KEY", "GROK_AUTH", "GROK_AUTH_PATH", "GROK_HOME", "GROK_CONFIG_PATH", "GROK_DEPLOYMENT_KEY",
                    "GROK_OIDC_ISSUER", "GROK_OIDC_CLIENT_ID", "GROK_MODELS_BASE_URL", "GROK_MODELS_LIST_URL",
                    "GROK_XAI_API_BASE_URL", "GROK_AGENT", "GROK_LOG_FILE", "RUST_LOG", "GROK_EXTRA_AUTH_KEY",
                    "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY",
                    "AWS_ACCESS_KEY_ID", "GOOGLE_APPLICATION_CREDENTIALS", "NODE_OPTIONS"] {
            inherited[key] = "secret-fixture"
        }
        let environment = GrokBuild.environment(inherited: inherited)
        assert(!environment.values.contains("secret-fixture"))
        assert(environment["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        assert(environment["USER"] == "fixture" && environment["LANG"] == "fr_FR.UTF-8")
        assert(environment["GROK_DISABLE_API_KEY_AUTH"] == "1")
        for product in ["CURSOR", "CLAUDE"] {
            for feature in ["SKILLS", "RULES", "AGENTS", "MCPS", "HOOKS"] {
                assert(environment["GROK_\(product)_\(feature)_ENABLED"] == "false")
            }
        }
        assert(GrokBuild.executableCandidates.count == 4 && GrokBuild.executableCandidates[0].hasSuffix("/.grok/bin/grok"))

        let inspectionDirectory = URL(fileURLWithPath: "/fixture/grok-home")
        let validInspection = inspection(inspectionDirectory)
        _ = try GrokBuild.parseInspection(JSONSerialization.data(withJSONObject: validInspection), directory: inspectionDirectory)
        var badInspections: [[String: Any]] = []
        for (key, value) in [("loginPolicy", ["disableApiKeyAuth": false] as Any),
                             ("hooks", [["command": "unwanted"]]), ("mcpServers", [["name": "unwanted"]]),
                             ("projectInstructions", [["path": "/outside/AGENTS.md"]]),
                             ("agents", [["source": ["type": "plugin"]]]),
                             ("permissions", ["managedSettingsActive": true]),
                             ("externalCompat", ["remoteSettingsLoaded": true, "cells": []])] {
            var bad = validInspection; bad[key] = value; badInspections.append(bad)
        }
        var outside = validInspection
        outside["configSources"] = ["layers": [["role": "user", "path": "/outside/config.toml"]]]
        badInspections.append(outside)
        for bad in badInspections {
            fails { _ = try GrokBuild.parseInspection(JSONSerialization.data(withJSONObject: bad), directory: inspectionDirectory) }
        }
        for invalid in ["not JSON", "[]", "{}"] {
            fails { _ = try GrokBuild.parseInspection(data(invalid), directory: inspectionDirectory) }
        }

        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try fakeExecutable(in: folder)
        let prompt = "--model fake; `touch /tmp/injection` $(echo secret)\nUne question française."
        try prepare(folder, result: success)
        let reply = try await GrokBuild.ask(prompt, executable: executable)
        assert(reply == "Bonjour.")
        let arguments = try Data(contentsOf: folder.appendingPathComponent("arguments"))
            .split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        let filePrompt = try? contents(folder, "prompt")
        let stdinPrompt = try contents(folder, "input")
        assert(filePrompt == prompt && stdinPrompt.isEmpty && !arguments.contains(prompt))
        assert(!arguments.contains("--always-approve") && !arguments.contains("--yolo"))
        for flag in ["--verbatim", "--no-plan", "--no-subagents", "--disable-web-search"] { assert(arguments.contains(flag)) }
        for (flag, value) in [("--tools", "read_file"), ("--permission-mode", "dontAsk"),
                              ("--sandbox", "strict"), ("--output-format", "json"), ("--model", "grok-4.7"),
                              ("--reasoning-effort", "low")] {
            let index = arguments.firstIndex(of: flag)!
            assert(arguments[index + 1] == value)
        }
        let denied = Set(arguments[arguments.firstIndex(of: "--disallowed-tools")! + 1].split(separator: ",").map(String.init))
        assert(denied.isSuperset(of: ["read_file", "search_tool", "use_tool", "Agent"]))
        let directory = try contents(folder, "directory").trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!FileManager.default.fileExists(atPath: directory))
        let childEnvironment = try contents(folder, "environment")
        assert(!childEnvironment.contains("XAI_API_KEY=") && !childEnvironment.contains("GROK_AUTH="))
        assert(childEnvironment.contains("GROK_DISABLE_API_KEY_AUTH=1"))
        assert(childEnvironment.contains("GROK_AUTH_PATH=" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json").path))
        let home = String(childEnvironment.split(separator: "\n").first { $0.hasPrefix("GROK_HOME=") }!.dropFirst("GROK_HOME=".count))
        assert(!FileManager.default.fileExists(atPath: home))
        for file in ["config.toml", "requirements.toml"] {
            let config = try contents(folder, file)
            assert(config.range(of: #"(?m)^\s*disable_api_key_auth\s*=\s*true\s*$"#, options: .regularExpression) != nil)
            assert(config.range(of: #"(?m)^\s*default_reasoning_effort\s*=\s*"low"\s*$"#, options: .regularExpression) != nil)
            assert(config.contains("grok-4.7") && config.contains("allowed_models"))
        }

        for (result, code) in [(data(#"{"type":"error","message":"Authentication required; run grok login"}"#), Int32(1)),
                               (data(#"{"type":"error","message":"Quota atteint"}"#), 2),
                               (success, 3), (data("invalid JSON"), 0), (data(#"{"text":" ","stopReason":"end_turn"}"#), 0)] {
            try prepare(folder, result: result, exitCode: code)
            do { _ = try await GrokBuild.ask(prompt, executable: executable); assertionFailure("Cet appel doit échouer.") }
            catch { assert(error is GrokBuild.Failure) }
            let calls = try contents(folder, "calls")
            assert(calls == "1", "Un échec ne doit pas déclencher de repli ou nouvelle inférence.")
            let path = try contents(folder, "directory").trimmingCharacters(in: .whitespacesAndNewlines)
            assert(!FileManager.default.fileExists(atPath: path))
        }
        try prepare(folder, result: Data(), exitCode: 2, stderr: "error: unexpected argument '--reasoning-effort' found")
        do { _ = try await GrokBuild.ask(prompt, executable: executable); assertionFailure() }
        catch { assert(error.localizedDescription.contains("unexpected argument '--reasoning-effort'")) }
        let calls = try contents(folder, "calls")
        let refusedEnvironment = try contents(folder, "environment")
        assert(calls == "1" && refusedEnvironment.contains("GROK_DISABLE_API_KEY_AUTH=1"),
               "Une option inconnue doit échouer sans repli API ou nouvelle inférence.")
        try prepare(folder, result: success)
        try data(#"{"loginPolicy":{"disableApiKeyAuth":false}}"#).write(to: folder.appendingPathComponent("inspection.json"))
        do { _ = try await GrokBuild.ask(prompt, executable: executable); assertionFailure() }
        catch { assert(error is GrokBuild.Failure) }
        assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("arguments").path))
        let inspectedDirectory = try contents(folder, "inspect-directory").trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!FileManager.default.fileExists(atPath: inspectedDirectory))
        try prepare(folder, result: success)
        do { _ = try await GrokBuild.ask(" \n", executable: executable); assertionFailure() }
        catch { assert(error is GrokBuild.Failure) }
        do { _ = try await GrokBuild.ask("Lis @/etc/passwd", executable: executable); assertionFailure() }
        catch { assert(error is GrokBuild.Failure) }
        do { _ = try await GrokBuild.ask(String(repeating: "x", count: 128 * 1024 + 1), executable: executable); assertionFailure() }
        catch { assert(error is GrokBuild.Failure) }
        assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("inspect-arguments").path))
        print("Tests Grok Build : OK (JSON, erreurs, isolation, texte littéral, faux CLI, nettoyage). Aucun appel réseau, compte ou Trousseau.")
    }
}
