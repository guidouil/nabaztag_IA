import Foundation

enum VoiceEngine: String, Codable, CaseIterable, Identifiable {
    case kokoro, macOS
    var id: String { rawValue }
    var title: String { self == .kokoro ? "Siwis · Kokoro local" : "Thomas · macOS" }
}

enum EarMotion: String, Codable, CaseIterable {
    case off, on

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "off": self = .off
        case "on", "small", "large": self = .on
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Mouvement des oreilles inconnu.")
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
    var rabbitName: String?
    var personalityPrompt: String?
    private static let storageKey = "nabaztag.configuration"

    static let defaultRabbitName = "Nabaztag"
    static let defaultPersonalityPrompt = """
    Tu es un petit lapin de bureau à la personnalité pince-sans-rire, un peu absurde et complice.
    Réponds d'abord à la question ; ajoute parfois une courte touche d'humour si elle convient, sans forcer les références aux lapins ni répéter les mêmes plaisanteries.
    Ne rabaisse pas l'utilisateur. Pour un sujet grave, une détresse ou une demande de ton sérieux, laisse l'humour de côté.
    Les fantaisies de lapin sont des plaisanteries manifestes, jamais des faits ni des capacités réelles inventées.
    """

    var selectedRabbitName: String {
        let name = rabbitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? Self.defaultRabbitName : name
    }
    var selectedPersonalityPrompt: String { personalityPrompt ?? Self.defaultPersonalityPrompt }
    var selectedVoiceEngine: VoiceEngine { voiceEngine ?? (LocalVoice.isInstalled ? .kokoro : .macOS) }
    var selectedEarMotion: EarMotion { earMotion ?? (animateResponses == false ? .off : .on) }
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
        let name = rabbitName ?? ""
        guard name.count <= 80, !name.contains("\0"), name.rangeOfCharacter(from: .newlines) == nil else {
            throw SSHSettings.Failure(message: "Le prénom doit tenir sur une seule ligne de 80 caractères maximum.")
        }
        let personality = selectedPersonalityPrompt
        guard personality.count <= 8_000, !personality.contains("\0") else {
            throw SSHSettings.Failure(message: "Le prompt de personnalité doit contenir au maximum 8 000 caractères, sans caractère nul.")
        }
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
        normalized.rabbitName = selectedRabbitName
        normalized.lightColorHex = selectedLightColorHex
        UserDefaults.standard.set(try JSONEncoder().encode(normalized), forKey: Self.storageKey)
    }
}
