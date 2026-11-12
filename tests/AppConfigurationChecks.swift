import Foundation

@main
struct AppConfigurationChecks {
    static func main() throws {
        var config = AppConfiguration()
        config.ssh.authentication = .password
        config.ssh.host = "nabaztag-609.local"
        try config.validate()
        assert(config.provider == .chatgpt)
        assert(config.animationsEnabled)
        assert(config.selectedEarMotion == .small && config.selectedLightMode == .fixed)
        assert(config.selectedLightColorHex == "002838")
        assert(config.playbackAction == "play-animated small fixed 002838")
        config.provider = .claude
        try config.validate()
        let oldAccount = config.apiSecretAccount(for: .claude)
        config.providers[AIProvider.claude.rawValue] = .init(model: "claude-test", baseURL: "https://example.com/v1")
        assert(config.apiSecretAccount(for: .claude) != oldAccount)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        assert(decoded.ssh.host == "nabaztag-609.local" && decoded.provider == .claude)
        var mistral = config
        mistral.provider = .mistral
        try mistral.validate()
        assert(mistral.options(for: .mistral).model == "mistral-small-latest")
        assert(mistral.options(for: .mistral).baseURL == "https://api.mistral.ai/v1")
        let mistralAccount = mistral.apiSecretAccount(for: .mistral)
        assert(mistralAccount == "api:mistral:https://api.mistral.ai/v1")
        mistral.providers["mistral"] = .init(model: "mistral-test", baseURL: "https://api.mistral.ai/v1/")
        mistral.providers["openAICompatible"] = .init(model: "compatible-test", baseURL: "https://api.mistral.ai/v1")
        try mistral.validate()
        assert(mistral.apiSecretAccount(for: .mistral) == mistralAccount)
        assert(mistral.apiSecretAccount(for: .openAICompatible) != mistralAccount)
        let restoredMistral = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(mistral))
        assert(restoredMistral.provider == .mistral && restoredMistral.ssh == config.ssh)
        assert(restoredMistral.providers == mistral.providers && restoredMistral.providers["claude"] == config.providers["claude"])
        var subscription = config
        subscription.provider = .claudeCode
        try subscription.validate()
        let restoredSubscription = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(subscription))
        assert(restoredSubscription.provider == .claudeCode && restoredSubscription.ssh == config.ssh)
        assert(restoredSubscription.providers == config.providers)
        assert(restoredSubscription.providers["claude"]?.model == "claude-test")
        assert(restoredSubscription.options(for: .claudeCode).baseURL.isEmpty)
        subscription.provider = .grokBuild
        subscription.providers["grok"] = .init(model: "grok-api-test", baseURL: "https://api.x.ai/v1")
        try subscription.validate()
        let grokSubscription = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(subscription))
        assert(grokSubscription.provider == .grokBuild && grokSubscription.ssh == config.ssh)
        assert(grokSubscription.providers["grok"]?.model == "grok-api-test")
        assert(grokSubscription.providers["claude"]?.model == "claude-test")
        assert(grokSubscription.options(for: .grokBuild).baseURL.isEmpty)
        config.voiceEngine = .macOS
        config.animateResponses = false
        let encoded = try JSONEncoder().encode(config)
        let voice = try JSONDecoder().decode(AppConfiguration.self, from: encoded)
        assert(voice.selectedVoiceEngine == .macOS)
        assert(!voice.animationsEnabled)
        assert(voice.playbackAction == "play")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "voiceEngine")
        legacy.removeValue(forKey: "animateResponses")
        let migrated = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        assert(migrated.voiceEngine == nil && migrated.ssh.host == config.ssh.host && migrated.provider == config.provider)
        assert(migrated.animationsEnabled)
        for oldSetting: Bool? in [nil, true, false] {
            var oldJSON = legacy
            oldJSON["animateResponses"] = oldSetting
            let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: oldJSON))
            assert(restored.selectedEarMotion == (oldSetting == false ? .off : .small))
            assert(restored.selectedLightMode == (oldSetting == false ? .off : .fixed))
            assert(restored.selectedLightColorHex == "002838")
        }
        for ears in EarMotion.allCases {
            for lights in LightMode.allCases {
                config.earMotion = ears
                config.lightMode = lights
                config.lightColorHex = "a1b2c3"
                try config.validate()
                let enabled = ears != .off || lights != .off
                assert(config.animationsEnabled == enabled)
                let expected = enabled ? "play-animated \(ears.rawValue) \(lights.rawValue) A1B2C3" : "play"
                assert(config.playbackAction == expected)
                assert(config.streamPlaybackAction == "play-queue \(ears.rawValue) \(lights.rawValue) A1B2C3")
                let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
                assert(roundTrip.selectedEarMotion == ears && roundTrip.selectedLightMode == lights)
                assert(roundTrip.selectedLightColorHex == "A1B2C3" && roundTrip.playbackAction == expected)
            }
        }
        config.earMotion = .small
        config.lightMode = .random
        let example = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        assert(example.playbackAction == "play-animated small random A1B2C3")
        assert(example.ssh == config.ssh && example.provider == config.provider && example.providers == config.providers)
        assert(example.selectedVoiceEngine == config.selectedVoiceEngine)
        var partial = config
        partial.earMotion = nil
        partial.animateResponses = false
        assert(partial.selectedEarMotion == .off && partial.selectedLightMode == .random)
        for color in ["", "12345", "1234567", "#002838", " 002838", "002838 ", "GG2838", "00\n838", "😀2838", "00_838", "abcdeé"] {
            config.lightColorHex = color
            do { try config.validate(); assertionFailure("Couleur invalide acceptée") } catch {}
        }
        config.lightColorHex = "002838"
        for endpoint in ["https://user:secret@example.com/v1", "https://example.com?key=secret", "http://remote.example/v1"] {
            config.providers[AIProvider.claude.rawValue]?.baseURL = endpoint
            do { try config.validate(); assertionFailure("URL dangereuse acceptée") } catch {}
        }
        print("Tests AppConfiguration : OK (défauts, migrations, Claude abonnement/API séparés, neuf combinaisons d’effets, couleurs, JSON, voix et autres réglages préservés).")
    }
}
