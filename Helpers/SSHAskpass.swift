import Foundation
import Darwin

@main
struct SSHAskpass {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2,
              let account = ProcessInfo.processInfo.environment["NABAZTAG_SSH_ACCOUNT"],
              isSSHPasswordPrompt(arguments[1], account: account) else { exit(1) }
        do {
            guard let password = try KeychainSecrets.read(account), !password.isEmpty,
                  !password.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else { exit(1) }
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
        } catch {
            exit(1)
        }
    }
}
