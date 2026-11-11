import Foundation
import Darwin

enum SSHTrust {
    struct Scan {
        let host: String
        let lines: String
        let fingerprints: String
        let alreadyKnown: Bool
    }

    private static var knownHosts: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    }

    static func validateHost(_ host: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw Bridge.Failure(message: "Hôte SSH invalide : utilise un nom ou une adresse IP ASCII sans espace.")
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 ||
            host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return }
        let dns = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?\z"#
        guard host.utf8.count <= 253,
              host.range(of: dns, options: .regularExpression) != nil,
              !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            throw Bridge.Failure(message: "Hôte SSH invalide : indique un nom DNS ou une adresse IP, sans port ni utilisateur.")
        }
    }

    static func validatedLines(host: String, lines: String) throws -> String {
        try validateHost(host)
        guard !lines.isEmpty, lines.utf8.count <= 65536 else {
            throw Bridge.Failure(message: "La réponse ssh-keyscan est vide ou trop longue.")
        }
        var validated: [String] = []
        for line in lines.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, fields[0] == host, fields[1] == "ssh-ed25519",
                  let key = Data(base64Encoded: fields[2]), key.count == 51,
                  key.prefix(15) == Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8)),
                  key.subdata(in: 15..<19) == Data([0, 0, 0, 32]),
                  key.base64EncodedString() == fields[2] else {
                throw Bridge.Failure(message: "La clé reçue ne correspond pas à l’hôte ou au format Ed25519 attendu.")
            }
            let normalized = fields.joined(separator: " ")
            if !validated.contains(normalized) { validated.append(normalized) }
        }
        guard !validated.isEmpty else { throw Bridge.Failure(message: "Aucune clé SSH reçue.") }
        return validated.joined(separator: "\n") + "\n"
    }

    private static func fingerprints(_ lines: String) async throws -> String {
        let folder = try Bridge.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("host-keys")
        try Data(lines.utf8).write(to: file)
        let data = try await Bridge.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.path])
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Bridge.Failure(message: "Impossible de calculer l’empreinte SSH.") }
        return text
    }

    private static func isKnown(host: String, file: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-F", host, "-f", file.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            switch process.terminationStatus {
            case 0: return true
            case 1: return false
            default: throw Bridge.Failure(message: "Impossible de vérifier le fichier known_hosts.")
            }
        }.value
    }

    static func scan(host: String) async throws -> Scan {
        try validateHost(host)
        let host = host.lowercased()
        let data = try await Bridge.run("/usr/bin/ssh-keyscan", ["-T", "5", "-t", "ed25519", host], timeout: 10)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Bridge.Failure(message: "Réponse ssh-keyscan invalide.")
        }
        let lines = try validatedLines(host: host, lines: text)
        return Scan(host: host, lines: lines, fingerprints: try await fingerprints(lines),
                    alreadyKnown: try await isKnown(host: host, file: knownHosts))
    }

    static func accept(_ scan: Scan) async throws {
        guard !scan.alreadyKnown else {
            throw Bridge.Failure(message: "Cet hôte est déjà connu. Aucune clé existante ne sera remplacée.")
        }
        let lines = try validatedLines(host: scan.host, lines: scan.lines)
        guard try await fingerprints(lines) == scan.fingerprints else {
            throw Bridge.Failure(message: "L’empreinte a changé depuis sa présentation. Relance la vérification.")
        }
        try await append(host: scan.host, lines: lines, to: knownHosts)
    }

    static func append(host: String, lines: String, to file: URL) async throws {
        let lines = try validatedLines(host: host, lines: lines)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = file.path.withCString { Darwin.open($0, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Bridge.Failure(message: "Le fichier known_hosts est occupé. Réessaie.")
        }
        guard try await !isKnown(host: host, file: file) else {
            throw Bridge.Failure(message: "Cet hôte possède déjà une clé enregistrée. Aucune clé ne sera ajoutée ni remplacée.")
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let end = try handle.seekToEnd()
        var prefix = ""
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.last != 10 { prefix = "\n" }
        }
        try handle.write(contentsOf: Data((prefix + lines).utf8))
    }
}
