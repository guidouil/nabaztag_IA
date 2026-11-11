import Foundation
import Speech

@main
struct BridgeChecks {
    static func checkCodex() async throws {
        let arguments = Bridge.codexArguments
        assert(Bridge.codexModel == "gpt-6-luna" && Bridge.codexReasoningEffort == "low")
        assert(arguments.first == "exec" && arguments.last == "-")
        assert(arguments[arguments.firstIndex(of: "--model")! + 1] == "gpt-6-luna")
        for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"] {
            assert(arguments.contains(flag))
        }
        assert(arguments[arguments.firstIndex(of: "--sandbox")! + 1] == "read-only")
        let overrides = Set(arguments.indices.filter { arguments[$0] == "-c" }.map { arguments[$0 + 1] })
        assert(overrides.isSuperset(of: ["model_reasoning_effort=\"low\"", "model_verbosity=\"low\"",
            "model_reasoning_summary=\"none\"", "service_tier=\"default\"", "features.fast_mode=false",
            "approval_policy=\"never\"", "cli_auth_credentials_store=\"file\"", "features.shell_tool=false",
            "features.apps=false", "features.multi_agent=false", "features.apply_patch_freeform=false",
            "features.hooks=false", "web_search=\"disabled\""]))

        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        set -eu
        fixture=${0%/*}
        mode=request
        for argument in "$@"; do if [ "$argument" = login ]; then mode=login; fi; done
        printf '%s\0' "$@" > "$fixture/$mode-arguments"
        /bin/cat > "$fixture/$mode-input"
        /bin/pwd > "$fixture/$mode-directory"
        /usr/bin/env > "$fixture/$mode-environment"
        printf 1 >> "$fixture/$mode-calls"
        /bin/cat "$fixture/$mode-output"
        exit "$(/bin/cat "$fixture/$mode-code")"
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        func prepare(login: String = "Logged in using ChatGPT", answer: String = "Quarante-deux.\n", code: Int = 0) throws {
            for name in ["login-calls", "request-calls", "request-arguments", "request-directory"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            for (name, value) in ["login-output": login, "login-code": "0", "request-output": answer, "request-code": String(code)] {
                try Data(value.utf8).write(to: folder.appendingPathComponent(name))
            }
        }
        func read(_ name: String) throws -> String {
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        func checkCleanup() throws {
            let directory = try read("request-directory").trimmingCharacters(in: .whitespacesAndNewlines)
            assert(!FileManager.default.fileExists(atPath: directory))
            let calls = try read("request-calls")
            assert(calls == "1", "Aucun repli ou deuxième appel modèle ne doit être tenté.")
        }

        let prompt = "--model autre; `touch /tmp/injection` $(echo secret)\nCombien font 23 + 19 ?"
        try prepare()
        let answer = try await Bridge.askCodex(prompt, executable: executable.path)
        assert(answer == "Quarante-deux.")
        let receivedArguments = try Data(contentsOf: folder.appendingPathComponent("request-arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let receivedPrompt = try read("request-input")
        let environment = try read("request-environment")
        assert(receivedArguments == arguments && !receivedArguments.contains(prompt) && receivedPrompt == prompt)
        assert(!environment.contains("OPENAI_API_KEY=") && !environment.contains("CODEX_API_KEY="))
        try checkCleanup()
        for login in ["Not logged in", "Logged in using an API key", "unknown"] {
            try prepare(login: login)
            do { _ = try await Bridge.askCodex(prompt, executable: executable.path); assertionFailure() }
            catch { assert(error.localizedDescription.contains("ChatGPT")) }
            assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("request-arguments").path))
        }
        try prepare(answer: " \n")
        do { _ = try await Bridge.askCodex(prompt, executable: executable.path); assertionFailure() }
        catch { assert(error.localizedDescription.contains("vide")) }
        try checkCleanup()
        try prepare(answer: "fixture failure", code: 7)
        do { _ = try await Bridge.askCodex(prompt, executable: executable.path); assertionFailure() }
        catch let failure as Bridge.ProcessFailure { assert(failure.exitCode == 7) }
        try checkCleanup()
    }

    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first ?? "self-test" {
        case "diagnostic":
            print(try await Bridge.diagnostic())
        case "ask":
            print(try await Bridge.ask("Réponds en français en une phrase courte, sans outil : quel est le résultat de deux plus deux ?"))
        case "claude-status":
            print(try await ClaudeCode.diagnostic())
        case "claude":
            print(try await ClaudeCode.ask("Réponds en français en une phrase courte, sans outil : combien font trois plus quatre ?"))
        case "grok-status":
            print(try await GrokBuild.diagnostic())
        case "grok":
            print(try await GrokBuild.ask("Réponds en français en une phrase courte, sans outil : combien font trois plus quatre ?"))
        case "speaker":
            try await Bridge.speak("Bonjour. Ceci est un test du haut-parleur du Nabaztag depuis ton Mac.")
            print("Lecture terminée sans erreur ALSA.")
        case "speech-support":
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
            print("Reconnaissance locale française : \(recognizer?.supportsOnDeviceRecognition == true)")
        case "record":
            let data = try await Bridge.record(seconds: 3)
            guard data.starts(with: Data("RIFF".utf8)), data.count >= 96044 else {
                throw Bridge.Failure(message: "Capture WAV incomplète.")
            }
            print("Capture WAV : \(data.count) octets, 3 secondes.")
        default:
            try await checkCodex()
            let text = Data("Texte français — `$(echo test)`\n".utf8)
            let result = try await Bridge.run("/bin/cat", [], input: text)
            assert(result == text, "Le texte doit être transmis littéralement.")
            do {
                _ = try await Bridge.run("/bin/sleep", ["3"], timeout: 0.1)
                assertionFailure("Le délai doit être appliqué.")
            } catch { assert(error.localizedDescription.contains("Délai dépassé")) }
            do {
                _ = try await Bridge.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 10"], timeout: 0.2)
                assertionFailure("Un processus ignorant SIGTERM doit être arrêté.")
            } catch { assert(error.localizedDescription.contains("Délai dépassé")) }
            do {
                _ = try await Bridge.run("/usr/bin/false", [])
                assertionFailure("Un code non nul doit échouer.")
            } catch { assert(error.localizedDescription.contains("échec")) }
            do {
                _ = try await Bridge.run("/bin/sh", ["-c", "printf stdout-error; printf stderr-error >&2; exit 7"])
                assertionFailure("Un code non nul avec sortie doit échouer.")
            } catch let error as Bridge.ProcessFailure {
                assert(error.exitCode == 7)
                assert(error.stdout == Data("stdout-error".utf8))
                assert(error.stderr == "stderr-error")
                assert(error.localizedDescription.contains("stderr-error"))
            }
            let env = try await Bridge.run("/usr/bin/env", [], environment: ["NABAZTAG_CHECK": "literal value", "OPENAI_API_KEY": "removed", "CODEX_API_KEY": "removed"])
            let environment = String(decoding: env, as: UTF8.self)
            assert(environment.contains("NABAZTAG_CHECK=literal value"))
            assert(!environment.contains("OPENAI_API_KEY=") && !environment.contains("CODEX_API_KEY="))
            let args = try Bridge.sshArguments("record 6")
            assert(args.contains("StrictHostKeyChecking=yes") && args.last?.hasSuffix(" record 6") == true)
            let completed: String = try await withCheckedThrowingContinuation { continuation in
                let state = Bridge.RecognitionState(continuation)
                DispatchQueue.concurrentPerform(iterations: 20) { value in
                    state.finish(.success(String(value)))
                }
            }
            assert((0..<20).contains(Int(completed)!))
            print("Tests Bridge : OK (Codex Luna/low/standard isolé sans API/repli, stdin littéral, délai, erreurs, SSH, fin STT unique).")
        }
    }
}
