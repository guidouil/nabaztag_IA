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
        "-c", "features.hooks=false", "-c", "web_search=\"live\"", "-"
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

    enum HealthStatus { case healthy, warning, failed }

    struct HealthCheck: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let status: HealthStatus
        let detail: String
    }

    struct HealthReport {
        let checks: [HealthCheck]
        let diagnostic: String
        let checkedAt: Date

        var status: HealthStatus {
            if checks.contains(where: { $0.status == .failed }) { return .failed }
            return checks.contains(where: { $0.status == .warning }) ? .warning : .healthy
        }
    }

    static func healthCheck() async -> HealthReport {
        let configuration = AppConfiguration.load()
        async let remote = remoteHealth(configuration)
        async let provider = providerHealth(configuration)
        async let voice = voiceHealth(configuration)
        let (remoteResult, providerResult, voiceResult) = await (remote, provider, voice)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let supportsSpeech = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))?.supportsOnDeviceRecognition == true
        let speech = HealthCheck(id: "speech", title: "Transcription", systemImage: "mic",
            status: !supportsSpeech || speechStatus == .denied || speechStatus == .restricted ? .failed : speechStatus == .authorized ? .healthy : .warning,
            detail: !supportsSpeech ? "Reconnaissance française locale indisponible sur ce Mac."
                : speechStatus == .authorized ? "Reconnaissance française locale disponible et autorisée."
                : speechStatus == .notDetermined ? "Autorisation demandée au premier enregistrement."
                : "Reconnaissance vocale refusée dans les réglages de confidentialité macOS.")
        let checks = remoteResult.checks + [providerResult, voiceResult, speech]
        let details = checks.map { "\($0.title) : \($0.detail)" }.joined(separator: "\n\n")
        return HealthReport(checks: checks, diagnostic: details + "\n\n" + remoteResult.diagnostic, checkedAt: Date())
    }

    private static func remoteHealth(_ configuration: AppConfiguration) async -> (checks: [HealthCheck], diagnostic: String) {
        do {
            let data = try await run("/usr/bin/ssh", configuration.ssh.arguments(for: "diagnostic"),
                                     timeout: 15, environment: configuration.ssh.environment())
            let checks = try remoteHealthChecks(data)
            let object = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return (checks, String(decoding: pretty, as: UTF8.self))
        } catch {
            return ([HealthCheck(id: "rabbit", title: "Lapin", systemImage: "antenna.radiowaves.left.and.right", status: .failed,
                                 detail: "Connexion ou diagnostic impossible : \(error.localizedDescription)"),
                     HealthCheck(id: "services", title: "Services", systemImage: "gearshape.2", status: .warning,
                                 detail: "Non vérifiés : diagnostic du lapin indisponible."),
                     HealthCheck(id: "audio", title: "Audio du lapin", systemImage: "hifispeaker", status: .warning,
                                 detail: "Non vérifié : diagnostic du lapin indisponible.")], "")
        }
    }

    static func remoteHealthChecks(_ data: Data) throws -> [HealthCheck] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["bridge_version"] as? Int == 1, let commands = object["commands"] as? [String: [String: Any]] else {
            throw Failure(message: "Format du diagnostic du lapin invalide ou incompatible.")
        }
        func output(_ command: String) -> String { commands[command]?["stdout"] as? String ?? "" }
        func succeeded(_ command: String) -> Bool { commands[command]?["returncode"] as? Int == 0 }
        let activeCommand = "systemctl is-active nabd.service nabweb.service nginx.service"
        let failedCommand = "systemctl --failed --no-pager --no-legend"
        let states = output(activeCommand).split(whereSeparator: \.isNewline).map(String.init)
        let gestalt = object["gestalt"] as? [String: Any]
        let servicesReady = succeeded(activeCommand) && states == ["active", "active", "active"] &&
            gestalt?["type"] as? String == "response" && gestalt?["state"] as? String != nil
        let clean = succeeded(failedCommand) && output(failedCommand).isEmpty
        let serviceDetail = !servicesReady ? "Services ou réponse Pynab indisponibles. \(output(activeCommand)) \(object["gestalt_error"] as? String ?? "")"
            : !clean ? "Pynab répond, mais des unités système sont en échec ou leur état est inconnu. \(output(failedCommand))"
            : "nabd, nabweb et nginx actifs ; Pynab répond ; aucune unité système en échec."
        let hardware = gestalt?["hardware"] as? [String: Any]
        let card = hardware?["sound_card"] as? String ?? ""
        let audioReady = !card.isEmpty && hardware?["sound_input"] as? Bool == true &&
            ["aplay -l", "arecord -l"].allSatisfy { succeeded($0) && output($0).contains(card) }
        return [HealthCheck(id: "rabbit", title: "Lapin", systemImage: "antenna.radiowaves.left.and.right", status: .healthy,
                            detail: "Connexion SSH et relais de diagnostic accessibles."),
                HealthCheck(id: "services", title: "Services", systemImage: "gearshape.2", status: servicesReady ? clean ? .healthy : .warning : .failed,
                            detail: serviceDetail.trimmingCharacters(in: .whitespacesAndNewlines)),
                HealthCheck(id: "audio", title: "Audio du lapin", systemImage: "hifispeaker", status: audioReady ? .healthy : .failed,
                            detail: audioReady ? "Carte \(card) détectée en entrée et en sortie. Qualité sonore non testée."
                                : "Microphone ou carte de lecture non détectés par ALSA et Pynab.")]
    }

    static func providerHealth(_ configuration: AppConfiguration) async -> HealthCheck {
        let provider = configuration.provider
        do {
            let detail: String
            let status: HealthStatus
            switch provider {
            case .chatgpt:
                let login = try await run(codex, loginArguments, timeout: 15)
                guard String(decoding: login, as: UTF8.self).contains("Logged in using ChatGPT") else {
                    throw Failure(message: "Connecte Codex avec ChatGPT via codex login dans Terminal.")
                }
                status = .healthy
                detail = "Codex connecté avec ChatGPT. Disponibilité du modèle et quotas non testés."
            case .claudeCode:
                guard let executable = ClaudeCode.executable else { throw Failure(message: "Claude Code n’est pas installé.") }
                let folder = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: folder) }
                let auth = try await ClaudeCode.authentication(executable: executable, directory: folder, environment: ClaudeCode.environment())
                try ClaudeCode.requireSubscription(auth)
                status = .healthy
                detail = "Claude Code connecté avec claude.ai. Disponibilité du modèle et quotas non testés."
            case .grokBuild:
                guard GrokBuild.executable != nil else { throw Failure(message: "Grok Build n’est pas installé.") }
                detail = try await GrokBuild.diagnostic()
                status = .warning
            default:
                let options = configuration.options(for: provider)
                _ = try RemoteAI.makeRequest("Vérification", provider: provider, model: options.model,
                                             apiKey: "validation-only", baseURL: options.baseURL)
                status = .warning
                detail = "\(provider.title) : URL et modèle valides. Clé non consultée ; connexion et quotas non testés."
            }
            return HealthCheck(id: "provider", title: "Assistant IA", systemImage: "sparkles", status: status, detail: detail)
        } catch {
            return HealthCheck(id: "provider", title: "Assistant IA", systemImage: "sparkles", status: .failed, detail: error.localizedDescription)
        }
    }

    private static func voiceHealth(_ configuration: AppConfiguration) async -> HealthCheck {
        let status: HealthStatus
        let detail: String
        if configuration.selectedVoiceEngine == .kokoro {
            status = LocalVoice.isInstalled ? .healthy : .failed
            detail = LocalVoice.isInstalled ? "Installation Kokoro et voix Siwis présentes. Synthèse non testée."
                : "Installation Kokoro incomplète. Lance setup-voice.command."
        } else {
            do {
                let voices = try await run("/usr/bin/say", ["-v", "?"], timeout: 10)
                let installed = String(decoding: voices, as: UTF8.self).split(whereSeparator: \.isNewline)
                    .contains { $0.split(whereSeparator: \.isWhitespace).first == "Thomas" }
                status = installed ? .healthy : .failed
                detail = installed ? "Voix Thomas disponible sur macOS. Synthèse non testée."
                    : "Voix Thomas absente. Installe-la dans les réglages vocaux macOS."
            } catch {
                status = .failed
                detail = "Voix macOS non vérifiable : \(error.localizedDescription)"
            }
        }
        return HealthCheck(id: "voice", title: "Voix locale", systemImage: "waveform", status: status, detail: detail)
    }

    static func ask(_ prompt: String) async throws -> String {
        let answer = try await askProvider(prompt)
        do {
            switch try serviceQuery(answer) {
            case .weather(let query): return try await WeatherService.answer(query)
            case .news(let query): return try await NewsService.answer(query)
            case nil: return answer
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as WeatherService.Failure {
            return failure.message
        } catch let failure as NewsService.Failure {
            return failure.message
        } catch {
            return "Je n’ai pas pu consulter le service demandé. Peux-tu reformuler ou réessayer dans un instant ?"
        }
    }

    enum ServiceQuery {
        case weather(WeatherService.Query)
        case news(NewsService.Query)
    }

    static func serviceQuery(_ answer: String) throws -> ServiceQuery? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json\n"), text.hasSuffix("```") {
            text = String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("```\n"), text.hasSuffix("```") {
            text = String(text.dropFirst(4).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let data = Data(text.utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if text.contains("\"tool\""),
               text.localizedCaseInsensitiveContains("weather") || text.localizedCaseInsensitiveContains("news") {
                throw Failure(message: "Demande de service invalide.")
            }
            return nil
        }
        guard let tool = object["tool"] else { return nil }
        switch tool as? String {
        case "weather": return .weather(try JSONDecoder().decode(WeatherService.Query.self, from: data))
        case "news": return .news(try JSONDecoder().decode(NewsService.Query.self, from: data))
        default: throw Failure(message: "Demande de service invalide.")
        }
    }

    private static func askProvider(_ prompt: String) async throws -> String {
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

    static func spokenAnswer(_ answer: String) -> String {
        // shortcut: inline links support one level of URL parentheses; use a Markdown parser for richer formatting.
        answer
            .replacingOccurrences(of: #"(?ims)^[ \t]*Sources[ \t]*:.*\z"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"cite[^]*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\[([^\]\n]*)\]\(https?://(?:[^\s()]|\([^\s()]*\))+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<?\bhttps?://(?:[^\s<>()]|\([^\s<>()]*\))+(?<![.,;:!?])>?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func listen(session: RemoteSession, onRecorded: @MainActor () -> Void) async throws -> String {
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
        let data = try await withTaskCancellationHandler(operation: {
            try await session.start("record-until-stop")
            return try await session.result(timeout: 150)
        }, onCancel: { session.cancel() })
        try data.write(to: audio)
        await onRecorded()
        return try await transcribe(audio, recognizer: recognizer)
    }

    static func askWhileThinking(_ prompt: String, direction: String) async throws -> String {
        let session = RemoteSession()
        defer { session.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await session.start("think \(direction)", waitForReady: true)
            let answer: String
            do { answer = try await ask(prompt) }
            catch {
                session.stop()
                _ = try? await session.result(timeout: 25)
                throw error
            }
            session.stop()
            _ = try await session.result(timeout: 25)
            try Task.checkCancellation()
            return answer
        }, onCancel: { session.cancel() })
    }

    final class RemoteSession: @unchecked Sendable {
        private let configuration: AppConfiguration
        private let executable: String
        private let readyTimeout: Double
        private let lock = NSLock()
        private let ended = DispatchGroup()
        private var process: Process?
        private var input: Pipe?
        private var folder: URL?
        private var output: FileHandle?
        private var errors: FileHandle?
        private var stopMessage = Data()
        private var stopped = false
        private var canceled = false

        init(configuration: AppConfiguration = .load(), executable: String = "/usr/bin/ssh", readyTimeout: Double = 15) {
            self.configuration = configuration
            self.executable = executable
            self.readyTimeout = readyTimeout
        }

        func start(_ action: String, waitForReady: Bool = false) async throws {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                try self.startSync(action)
                if waitForReady { try self.waitReady() }
            }.value
        }

        private func startSync(_ action: String) throws {
            let directory = try Bridge.temporaryDirectory()
            var retained = false
            defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
            let stdout = directory.appendingPathComponent("stdout"), stderr = directory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            FileManager.default.createFile(atPath: stderr.path, contents: nil)
            let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
            let child = Process(), stdin = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = try configuration.ssh.arguments(for: action)
            child.environment = try configuration.ssh.environment()
            child.standardInput = stdin
            child.standardOutput = output
            child.standardError = errors
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                try? FileManager.default.removeItem(at: directory)
                throw Failure(message: "Impossible de préparer la commande du lapin.")
            }
            lock.lock()
            defer { lock.unlock() }
            guard !canceled, process == nil else {
                try? FileManager.default.removeItem(at: directory)
                throw Failure(message: "Commande du lapin déjà démarrée ou interrompue.")
            }
            process = child; input = stdin; folder = directory; self.output = output; self.errors = errors
            retained = true
            stopMessage = action == "record-until-stop" ? Data("stop\n".utf8) : Data()
            ended.enter()
            let ended = ended
            child.terminationHandler = { _ in ended.leave() }
            do { try child.run() } catch { ended.leave(); throw error }
            if stopped { sendStop() }
        }

        private func waitReady() throws {
            let deadline = ProcessInfo.processInfo.systemUptime + readyTimeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                lock.lock()
                let interrupted = canceled, child = process, stdout = folder?.appendingPathComponent("stdout")
                lock.unlock()
                if interrupted { throw CancellationError() }
                if let stdout {
                    let handle = try FileHandle(forReadingFrom: stdout)
                    let data = try handle.read(upToCount: 65) ?? Data()
                    try handle.close()
                    if data.starts(with: Data("ready\n".utf8)) { return }
                    if data.contains(10) || data.count > 64 { throw Failure(message: "Signal de réflexion du lapin invalide.") }
                }
                if child?.isRunning != true {
                    throw Failure(message: "Le lapin n’a pas démarré la réflexion : \(diagnostic())")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            cancel()
            throw Failure(message: "Délai de préparation de la réflexion du lapin dépassé.")
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            sendStop()
        }

        private func sendStop() {
            guard let handle = input?.fileHandleForWriting else { return }
            if !stopMessage.isEmpty { try? handle.write(contentsOf: stopMessage) }
            try? handle.close()
        }

        func result(timeout: Double) async throws -> Data {
            try await Task.detached(priority: .userInitiated) { try self.resultSync(timeout: timeout) }.value
        }

        private func resultSync(timeout: Double) throws -> Data {
            guard ended.wait(timeout: .now() + timeout) == .success else {
                cancel()
                throw Failure(message: "Délai de commande du lapin dépassé.")
            }
            lock.lock()
            let interrupted = canceled, child = process, stdout = folder?.appendingPathComponent("stdout")
            lock.unlock()
            if interrupted { throw CancellationError() }
            guard let child, let stdout else { throw Failure(message: "Commande du lapin absente.") }
            guard child.terminationStatus == 0 else { throw Failure(message: "Commande SSH du lapin : \(diagnostic())") }
            let size = try stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1024 * 1024 else { throw Failure(message: "Réponse du lapin supérieure à 8 Mio.") }
            return try Data(contentsOf: stdout)
        }

        private func diagnostic() -> String {
            lock.lock()
            let stderr = folder?.appendingPathComponent("stderr")
            lock.unlock()
            return stderr.flatMap { try? Data(contentsOf: $0) }.map { String(decoding: $0.suffix(2500), as: UTF8.self) } ?? "Connexion fermée."
        }

        func cancel() {
            lock.lock()
            canceled = true
            try? input?.fileHandleForWriting.close()
            let child = process
            lock.unlock()
            if let child, child.isRunning {
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }

        deinit {
            cancel()
            try? output?.close()
            try? errors?.close()
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
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
