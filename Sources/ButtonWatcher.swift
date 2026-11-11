import Foundation
import Combine
import Darwin

struct ButtonLineParser {
    private var line = Data()
    private var discarding = false

    mutating func append(_ data: Data) -> [String] {
        var events: [String] = []
        for byte in data {
            if byte == 10 {
                if !discarding {
                    if line.last == 13 { line.removeLast() }
                    let event = String(decoding: line, as: UTF8.self)
                    if event == "ready" || event == "click" { events.append(event) }
                }
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count < 64 {
                    line.append(byte)
                } else {
                    line.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }
        return events
    }
}

private final class ButtonDiagnostics {
    private let lock = NSLock()
    private var bytes = Data()

    func read(_ handle: FileHandle, untilEOF: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let chunk = untilEOF ? handle.readDataToEndOfFile() : handle.availableData
        bytes.append(chunk)
        bytes = Data(bytes.suffix(2048))
        return chunk.isEmpty
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class ButtonWatcher: ObservableObject {
    @Published private(set) var status = "Bouton du lapin déconnecté"
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var generation = UUID()
    private var parser = ButtonLineParser()
    private var onClick: (@MainActor () -> Void)?

    func start(onClick: @escaping @MainActor () -> Void) {
        stop()
        status = "Connexion au bouton…"
        self.onClick = onClick
        let token = UUID()
        generation = token
        parser = ButtonLineParser()
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let diagnostics = ButtonDiagnostics()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                for event in self.parser.append(data) {
                    if event == "ready" { self.status = "Bouton du lapin connecté" }
                    if event == "click" { self.onClick?() }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if diagnostics.read(handle) { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] child in
            stderr.fileHandleForReading.readabilityHandler = nil
            _ = diagnostics.read(stderr.fileHandleForReading, untilEOF: true)
            let detail = diagnostics.text
            let code = child.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
                self.status = "Connexion au bouton interrompue (code \(code))." +
                    (detail.isEmpty ? " Reconnecte le bouton pour réessayer." : " \(detail)")
            }
        }
        process = child
        input = stdin
        output = stdout
        errors = stderr
        do {
            child.arguments = try Bridge.sshArguments("watch-button")
            child.environment = try Bridge.sshEnvironment()
            try child.run()
        } catch {
            stop()
            status = "Connexion au bouton impossible : \(error.localizedDescription)"
        }
    }

    func stop() {
        generation = UUID()
        onClick = nil
        Self.close(process: process, input: input, output: output, errors: errors)
        process = nil
        input = nil
        output = nil
        errors = nil
        status = "Bouton du lapin déconnecté"
    }

    private nonisolated static func close(process: Process?, input: Pipe?, output: Pipe?, errors: Pipe?) {
        input?.fileHandleForWriting.closeFile()
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit {
        Self.close(process: process, input: input, output: output, errors: errors)
    }
}
