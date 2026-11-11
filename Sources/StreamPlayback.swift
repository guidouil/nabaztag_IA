import Foundation
import Darwin

final class StreamPlayback: @unchecked Sendable {
    static let maxBytes = 90 * 24000 * 2
    private static let activeLock = NSLock()
    private static weak var active: StreamPlayback?

    private let configuration: AppConfiguration
    private let executable: String
    private let readyTimeout: Double
    private let writeTimeout: Double
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private let diagnostics = StreamDiagnostics()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var canceled = false
    private var ready = false
    private var writingFinished = false
    private var bytes = 0

    init(configuration: AppConfiguration, executable: String = "/usr/bin/ssh", readyTimeout: Double = 15, writeTimeout: Double = 120) {
        self.configuration = configuration
        self.executable = executable
        self.readyTimeout = readyTimeout
        self.writeTimeout = writeTimeout
        Self.activeLock.lock()
        Self.active = self
        Self.activeLock.unlock()
    }

    static func cancelActive() {
        activeLock.lock()
        let playback = active
        activeLock.unlock()
        playback?.cancel()
    }

    func start() async throws {
        try await Task.detached(priority: .userInitiated) { try self.startSync() }.value
    }

    private func startSync() throws {
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = try configuration.ssh.arguments(for: configuration.streamPlaybackAction)
        child.environment = try configuration.ssh.environment()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw Bridge.Failure(message: "Impossible de préparer le flux audio SSH.")
        }
        let flags = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw Bridge.Failure(message: "Impossible de préparer la contrepression audio SSH.")
        }
        let diagnostics = diagnostics
        stderr.fileHandleForReading.readabilityHandler = { handle in diagnostics.read(handle) }
        let ended = ended
        child.terminationHandler = { _ in ended.signal() }
        lock.lock()
        guard !canceled, process == nil else {
            lock.unlock()
            stderr.fileHandleForReading.readabilityHandler = nil
            throw Bridge.Failure(message: "Le flux audio est déjà démarré ou interrompu.")
        }
        process = child; input = stdin; output = stdout; errors = stderr
        do { try child.run() } catch {
            lock.unlock()
            cancel()
            throw error
        }
        lock.unlock()
        do {
            try Self.readReady(stdout.fileHandleForReading, timeout: readyTimeout)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                var buffer = [UInt8](repeating: 0, count: 4096)
                let size = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
                if size <= 0 { handle.readabilityHandler = nil }
            }
            lock.lock()
            let interrupted = canceled
            ready = !interrupted
            lock.unlock()
            if interrupted { throw Bridge.Failure(message: "Lecture audio interrompue.") }
        } catch {
            let detail = diagnostics.text
            cancel()
            throw Bridge.Failure(message: "Le lapin n’a pas démarré le flux audio : \(error.localizedDescription)" + (detail.isEmpty ? "" : " \(detail)"))
        }
    }

    private static func readReady(_ handle: FileHandle, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while Date() < deadline {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            let count = poll(&descriptor, 1, remaining)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            var buffer = [UInt8](repeating: 0, count: 64)
            let size = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else {
                throw Bridge.Failure(message: "Connexion SSH fermée avant le signal ready.")
            }
            data.append(contentsOf: buffer.prefix(size))
            if let newline = data.firstIndex(of: 10) {
                guard data[..<newline] == Data("ready".utf8) else {
                    throw Bridge.Failure(message: "Signal de lecture invalide. Mets le relais du lapin à jour.")
                }
                return
            }
            guard data.count <= 64 else { throw Bridge.Failure(message: "Signal de lecture trop long.") }
        }
        throw Bridge.Failure(message: "Délai de préparation audio dépassé.")
    }

    func write(_ pcm: Data) throws {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= Self.maxBytes else {
            throw Bridge.Failure(message: "Segment PCM invalide ou réponse audio supérieure à 90 secondes.")
        }
        lock.lock()
        let needsStart = process == nil && !canceled
        lock.unlock()
        // Reserve the rabbit only once the first synthesized phrase exists.
        if needsStart { try startSync() }
        lock.lock()
        guard ready, !canceled, !writingFinished, process?.isRunning == true, let handle = input?.fileHandleForWriting else {
            lock.unlock()
            throw Bridge.Failure(message: "Le flux audio SSH n’est pas disponible.")
        }
        guard pcm.count <= Self.maxBytes - bytes else {
            lock.unlock()
            throw Bridge.Failure(message: "Segment PCM invalide ou réponse audio supérieure à 90 secondes.")
        }
        bytes += pcm.count
        let descriptorNumber = handle.fileDescriptor
        lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + min(writeTimeout, Double(pcm.count) / 48000 + 15)
        var size = UInt32(pcm.count).bigEndian
        var packet = withUnsafeBytes(of: &size) { Data($0) }
        packet.append(pcm)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Bridge.Failure(message: "Délai d’écriture audio SSH dépassé.")
                }
                lock.lock()
                guard !canceled, !writingFinished else {
                    lock.unlock()
                    throw Bridge.Failure(message: "Lecture audio interrompue.")
                }
                let written = Darwin.write(descriptorNumber, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                let code = errno
                lock.unlock()
                if written > 0 { offset += written; continue }
                if written < 0 && code == EINTR { continue }
                guard written < 0 && (code == EAGAIN || code == EWOULDBLOCK) else {
                    throw Bridge.Failure(message: "Le flux audio SSH est fermé ou interrompu.")
                }
                var descriptor = pollfd(fd: descriptorNumber, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 50)
            }
        }
    }

    func finish() async throws {
        try await Task.detached(priority: .userInitiated) { try self.finishSync() }.value
    }

    private func finishSync() throws {
        lock.lock()
        guard ready, !canceled, !writingFinished, bytes > 0, let child = process, let stdin = input else {
            lock.unlock()
            cancel()
            throw Bridge.Failure(message: "Aucun audio à terminer ou lecture interrompue.")
        }
        writingFinished = true
        let timeout = Double(bytes) / 48000 + 15
        lock.unlock()
        do {
            try stdin.fileHandleForWriting.close()
            guard ended.wait(timeout: .now() + timeout) == .success else {
                throw Bridge.Failure(message: "Délai de fin de lecture SSH dépassé.")
            }
            lock.lock()
            let interrupted = canceled
            lock.unlock()
            guard !interrupted else { throw Bridge.Failure(message: "Lecture audio interrompue.") }
            errors?.fileHandleForReading.readabilityHandler = nil
            if let handle = errors?.fileHandleForReading { diagnostics.read(handle, untilEOF: true) }
            guard child.terminationStatus == 0 else {
                throw Bridge.Failure(message: "Lecture SSH : \(diagnostics.text.isEmpty ? "échec (code \(child.terminationStatus))" : diagnostics.text)")
            }
            cleanup()
        } catch { cancel(); throw error }
    }

    func cancel() {
        lock.lock()
        canceled = true
        ready = false
        let child = process
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
        DispatchQueue.global().async { [self] in
            if let child {
                let deadline = Date().addingTimeInterval(1)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            }
            cleanup()
        }
    }

    private func cleanup() {
        lock.lock()
        let stdin = input, stdout = output, stderr = errors
        input = nil; output = nil; errors = nil; process = nil; ready = false
        lock.unlock()
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.fileHandleForWriting.close()
        // Reader callbacks retain their handles until return; ARC then closes them safely.
        Self.activeLock.lock()
        if Self.active === self { Self.active = nil }
        Self.activeLock.unlock()
    }

    deinit {
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class StreamDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func read(_ handle: FileHandle, untilEOF: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<(untilEOF ? 64 : 1) {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 0) > 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let size = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            guard size > 0 else {
                handle.readabilityHandler = nil
                return
            }
            bytes.append(contentsOf: buffer.prefix(size))
            bytes = Data(bytes.suffix(2500))
        }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
