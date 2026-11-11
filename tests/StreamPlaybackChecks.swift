import Foundation
import Darwin

@main
struct StreamPlaybackChecks {
    static func main() async throws {
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
          invalid) printf 'not-ready\n'; exec /bin/sleep 10 ;;
          timeout) exec /bin/sleep 10 ;;
          stall) printf 'ready\n'; trap '' TERM; exec /bin/sleep 10 ;;
          noise) while :; do printf 'diagnostic fixture\n' >&2; /bin/sleep 0.01; done ;;
          exit) printf 'ready\n'; exit 0 ;;
        esac
        printf rea
        /bin/sleep 0.02
        printf 'dy\n'
        /bin/dd bs=2 count=1 of="$fixture/first" 2>/dev/null
        /bin/cat > "$fixture/rest"
        if [ "$mode" = error ]; then printf 'test-relay-failed\n' >&2; exit 7; fi
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let key = folder.appendingPathComponent("test-key")
        try Data("fixture".utf8).write(to: key)
        var configuration = AppConfiguration()
        configuration.ssh.host = "fixture.local"
        configuration.ssh.keyPath = key.path
        configuration.earMotion = .large
        configuration.lightMode = .random
        configuration.lightColorHex = "AABBCC"

        func setMode(_ mode: String) throws {
            try Data(mode.utf8).write(to: folder.appendingPathComponent("mode"))
        }
        func playback(_ timeout: Double = 1) -> StreamPlayback {
            StreamPlayback(configuration: configuration, executable: executable.path, readyTimeout: timeout)
        }
        try setMode("normal")
        let stream = playback()
        let pcm = Data([1, 2, 3, 4, 5, 6])
        try stream.write(pcm)
        let first = folder.appendingPathComponent("first")
        for _ in 0..<100 {
            if (try? Data(contentsOf: first))?.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstBytes = try Data(contentsOf: first)
        assert(firstBytes == Data([1, 2]), "Le premier PCM doit arriver avant finish/EOF.")
        try await stream.finish()
        let rest = try Data(contentsOf: folder.appendingPathComponent("rest"))
        assert(firstBytes + rest == pcm)
        let arguments = try Data(contentsOf: folder.appendingPathComponent("arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let expectedArguments = try configuration.ssh.arguments(for: configuration.streamPlaybackAction)
        assert(arguments == expectedArguments)

        for mode in ["invalid", "timeout"] {
            try setMode(mode)
            let rejected = playback(0.08)
            do { try await rejected.start(); assertionFailure("Un ACK invalide ou absent doit échouer.") }
            catch { assert(error.localizedDescription.contains("flux audio")) }
        }
        try setMode("stall")
        let stalled = StreamPlayback(configuration: configuration, executable: executable.path, readyTimeout: 1, writeTimeout: 0.1)
        try await stalled.start()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try stalled.write(Data(repeating: 1, count: 512 * 1024))
            assertionFailure("Un SSH qui ne consomme pas le PCM doit expirer.")
        } catch { assert(error.localizedDescription.contains("Délai")) }
        assert(ProcessInfo.processInfo.systemUptime - started < 1)
        stalled.cancel()
        try setMode("noise")
        for _ in 0..<20 {
            let interrupted = playback()
            let starting = Task { try await interrupted.start() }
            try await Task.sleep(nanoseconds: 20_000_000)
            interrupted.cancel()
            do { try await starting.value; assertionFailure("L’attente ACK annulée doit échouer.") }
            catch {}
        }
        try setMode("normal")
        for invalid in [Data(), Data([1]), Data(repeating: 0, count: StreamPlayback.maxBytes + 2)] {
            let rejected = playback()
            try await rejected.start()
            do { try rejected.write(invalid); assertionFailure("PCM invalide accepté.") }
            catch { assert(error.localizedDescription.contains("PCM")) }
            rejected.cancel()
        }
        try setMode("error")
        let failed = playback()
        try await failed.start()
        try failed.write(pcm)
        do { try await failed.finish(); assertionFailure("Une erreur du relais doit être remontée.") }
        catch { assert(error.localizedDescription.contains("test-relay-failed")) }

        try setMode("exit")
        let closed = playback()
        try await closed.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        do { try closed.write(pcm); assertionFailure("Un SSH fermé doit être refusé sans SIGPIPE.") }
        catch {}
        closed.cancel()

        try setMode("normal")
        let canceled = playback()
        try await canceled.start()
        let pid = Int32(try String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8))!
        StreamPlayback.cancelActive()
        do { try canceled.write(pcm); assertionFailure("Un flux annulé doit refuser les écritures.") }
        catch {}
        for _ in 0..<150 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(kill(pid, 0) != 0, "Le processus SSH annulé doit être terminé.")
        print("Tests StreamPlayback : OK (PCM avant EOF, ACK fragmenté/invalide/délai, limites, erreur SSH, annulation, SIGPIPE). Aucun réseau.")
    }
}
