import Foundation
import Speech
import Darwin

enum Bridge {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct ProcessFailure: LocalizedError {
        let stdout: Data
        let stderr: String
        let exitCode: Int32
        let executable: String
        var errorDescription: String? {
            "\(URL(fileURLWithPath: executable).lastPathComponent) : \(stderr.isEmpty ? "échec (code \(exitCode))" : String(stderr.suffix(2500)))"
        }
    }

    static let codex = "/opt/homebrew/bin/codex"
    static let loginArguments = ["-c", "cli_auth_credentials_store=\"file\"", "login", "status"]
    static let codexModel = "gpt-6-luna"
    static let codexReasoningEffort = "low"
    // Codex's model catalog advertises low as Luna's minimum; Fast uses extra subscription quota.
    // https://learn.chatgpt.com/docs/models — https://learn.chatgpt.com/docs/agent-configuration/speed
    static let codexArguments = [
        "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--model", codexModel,
        "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
        "-c", "model_reasoning_effort=\"\(codexReasoningEffort)\"", "-c", "model_verbosity=\"low\"",
        "-c", "model_reasoning_summary=\"none\"", "-c", "service_tier=\"default\"", "-c", "features.fast_mode=false",
        "-c", "approval_policy=\"never\"", "-c", "features.shell_tool=false",
        "-c", "cli_auth_credentials_store=\"file\"",
        "-c", "features.apps=false", "-c", "features.multi_agent=false",
        "-c", "features.apply_patch_freeform=false",
        "-c", "features.hooks=false", "-c", "web_search=\"disabled\"", "-"
    ]

    static func sshArguments(_ action: String) throws -> [String] {
        try AppConfiguration.load().ssh.arguments(for: action)
    }

    static func sshEnvironment() throws -> [String: String] {
        try AppConfiguration.load().ssh.environment()
    }

    static func diagnostic() async throws -> String {
        let data = try await run("/usr/bin/ssh", sshArguments("diagnostic"))
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let provider = AppConfiguration.load().provider
        let status: String
        if provider == .chatgpt {
            let login = try await run(codex, loginArguments)
            status = "Codex : " + String(decoding: login, as: UTF8.self)
        } else if provider == .claudeCode {
            status = try await ClaudeCode.diagnostic()
        } else if provider == .grokBuild {
            status = try await GrokBuild.diagnostic()
        } else {
            status = "\(provider.title) : aucun appel API effectué par ce diagnostic."
        }
        return "Diagnostic SSH du Nabaztag.\n\(status)\n\(String(decoding: pretty, as: UTF8.self))"
    }

    static func ask(_ prompt: String) async throws -> String {
        let configuration = AppConfiguration.load()
        if configuration.provider == .claudeCode {
            return try await ClaudeCode.ask(prompt)
        }
        if configuration.provider == .grokBuild {
            return try await GrokBuild.ask(prompt)
        }
        if configuration.provider.usesAPI {
            let options = configuration.options(for: configuration.provider)
            let account = configuration.apiSecretAccount(for: configuration.provider)
            let apiKey = try await Task.detached { try KeychainSecrets.read(account) ?? "" }.value
            return try await RemoteAI.ask(prompt, provider: configuration.provider, model: options.model,
                                          apiKey: apiKey, baseURL: options.baseURL)
        }
        return try await askCodex(prompt)
    }

