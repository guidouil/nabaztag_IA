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
          gated)
            : > "$fixture/connecting"
            while [ ! -f "$fixture/release" ]; do /bin/sleep 0.01; done
            ;;
        esac
        printf rea
        /bin/sleep 0.02
        printf 'dy\n'
        /bin/dd bs=6 count=1 of="$fixture/first" 2>/dev/null
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
        configuration.earMotion = .on
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
            if (try? Data(contentsOf: first))?.count == 6 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstBytes = try Data(contentsOf: first)
        assert(firstBytes == Data([0, 0, 0, 6, 1, 2]), "La taille et le premier PCM doivent arriver avant finish/EOF.")
        try stream.write(Data([7, 8]))
        try await stream.finish()
        let rest = try Data(contentsOf: folder.appendingPathComponent("rest"))
        assert(firstBytes + rest == Data([0, 0, 0, 6]) + pcm + Data([0, 0, 0, 2, 7, 8]))
        let arguments = try Data(contentsOf: folder.appendingPathComponent("arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let expectedArguments = try configuration.ssh.arguments(for: configuration.streamPlaybackAction)
        assert(arguments == expectedArguments)

        for direction in ["forward", "backward"] {
            for name in ["arguments", "first", "connecting", "release"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            try setMode("gated")
            let thinking = StreamPlayback(configuration: configuration, thinkingDirection: direction,
                                          executable: executable.path, readyTimeout: 2)
            let starting = Task { try await thinking.start() }
            let connecting = folder.appendingPathComponent("connecting")
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: connecting.path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            assert(FileManager.default.fileExists(atPath: connecting.path), "La connexion doit commencer avant le premier PCM.")
            assert(!FileManager.default.fileExists(atPath: first.path))
            let arguments = try Data(contentsOf: folder.appendingPathComponent("arguments"))
                .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            let expected = try configuration.ssh.arguments(for: "\(configuration.streamPlaybackAction) \(direction)")
            assert(arguments == expected)
            try Data().write(to: folder.appendingPathComponent("release"))
            try await starting.value
            assert(!FileManager.default.fileExists(atPath: first.path), "Le signal ready ne doit pas envoyer de PCM.")
            try thinking.write(pcm)
            try await thinking.finish()
            let transmitted = try Data(contentsOf: first) + Data(contentsOf: folder.appendingPathComponent("rest"))
            assert(transmitted == Data([0, 0, 0, 6]) + pcm)
        }
        for name in ["connecting", "release"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        try setMode("gated")
        let canceledStart = StreamPlayback(configuration: configuration, thinkingDirection: "forward",
                                            executable: executable.path, readyTimeout: 15)
        let starting = Task { try await canceledStart.start() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("connecting").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(FileManager.default.fileExists(atPath: folder.appendingPathComponent("connecting").path))
        let startingPID = Int32(try String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8))!
        let canceledAt = ProcessInfo.processInfo.systemUptime
        starting.cancel()
        do { try await starting.value; assertionFailure("Une tâche annulée doit interrompre l’attente ready.") }
        catch {}
        for _ in 0..<150 {
            if kill(startingPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(kill(startingPID, 0) != 0, "L’annulation doit terminer le SSH en cours de connexion.")
        assert(ProcessInfo.processInfo.systemUptime - canceledAt < 2, "L’annulation ne doit pas attendre le délai ready de 15 secondes.")
        for name in ["arguments", "pid"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for direction in ["", "sideways", "forward\n", "backward extra", "forward; id"] {
            let rejected = StreamPlayback(configuration: configuration, thinkingDirection: direction,
                                          executable: executable.path)
            do { try await rejected.start(); assertionFailure("Un sens invalide doit échouer avant SSH.") }
            catch { assert(error.localizedDescription.contains("Sens de réflexion invalide")) }
            assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("arguments").path))
            assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pid").path))
            rejected.cancel()
        }

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
