import Foundation

@main
struct SSHTrustChecks {
    static func check(_ condition: Bool) { assert(condition) }
    static func fails(_ operation: () throws -> Void) {
        do { try operation(); assertionFailure("Cette entrée doit être refusée.") } catch {}
    }

    static func main() async throws {
        let key = Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + Array(repeating: UInt8(7), count: 32))
        let encoded = key.base64EncodedString()
        let line = "rabbit.local ssh-ed25519 \(encoded)\n"
        for host in ["rabbit", "rabbit.local", "192.168.68.54", "::1", "fe80::abcd"] {
            try SSHTrust.validateHost(host)
        }
        for host in ["", "-rabbit", "pi@rabbit.local", "rabbit:22", "rabbit.local\n", "a b", "../rabbit",
                     "rabbit;id", "$(id)", "râbbit.local", "999.999.999.999", "a..local", "127.0.0.1\0evil",
                     "::1\0evil", String(repeating: "a", count: 64)] {
            fails { try SSHTrust.validateHost(host) }
        }
        check(try SSHTrust.validatedLines(host: "rabbit.local", lines: line + line) == line)
        for invalid in ["", "\n", "other.local ssh-ed25519 \(encoded)\n", "rabbit.local ssh-rsa \(encoded)\n",
                        "rabbit.local ssh-ed25519 invalid\n", "rabbit.local ssh-ed25519 YQ==\n",
                        line.trimmingCharacters(in: .newlines) + " extra\n", "# comment\n" + line] {
            fails { _ = try SSHTrust.validatedLines(host: "rabbit.local", lines: invalid) }
        }

        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(".ssh/known_hosts")
        try await SSHTrust.append(host: "rabbit.local", lines: line, to: file)
        check(try String(contentsOf: file, encoding: .utf8) == line)
        for (url, permissions) in [(file, 0o600), (file.deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            assert((attributes[.posixPermissions] as? NSNumber)?.intValue == permissions)
        }
        do {
            try await SSHTrust.append(host: "rabbit.local", lines: line, to: file)
            assertionFailure("Une clé déjà connue ne doit pas être ajoutée une seconde fois.")
        } catch { assert(error.localizedDescription.contains("déjà une clé")) }
        check(try String(contentsOf: file, encoding: .utf8) == line)

        try Data("# conserver ce commentaire".utf8).write(to: file)
        try await SSHTrust.append(host: "rabbit.local", lines: line, to: file)
        check(try String(contentsOf: file, encoding: .utf8) == "# conserver ce commentaire\n" + line)
        do {
            try await SSHTrust.accept(.init(host: "rabbit.local", lines: line, fingerprints: "forged", alreadyKnown: false))
            assertionFailure("Une empreinte modifiée doit être refusée avant toute lecture réelle de known_hosts.")
        } catch { assert(error.localizedDescription.contains("empreinte a changé")) }
        do {
            try await SSHTrust.accept(.init(host: "rabbit.local", lines: line, fingerprints: "", alreadyKnown: true))
            assertionFailure("Un hôte déclaré connu doit être refusé avant toute lecture réelle de known_hosts.")
        } catch { assert(error.localizedDescription.contains("déjà connu")) }
        print("Tests SSHTrust : OK (hôtes, clés, empreintes altérées, append, refus de remplacement, permissions). Aucun réseau ni known_hosts réel.")
    }
}
