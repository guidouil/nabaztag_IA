import Foundation
import Darwin

enum LocalVoice {
    static let sampleRate = 24_000
    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NabaztagIA/Voice", isDirectory: true)
    private static let python = folder.appendingPathComponent("venv/bin/python")
    private static let model = folder.appendingPathComponent("model", isDirectory: true)
    private static var helper: URL? { Bundle.main.url(forResource: "local_voice", withExtension: "py") }
    private static let worker = LocalVoiceWorker(executable: python.path,
        arguments: [helper?.path ?? "", "--worker", "--model", model.path])

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) &&
        ["config.json", "kokoro-v1_0.safetensors", "voices/ff_siwis.safetensors"].allSatisfy {
            FileManager.default.fileExists(atPath: model.appendingPathComponent($0).path)
        } && helper != nil
    }

    static func prewarm() {
        if isInstalled { worker.prewarm() }
    }

    static func shutdown() { worker.shutdown() }

    static func stream(_ text: String, onChunk: @escaping @Sendable (Data) throws -> Void) async throws {
        guard isInstalled else { throw missingInstallation }
        try await worker.stream(text, onChunk: onChunk)
    }

    // Compatibility for callers that still need one complete WAV file.
    static func synthesize(_ text: String, to output: URL) async throws {
        guard isInstalled, let helper else { throw missingInstallation }
        _ = try await Bridge.run(python.path, [helper.path, "--model", model.path, "--output", output.path],
                                 input: Data(text.utf8), timeout: 120)
    }

    private static var missingInstallation: LocalVoiceFailure {
        LocalVoiceFailure(message: "La voix neuronale locale n'est pas installée complètement. Vérifie le modèle Kokoro, son environnement Python et le fichier local_voice.py de l'application.")
    }
}

struct LocalVoiceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The serial background queue makes the synchronous callback apply audio backpressure.
final class LocalVoiceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.gui.nabaztag-ia.voice", qos: .userInitiated)
    private let lock = NSLock()
    private var session: VoiceSession?
    private var generation = 0
    private let executable: String
    private let arguments: [String]
    private let readyTimeout: Double
    private let requestTimeout: Double

    init(executable: String, arguments: [String], readyTimeout: Double = 120, requestTimeout: Double = 120) {
        self.executable = executable
        self.arguments = arguments
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
    }

    func prewarm() {
        let token = currentGeneration()
        queue.async { [self] in
            do { _ = try connected(generation: token) }
            catch { discardCurrent(generation: token) }
        }
    }

    func stream(_ text: String, onChunk: @escaping @Sendable (Data) throws -> Void) async throws {
        let token = currentGeneration()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, text.unicodeScalars.count <= 2000, !text.contains("\0") else {
                            throw LocalVoiceFailure(message: "Le texte à prononcer doit contenir entre 1 et 2 000 caractères, sans caractère nul.")
                        }
                        let child = try connected(generation: token)
                        let id = UUID().uuidString
                        var request = try JSONSerialization.data(withJSONObject: ["id": id, "text": text])
                        request.append(10)
                        guard request.count <= 16_384 else { throw LocalVoiceFailure(message: "La demande vocale est trop volumineuse.") }
                        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
                        try child.write(request, deadline: deadline)
                        var total = 0
                        while true {
                            let event = try child.readEvent(deadline: deadline)
                            guard event["id"] as? String == id, let type = event["type"] as? String else {
                                throw LocalVoiceFailure(message: "Réponse invalide du moteur vocal local.")
                            }
                            if type == "done" {
                                guard total > 0 else { throw LocalVoiceFailure(message: "La voix locale n'a produit aucun audio.") }
                                break
                            }
                            if type == "error" {
                                let message = (event["message"] as? String).map { String($0.prefix(2048)) } ?? "Erreur inconnue."
                                throw LocalVoiceFailure(message: "Voix locale : " + message)
                            }
                            guard type == "chunk", event["sample_rate"] as? Int == LocalVoice.sampleRate,
                                  let encoded = event["pcm"] as? String,
                                  let pcm = Data(base64Encoded: encoded), !pcm.isEmpty, pcm.count.isMultiple(of: 2),
                                  pcm.count <= 4_320_000 - total else {
                                throw LocalVoiceFailure(message: "Segment vocal invalide ou réponse supérieure à 90 secondes.")
                            }
                            total += pcm.count
                            try child.checkRunning()
                            try onChunk(pcm)
                        }
                        continuation.resume()
                    } catch {
                        discardCurrent(generation: token)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [self] in shutdown() })
    }

    /// Does not wait behind synthesis, which may be blocked by the audio callback.
    func shutdown() {
        lock.lock()
        generation += 1
        let child = session
        session = nil
        lock.unlock()
        child?.stop()
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func connected(generation token: Int) throws -> VoiceSession {
        lock.lock()
        guard token == generation else {
            lock.unlock()
            throw CancellationError()
        }
        if let session, session.isAlive {
            lock.unlock()
            return session
        }
        let previous = session
        let child = VoiceSession(executable: executable, arguments: arguments)
        session = child
        lock.unlock()
        previous?.stop()
        try child.start()
        let event = try child.readEvent(deadline: ProcessInfo.processInfo.systemUptime + readyTimeout)
        guard event["type"] as? String == "ready" else {
            throw LocalVoiceFailure(message: "Le moteur vocal local n'a pas confirmé son démarrage.")
        }
        return child
    }

    private func discardCurrent(generation token: Int) {
        lock.lock()
        let child = token == generation ? session : nil
        if token == generation { session = nil }
        lock.unlock()
        child?.stop()
    }

    deinit { session?.stop() }
}

