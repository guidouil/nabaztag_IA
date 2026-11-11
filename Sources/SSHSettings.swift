import Foundation
import Security

enum SSHAuthentication: String, Codable, CaseIterable {
    case key, password
}

struct SSHSettings: Codable, Equatable {
    var host = "192.168.68.54"
    var username = "pi"
    var authentication: SSHAuthentication = .key
    var keyPath = "~/.ssh/nabaztag_mac_ed25519"

    var secretAccount: String { "ssh:\(username)@\(host.lowercased())" }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func validate() throws {
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ allowedHost.contains($0) }),
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" }) else {
            throw Failure(message: "Hôte SSH invalide. Utilise une adresse IPv4 ou un nom comme nabaztag.local.")
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard labels.count == 4, labels.allSatisfy({
                guard let value = Int($0), (0...255).contains(value) else { return false }
                return String(value) == $0
            }) else { throw Failure(message: "Adresse IPv4 invalide.") }
        }
        let first = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let rest = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard (1...32).contains(username.utf8.count),
              username.unicodeScalars.first.map({ first.contains($0) }) == true,
              username.unicodeScalars.allSatisfy({ rest.contains($0) }) else {
            throw Failure(message: "Login SSH invalide. Utilise un nom Unix simple, sans espace ni symbole @.")
        }
        if authentication == .key {
            let expanded = (keyPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: expanded) else {
                throw Failure(message: "Clé SSH introuvable ou illisible. Choisis un fichier de clé privée existant.")
            }
        }
    }

    func arguments(for action: String) throws -> [String] {
        try validate()
        let fields = action.split(separator: " ", omittingEmptySubsequences: false)
        let isRecord = fields.count == 2 && fields[0] == "record" &&
            Int(fields[1]).map({ (1...15).contains($0) && String($0) == fields[1] }) == true
        let isConfiguredPlayback = fields.count == 4 && ["play-animated", "play-stream"].contains(String(fields[0])) &&
            ["off", "small", "large"].contains(String(fields[1])) &&
            ["off", "fixed", "random"].contains(String(fields[2])) &&
            fields[3].utf8.count == 6 &&
            fields[3].range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
        guard ["diagnostic", "play", "play-animated", "watch-button"].contains(action) || isRecord || isConfiguredPlayback else {
            throw Failure(message: "Commande SSH non autorisée.")
        }
        var arguments = ["-T", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                         "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        switch authentication {
        case .key:
            arguments += ["-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", (keyPath as NSString).expandingTildeInPath]
        case .password:
            arguments += ["-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                          "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }
        return arguments + ["\(username)@\(host.lowercased())", "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py \(action)"]
    }

    func environment() throws -> [String: String] {
        try validate()
        var environment = ProcessInfo.processInfo.environment
        for name in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", "NABAZTAG_SSH_ACCOUNT"] {
            environment.removeValue(forKey: name)
        }
        if authentication == .password {
            guard let password = try KeychainSecrets.read(secretAccount), !password.isEmpty else {
                throw Failure(message: "Aucun mot de passe enregistré dans le Trousseau pour ce login et cet hôte.")
            }
            guard let executable = Bundle.main.executableURL else {
                throw Failure(message: "Impossible de localiser l'application pour l'authentification SSH.")
            }
            let helper = executable.deletingLastPathComponent().appendingPathComponent("NabaztagSSHAskpass").path
            guard FileManager.default.isExecutableFile(atPath: helper) else {
                throw Failure(message: "Assistant SSH manquant. Reconstruis Nabaztag IA avec build.command.")
            }
            environment["SSH_ASKPASS"] = helper
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "nabaztag"
            environment["NABAZTAG_SSH_ACCOUNT"] = secretAccount
        }
        return environment
    }
}

enum KeychainSecrets {
    static let service = "local.gui.nabaztag-ia"

    private static func query(_ account: String) throws -> [String: Any] {
        guard !account.isEmpty, !account.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw SSHSettings.Failure(message: "Identifiant de secret invalide.")
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false]
    }

    private static func failure(_ status: OSStatus, operation: String) -> SSHSettings.Failure {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return SSHSettings.Failure(message: "Trousseau — \(operation) impossible : \(reason)")
    }

    static func read(_ account: String) throws -> String? {
        var query = try query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status, operation: "lecture") }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SSHSettings.Failure(message: "Le secret du Trousseau n'est pas un texte UTF-8 valide.")
        }
        return value
    }

    static func set(_ value: String, for account: String) throws {
        guard !value.isEmpty, !value.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw SSHSettings.Failure(message: "Le mot de passe doit être non vide et tenir sur une ligne.")
        }
        var query = try query(account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            query[kSecAttrLabel as String] = "Nabaztag IA — \(account)"
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status, operation: "enregistrement") }
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(try query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, operation: "suppression") }
    }
}

func isSSHPasswordPrompt(_ prompt: String, account: String) -> Bool {
    guard account.hasPrefix("ssh:"),
          !prompt.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else { return false }
    let normalized = prompt.trimmingCharacters(in: .whitespaces).lowercased()
    let target = account.dropFirst(4).lowercased()
    return normalized == "password:" || normalized == "\(target)'s password:"
}
