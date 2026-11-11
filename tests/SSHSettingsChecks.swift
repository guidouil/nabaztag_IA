import Foundation

@main
struct SSHSettingsChecks {
    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); assertionFailure("La validation aurait dû échouer.") }
        catch { }
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NabaztagSSHChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = folder.appendingPathComponent("test_key")
        try Data("clé de test, aucun secret".utf8).write(to: key)
        var settings = SSHSettings()
        settings.keyPath = key.path
        try settings.validate()
        let keyArguments = try settings.arguments(for: "record 6")
        assert(keyArguments.contains("BatchMode=yes") && keyArguments.contains("IdentitiesOnly=yes"))
        assert(keyArguments.suffix(2).first == "pi@192.168.68.54")
        assert(keyArguments.last == "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py record 6")
        for host in ["192.168.68.54", "Nabaztag.local", "lapin-1", "a.b.example"] {
            settings.host = host
            try settings.validate()
        }
        assert(settings.secretAccount == "ssh:pi@a.b.example")
        for host in ["", "-oProxyCommand=x", "a b", "pi@host", "host/path", "a\nb", "é.local", "a..b", "-a.local", "a-.local", "999.1.2.3", "192.168.01.2", "123"] {
            settings.host = host
            expectFailure { try settings.validate() }
        }
        settings.host = "Nabaztag.LOCAL"
        assert(settings.secretAccount == "ssh:pi@nabaztag.local")
        for username in ["", "-pi", "1pi", "pi@host", "pi space", "pi\n", "$(id)", "é"] {
            settings.username = username
            expectFailure { try settings.validate() }
        }
        settings.username = "pi"
        for action in ["diagnostic", "play", "play-animated", "play-animated off fixed 002838", "play-animated small random FF00AA", "play-animated large off abcdef", "watch-button", "record 1", "record 15"] {
            _ = try settings.arguments(for: action)
        }
        for action in ["record-until-stop", "think forward", "think backward"] {
            _ = try settings.arguments(for: action)
        }
        for action in ["record-until-stop 6", "record-until-stop; id", "think", "think left", "think forward extra", "think  forward", "think forward\n", "think forward; id", "think $(id)"] {
            expectFailure { _ = try settings.arguments(for: action) }
        }
        for action in ["play-stream off off 002838", "play-stream small fixed ABCDEF", "play-stream large random FF00AA"] {
            _ = try settings.arguments(for: action)
            _ = try settings.arguments(for: action.replacingOccurrences(of: "play-stream", with: "play-queue"))
        }
        for action in ["", "sh", "play; id", "play-animated; id", "play-animated extra", "play-animated huge fixed 002838", "play-animated small unknown 002838", "play-animated small fixed 000000;id", "play-animated small fixed $(id)", "play-animated small fixed 12345", "play-animated small fixed 000000 extra", "record", "record 0", "record 16", "record 01", "record +1", "record 1\n", "record  1", "record $(id)", "record 1;id"] {
            expectFailure { _ = try settings.arguments(for: action) }
        }
        for action in ["play-stream", "play-stream off off", "play-stream small fixed 002838 extra", "play-stream huge fixed 002838", "play-stream small fixed 002838;id", "play-stream off off GGGGGG"] {
            expectFailure { _ = try settings.arguments(for: action) }
            expectFailure { _ = try settings.arguments(for: action.replacingOccurrences(of: "play-stream", with: "play-queue")) }
        }
        settings.keyPath = folder.path
        expectFailure { try settings.validate() }
        settings.keyPath = folder.appendingPathComponent("missing").path
        expectFailure { try settings.validate() }
        settings.authentication = .password
        let passwordArguments = try settings.arguments(for: "diagnostic")
        assert(passwordArguments.contains("BatchMode=no") && passwordArguments.contains("PubkeyAuthentication=no"))
        assert(passwordArguments.contains("NumberOfPasswordPrompts=1") && !passwordArguments.contains("-i"))
        assert(passwordArguments.allSatisfy({ !$0.contains("NABAZTAG_SSH_ACCOUNT") }))
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SSHSettings.self, from: encoded)
        assert(decoded == settings)
        let account = "ssh:pi@nabaztag.local"
        assert(isSSHPasswordPrompt("pi@nabaztag.local's password: ", account: account))
        assert(isSSHPasswordPrompt("Password:", account: account))
        for prompt in ["Are you sure you want to continue connecting (yes/no/[fingerprint])?", "Enter passphrase for key:", "Verification code:", "root@other.local's password:", "Password:\n"] {
            assert(!isSSHPasswordPrompt(prompt, account: account))
        }
        print("Tests SSHSettings : OK (hôte/login/clé, actions, modes, compte normalisé, invite askpass, JSON). Aucun accès au Trousseau.")
    }
}
