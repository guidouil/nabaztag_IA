import Foundation

enum VoiceEngine: String, Codable, CaseIterable, Identifiable {
    case kokoro, macOS
    var id: String { rawValue }
    var title: String { self == .kokoro ? "Siwis · Kokoro local" : "Thomas · macOS" }
}

enum EarMotion: String, Codable, CaseIterable, Identifiable {
    case off, small, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Aucun"
        case .small: return "Petits"
        case .large: return "Grands"
        }
    }
}

enum LightMode: String, Codable, CaseIterable, Identifiable {
    case off, fixed, random
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Éteintes"
        case .fixed: return "Couleur fixe"
        case .random: return "Multicolore aléatoire"
        }
    }
}

struct ProviderConfiguration: Codable, Equatable {
    var model: String
    var baseURL: String
}

struct AppConfiguration: Codable {
    var ssh = SSHSettings()
    var provider = AIProvider.chatgpt
    var providers: [String: ProviderConfiguration] = [:]
    var voiceEngine: VoiceEngine?
    var animateResponses: Bool?
    var earMotion: EarMotion?
    var lightMode: LightMode?
    var lightColorHex: String?
    private static let storageKey = "nabaztag.configuration"

    var selectedVoiceEngine: VoiceEngine { voiceEngine ?? (LocalVoice.isInstalled ? .kokoro : .macOS) }
    var selectedEarMotion: EarMotion { earMotion ?? (animateResponses == false ? .off : .small) }
    var selectedLightMode: LightMode { lightMode ?? (animateResponses == false ? .off : .fixed) }
    var selectedLightColorHex: String { (lightColorHex ?? "002838").uppercased() }
    var animationsEnabled: Bool { selectedEarMotion != .off || selectedLightMode != .off }
    var playbackAction: String {
        animationsEnabled ? "play-animated \(selectedEarMotion.rawValue) \(selectedLightMode.rawValue) \(selectedLightColorHex)" : "play"
    }
    var streamPlaybackAction: String {
        "play-queue \(selectedEarMotion.rawValue) \(selectedLightMode.rawValue) \(selectedLightColorHex)"
    }

    func options(for provider: AIProvider) -> ProviderConfiguration {
        providers[provider.rawValue] ?? ProviderConfiguration(model: provider.defaultModel, baseURL: provider.defaultBaseURL)
    }

    func apiSecretAccount(for provider: AIProvider) -> String {
        "api:\(provider.rawValue):\(options(for: provider).baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    static func load() -> AppConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return AppConfiguration()
        }
        return configuration
    }

    func validate() throws {
        let color = lightColorHex ?? "002838"
        guard color.utf8.count == 6, color.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }) else {
            throw SSHSettings.Failure(message: "La couleur doit contenir exactement six chiffres hexadécimaux, sans #.")
        }
        try ssh.validate()
        for candidate in AIProvider.allCases where candidate.usesAPI && (candidate == provider || providers[candidate.rawValue] != nil) {
            let options = options(for: candidate)
            let model = options.model.isEmpty && candidate != provider ? "configuration" : options.model
            _ = try RemoteAI.makeRequest("Vérification des réglages", provider: candidate, model: model,
                                         apiKey: "validation-only", baseURL: options.baseURL)
        }
    }

    func save() throws {
        try validate()
        var normalized = self
        normalized.lightColorHex = selectedLightColorHex
        UserDefaults.standard.set(try JSONEncoder().encode(normalized), forKey: Self.storageKey)
    }
}