private final class VoiceSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var launched = false
    private var buffered = Data()
    private var diagnostics = Data()
    private var errorsClosed = false
    private static let maximumLine = 6 * 1024 * 1024

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        for handle in [input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading] {
            let descriptor = handle.fileDescriptor
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
                throw LocalVoiceFailure(message: "Impossible de préparer les échanges avec le moteur vocal.")
            }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw LocalVoiceFailure(message: "Impossible de sécuriser l'entrée du moteur vocal.")
        }
        try process.run()
        launched = true
    }

    func checkRunning() throws {
        lock.lock()
        let wasStopped = stopped
        lock.unlock()
        if wasStopped { throw CancellationError() }
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && launched && process.isRunning
    }

    func write(_ data: Data, deadline: Double) throws {
        var offset = 0
        while offset < data.count {
            try checkDeadline(deadline)
            lock.lock()
            guard !stopped else { lock.unlock(); throw CancellationError() }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            let code = errno
            lock.unlock()
            if count > 0 { offset += count; continue }
            if count < 0 && code == EINTR { continue }
            guard count < 0 && (code == EAGAIN || code == EWOULDBLOCK) else {
                throw failure("Connexion au moteur vocal interrompue.")
            }
            try pollOutput(deadline: deadline, writing: true)
        }
    }

    func readEvent(deadline: Double) throws -> [String: Any] {
        while true {
            try checkDeadline(deadline)
            if let newline = buffered.firstIndex(of: 10) {
                let count = buffered.distance(from: buffered.startIndex, to: newline)
                guard count <= Self.maximumLine else { throw failure("Réponse vocale trop volumineuse.") }
                let line = Data(buffered.prefix(count))
                buffered.removeFirst(count + 1)
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw failure("Réponse illisible du moteur vocal local.")
                }
                return event
            }
            guard buffered.count <= Self.maximumLine else { throw failure("Réponse vocale trop volumineuse.") }
            try pollOutput(deadline: deadline)
        }
    }

    private func pollOutput(deadline: Double, writing: Bool = false) throws {
        try checkDeadline(deadline)
        var descriptors = [pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: errorsClosed ? -1 : errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
        if writing { descriptors.append(pollfd(fd: input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0)) }
        let remaining = max(1, min(100, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
        let count = poll(&descriptors, nfds_t(descriptors.count), Int32(remaining))
        if count < 0 {
            if errno == EINTR { return }
            throw failure("Lecture du moteur vocal impossible.")
        }
        for index in [1, 0] where descriptors[index].revents != 0 {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let read = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
            if read > 0 {
                if index == 0 { buffered.append(contentsOf: bytes.prefix(read)) }
                else { diagnostics.append(contentsOf: bytes.prefix(read)); diagnostics = Data(diagnostics.suffix(4096)) }
            } else if read == 0 && index == 0 {
                throw failure("Le moteur vocal local s'est arrêté.")
            } else if read == 0 && index == 1 {
                errorsClosed = true
            } else if read < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw failure("Lecture du moteur vocal impossible.")
            }
        }
    }

    private func checkDeadline(_ deadline: Double) throws {
        try checkRunning()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw failure("Délai dépassé pour la voix locale.")
        }
    }

    private func failure(_ message: String) -> LocalVoiceFailure {
        let detail = String(decoding: diagnostics.suffix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalVoiceFailure(message: message + (detail.isEmpty ? "" : " " + detail))
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        try? input.fileHandleForWriting.close()
        let child = launched ? process : nil
        lock.unlock()
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    deinit {
        stop()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}
