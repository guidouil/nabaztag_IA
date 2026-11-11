import Foundation
import Darwin

private final class VoiceCheckBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var calls = 0
    func append(_ data: Data) {
        assert(!Thread.isMainThread)
        lock.lock()
        bytes.append(data)
        calls += 1
        lock.unlock()
    }
    var snapshot: (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, calls)
    }
}

@main
struct LocalVoiceChecks {
    static let fixture = #"""
    import base64, json, os, sys, time
    from pathlib import Path
    folder = Path(sys.argv[1])
    mode = sys.argv[2]
    with (folder / "pids").open("a") as output:
        output.write(str(os.getpid()) + "\n")
    def send(event):
        sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    if mode == "no-ready":
        time.sleep(60)
    if mode == "die-ready":
        send({"type": "ready"})
        os._exit(0)
    # Split a JSON line, then send several responses in a single write later.
    os.write(1, b'{"type":')
    time.sleep(.01)
    os.write(1, b'"ready"}\n')
    for line in sys.stdin:
        request = json.loads(line)
        token, text = request["id"], request["text"]
        chunk = {"type": "chunk", "id": token, "sample_rate": 24000, "pcm": "AAD/fw=="}
        done = {"type": "done", "id": token}
        if text == "hang":
            time.sleep(60)
        elif text == "bad-json":
            print("bad-json", flush=True)
        elif text == "wrong-id":
            send(dict(chunk, id="other"))
        elif text == "bad-rate":
            send(dict(chunk, sample_rate=22050))
        elif text == "odd":
            send(dict(chunk, pcm="AA=="))
        elif text == "empty":
            send(done)
        elif text == "huge-line":
            sys.stdout.write(" " * (6 * 1024 * 1024 + 1))
            sys.stdout.flush()
        elif text == "overflow":
            large = base64.b64encode(b"\0" * 2700000).decode("ascii")
            send(dict(chunk, pcm=large))
            send(dict(chunk, pcm=large))
        elif text == "exit":
            print("fixture stopped", file=sys.stderr, flush=True)
            sys.exit(3)
        elif text == "partial":
            send(chunk)
            send({"type": "error", "id": token, "message": "generation stopped"})
        else:
            sys.stdout.write(json.dumps(chunk) + "\n" + json.dumps(chunk) + "\n" + json.dumps(done) + "\n")
            sys.stdout.flush()
    """#

    static func pids(_ folder: URL) -> [Int32] {
        let text = (try? String(contentsOf: folder.appendingPathComponent("pids"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { Int32($0) }
    }

    static func waitUntil(_ condition: () -> Bool, timeout: Double = 3) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw LocalVoiceFailure(message: "Le faux worker n'a pas atteint l'état attendu.")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func fail(_ operation: () async throws -> Void) async {
        do { try await operation(); assertionFailure("Cet appel doit échouer.") }
        catch {}
    }

    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoiceChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker.py")
        try Data(fixture.utf8).write(to: script)

        func worker(_ mode: String = "normal", timeout: Double = 2) -> LocalVoiceWorker {
            LocalVoiceWorker(executable: "/usr/bin/python3", arguments: ["-u", script.path, folder.path, mode],
                             readyTimeout: timeout, requestTimeout: timeout)
        }
        let reused = worker()
        let audio = VoiceCheckBytes()
        reused.prewarm()
        try await waitUntil { pids(folder).count == 1 }
        try await reused.stream("Bonjour.") { audio.append($0) }
        try await reused.stream("Encore.") { audio.append($0) }
        assert(pids(folder).count == 1)
        assert(audio.snapshot.0 == Data([0, 0, 255, 127, 0, 0, 255, 127, 0, 0, 255, 127, 0, 0, 255, 127]))
        assert(audio.snapshot.1 == 4)
        reused.shutdown()
        try await waitUntil { kill(pids(folder)[0], 0) == -1 && errno == ESRCH }

        for invalid in ["", "  \n", String(repeating: "x", count: 2001), "a\0b"] {
            let child = worker()
            let before = pids(folder).count
            await fail { try await child.stream(invalid) { _ in assertionFailure() } }
            assert(pids(folder).count == before)
            child.shutdown()
        }

        for mode in ["bad-json", "wrong-id", "bad-rate", "odd", "empty", "huge-line", "overflow", "exit", "partial"] {
            let child = worker(timeout: 3)
            await fail { try await child.stream(mode) { _ in } }
            child.shutdown()
        }
        // A callback failure stops the current worker; the next call starts a new one.
        let callbackWorker = worker()
        let calls = VoiceCheckBytes()
        let beforeCallback = pids(folder).count
        await fail {
            try await callbackWorker.stream("Bonjour.") { chunk in
                calls.append(chunk)
                throw LocalVoiceFailure(message: "SSH fermé")
            }
        }
        assert(calls.snapshot.1 == 1)
        try await callbackWorker.stream("Encore.") { _ in }
        assert(pids(folder).count == beforeCallback + 2)
        callbackWorker.shutdown()

        for mode in ["no-ready", "die-ready"] {
            let child = worker(mode, timeout: 0.2)
            await fail { try await child.stream("Bonjour.") { _ in } }
            child.shutdown()
        }
        let timed = worker(timeout: 0.2)
        let begin = ProcessInfo.processInfo.systemUptime
        await fail { try await timed.stream("hang") { _ in } }
        assert(ProcessInfo.processInfo.systemUptime - begin < 2)
        timed.shutdown()

        let cancelled = worker(timeout: 10)
        let beforeCancel = pids(folder).count
        let task = Task { try await cancelled.stream("hang") { _ in } }
        try await waitUntil { pids(folder).count == beforeCancel + 1 }
        task.cancel()
        await fail { try await task.value }
        cancelled.shutdown()

        // Shutdown must kill Python without waiting behind a blocked playback callback.
        let blocked = worker(timeout: 10)
        let callbackEntered = VoiceCheckBytes()
        let callbackRelease = DispatchSemaphore(value: 0)
        let streaming = Task {
            try await blocked.stream("Bonjour.") { _ in
                callbackEntered.append(Data())
                _ = callbackRelease.wait(timeout: .now() + 5)
            }
        }
        try await waitUntil { callbackEntered.snapshot.1 > 0 }
        let stopBegan = ProcessInfo.processInfo.systemUptime
        blocked.shutdown()
        assert(ProcessInfo.processInfo.systemUptime - stopBegan < 0.2)
        let blockedPID = pids(folder).last!
        try await waitUntil { kill(blockedPID, 0) == -1 && errno == ESRCH }
        callbackRelease.signal()
        await fail { try await streaming.value }
        try await waitUntil { pids(folder).allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        print("LocalVoiceChecks : protocole, réutilisation, limites, erreurs et arrêt validés.")
    }
}
