import Foundation
import Speech

@main
struct BridgeChecks {
    static func checkServiceRouting() throws {
        func json(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let plain = try Bridge.serviceQuery("Une réponse ordinaire.")
        let ordinaryJSON = try Bridge.serviceQuery(json(["example": "JSON ordinaire"]))
        assert(plain == nil && ordinaryJSON == nil)
        let command = try json(["tool": "weather", "location": "New York", "country_code": "US", "day_offset": NSNull()])
        for text in [command, "```json\n\(command)\n```", "```\n\(command)\n```"] {
            guard case .weather(let query) = try Bridge.serviceQuery(text) else { fatalError("Routage météo absent.") }
            assert(query.location == "New York" && query.countryCode == "US" && query.dayOffset == nil)
        }
        guard case .weather(let tomorrow) = try Bridge.serviceQuery(json(["tool": "weather", "location": "Tokyo", "day_offset": 1])) else {
            fatalError("Routage météo absent.")
        }
        assert(tomorrow.location == "Tokyo" && tomorrow.dayOffset == 1)
        for category in NewsService.Category.allCases {
            let news = try json(["tool": "news", "category": category.rawValue])
            for text in [news, "```json\n\(news)\n```", "```\n\(news)\n```"] {
                guard case .news(let query) = try Bridge.serviceQuery(text) else { fatalError("Routage actualités absent.") }
                assert(query.category == category)
            }
        }
        for text in [String(command.dropLast()), try json(["tool": "weather"]),
                     "Voici la demande : \(command)", "```JSON\n\(command)\n```", "```json\n\(command)",
                     try json(["tool": "Weather", "location": "Paris"]), try json(["tool": 7]),
                     try json(["tool": "weather", "location": "Paris", "day_offset": "tomorrow"]),
                     #"{"tool":"news","category":"france""#,
                     try json(["tool": "news"]), try json(["tool": "news", "category": "politics"]),
                     try json(["tool": "news", "category": NSNull()]),
                     try json(["tool": "news", "category": ["france", "international"]]),
                     try json(["tool": "News", "category": "all"]),
                     #"Voici la demande : {"tool":"news","category":"all"}"#] {
            do { _ = try Bridge.serviceQuery(text); assertionFailure("Une commande de service invalide ne doit pas être lue à voix haute.") }
            catch {}
        }
    }

    static func checkRemoteSessions() async throws {
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fake-ssh")
        let script = #"""
        #!/bin/sh
        set -eu
        fixture=${0%/*}
        printf '%s\0' "$@" > "$fixture/arguments"
        printf '%s' "$$" > "$fixture/pid"
        mode=$(/bin/cat "$fixture/mode")
        case "$mode" in
          record)
            IFS= read -r command
            test "$command" = stop
            printf 'RIFF-recorded-until-stop'
            ;;
          think)
            printf rea
            /bin/sleep 0.02
            printf 'dy\n'
            /bin/cat > "$fixture/input"
            /bin/sleep 0.03
            printf done > "$fixture/finished"
            ;;
          invalid) printf 'invalid\n'; exec /bin/sleep 10 ;;
          failure) printf 'fixture remote error' >&2; exit 7 ;;
          stall) trap '' TERM; exec /bin/sleep 10 ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let key = folder.appendingPathComponent("key")
        try Data("fixture".utf8).write(to: key)
        var configuration = AppConfiguration()
        configuration.ssh.host = "fixture.local"
        configuration.ssh.keyPath = key.path
        func prepare(_ mode: String) throws -> Bridge.RemoteSession {
            try Data(mode.utf8).write(to: folder.appendingPathComponent("mode"))
            return Bridge.RemoteSession(configuration: configuration, executable: executable.path, readyTimeout: 0.1)
        }
        for stopEarly in [false, true] {
            let capture = try prepare("record")
            defer { capture.cancel() }
            if stopEarly { capture.stop() }
            try await capture.start("record-until-stop")
            if !stopEarly { capture.stop() }
            capture.stop()
            let data = try await capture.result(timeout: 1)
            assert(data == Data("RIFF-recorded-until-stop".utf8))
            let arguments = try Data(contentsOf: folder.appendingPathComponent("arguments"))
                .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            let expected = try configuration.ssh.arguments(for: "record-until-stop")
            assert(arguments == expected)
        }
        for direction in ["forward", "backward"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("finished"))
            let thinking = try prepare("think")
            defer { thinking.cancel() }
            try await thinking.start("think \(direction)", waitForReady: true)
            assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("finished").path))
            thinking.stop()
            let ready = try await thinking.result(timeout: 1)
            assert(ready == Data("ready\n".utf8))
            assert(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finished").path))
            let input = try Data(contentsOf: folder.appendingPathComponent("input"))
            assert(input.isEmpty)
        }
        let invalid = try prepare("invalid")
        do { try await invalid.start("think forward", waitForReady: true); assertionFailure("Un ACK invalide doit échouer.") }
        catch { assert(error.localizedDescription.contains("invalide")) }
        invalid.cancel()
        let failed = try prepare("failure")
        try await failed.start("record-until-stop")
        do { _ = try await failed.result(timeout: 1); assertionFailure("Une erreur SSH doit être propagée.") }
        catch { assert(error.localizedDescription.contains("fixture remote error")) }
        failed.cancel()
        let canceled = try prepare("record")
        canceled.cancel()
        do { try await canceled.start("record-until-stop"); assertionFailure("Une capture annulée ne démarre pas.") }
        catch {}
        let stalled = try prepare("stall")
        try await stalled.start("record-until-stop")
        do { _ = try await stalled.result(timeout: 0.1); assertionFailure("Un blocage distant doit expirer.") }
        catch { assert(error.localizedDescription.contains("Délai")) }
    }

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
            try checkServiceRouting()
            try await checkRemoteSessions()
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
            print("Tests Bridge : OK (Codex isolé, stdin, délais, erreurs, capture arrêtée/précoce, réflexion ready/EOF dans les deux sens, SSH, fin STT unique).")
        }
    }
}