    static func askCodex(_ prompt: String, executable: String = codex) async throws -> String {
        try Task.checkCancellation()
        let login = try await run(executable, loginArguments)
        guard String(decoding: login, as: UTF8.self).contains("Logged in using ChatGPT") else {
            throw Failure(message: "Codex doit être connecté avec ChatGPT : lance codex login dans Terminal. Une clé API n’est pas utilisée par ce prototype.")
        }
        try Task.checkCancellation()
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try await run(executable, codexArguments, input: Data(prompt.utf8), timeout: 180, directory: folder)
        let answer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure(message: "Codex a renvoyé une réponse vide.") }
        return answer
    }

    static func speak(_ text: String) async throws {
        try Task.checkCancellation()
        let configuration = AppConfiguration.load()
        if configuration.selectedVoiceEngine == .kokoro {
            let playback = StreamPlayback(configuration: configuration)
            defer { playback.cancel() }
            try await withTaskCancellationHandler(operation: {
                try await LocalVoice.stream(text) { try playback.write($0) }
                try Task.checkCancellation()
                try await playback.finish()
            }, onCancel: { playback.cancel() })
            return
        }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let aiff = folder.appendingPathComponent("reply.aiff")
        let wav = folder.appendingPathComponent("reply.wav")
        _ = try await run("/usr/bin/say", ["-v", "Thomas", "-o", aiff.path, "-f", "-"], input: Data(text.utf8))
        _ = try await run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@22050", "-c", "1", aiff.path, wav.path])
        _ = try await run("/usr/bin/ssh", sshArguments(configuration.playbackAction), input: Data(contentsOf: wav), timeout: 110)
    }

    static func record(seconds: Int) async throws -> Data {
        guard (1...15).contains(seconds) else { throw Failure(message: "Durée hors limites (1 à 15 secondes).") }
        return try await run("/usr/bin/ssh", sshArguments("record \(seconds)"), timeout: Double(seconds + 25))
    }

    static func listen(seconds: Int) async throws -> String {
        // Ask before capture so a denied permission does not record anything.
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard permission == .authorized else {
            throw Failure(message: "Autorise Nabaztag IA dans Réglages Système → Confidentialité et sécurité → Reconnaissance vocale. La saisie texte reste disponible.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR")),
              recognizer.supportsOnDeviceRecognition else {
            throw Failure(message: "La reconnaissance française sur cet appareil n’est pas disponible. Active ou télécharge la dictée française dans les réglages macOS, puis réessaie. La saisie texte reste disponible.")
        }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("micro.wav")
        try await record(seconds: seconds).write(to: audio)
        return try await transcribe(audio, recognizer: recognizer)
    }

    static func transcribe(_ audio: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.finish(text.isEmpty ? .failure(Failure(message: "Aucune parole reconnue. Rapproche-toi du lapin et réessaie.")) : .success(text))
                } else if let error {
                    state.finish(.failure(Failure(message: "Transcription impossible : \(error.localizedDescription). Réessaie après le bip, en parlant près du lapin.")))
                }
            }
            state.attach(task)
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                state.finish(.failure(Failure(message: "La transcription a dépassé 30 secondes.")))
            }
        }
    }

    final class RecognitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var task: SFSpeechRecognitionTask?
        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            let finished = continuation == nil
            if !finished { self.task = task }
            lock.unlock()
            if finished { task.cancel() }
        }
        func finish(_ result: Result<String, Error>) {
            lock.lock()
            let pending = continuation
            let task = self.task
            continuation = nil
            self.task = nil
            lock.unlock()
            guard let pending else { return }
            task?.cancel()
            pending.resume(with: result)
        }
    }

    static func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NabaztagIA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func run(_ executable: String, _ arguments: [String], input: Data = Data(),
                    timeout: Double = 45, directory: URL? = nil, environment: [String: String]? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try runSync(executable, arguments, input: input, timeout: timeout, directory: directory, environment: environment)
        }.value
    }

    private static func runSync(_ executable: String, _ arguments: [String], input: Data,
                                timeout: Double, directory: URL?, environment: [String: String]?) throws -> Data {
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let stdin = folder.appendingPathComponent("stdin")
            let stdout = folder.appendingPathComponent("stdout")
            let stderr = folder.appendingPathComponent("stderr")
            try input.write(to: stdin)
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            FileManager.default.createFile(atPath: stderr.path, contents: nil)
            let handles = try [FileHandle(forReadingFrom: stdin), FileHandle(forWritingTo: stdout), FileHandle(forWritingTo: stderr)]
            defer { handles.forEach { try? $0.close() } }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = handles[0]
            process.standardOutput = handles[1]
            process.standardError = handles[2]
            process.currentDirectoryURL = directory ?? folder
            var environment = try environment ?? (executable == "/usr/bin/ssh" ? sshEnvironment() : ProcessInfo.processInfo.environment)
            // Use the existing ChatGPT login; never silently charge an API key.
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_API_KEY")
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            guard ended.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                if ended.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                throw Failure(message: "Délai dépassé pour \(URL(fileURLWithPath: executable).lastPathComponent).")
            }
            let output = try Data(contentsOf: stdout)
            let errors = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw ProcessFailure(stdout: output, stderr: errors, exitCode: process.terminationStatus, executable: executable)
            }
            // `codex login status` writes its status to stderr.
            return output.isEmpty && Array(arguments.suffix(2)) == ["login", "status"] ? Data(errors.utf8) : output
    }
}
