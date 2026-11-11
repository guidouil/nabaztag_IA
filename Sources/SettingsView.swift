import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State var configuration: AppConfiguration
    let onSave: (AppConfiguration) -> Void
    @State private var sshPassword = ""
    @State private var apiKey = ""
    @State private var message = ""
    @State private var busy = false
    @State private var scan: SSHTrust.Scan?
    @State private var confirmingTrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Réglages de Nabaztag IA").font(.title2.bold())
            ScrollView {
                Form {
                    Section("Connexion au lapin") {
                        TextField("IP ou nom local", text: $configuration.ssh.host)
                        TextField("Identifiant SSH", text: $configuration.ssh.username)
                        Picker("Authentification", selection: $configuration.ssh.authentication) {
                            Text("Clé SSH").tag(SSHAuthentication.key)
                            Text("Mot de passe").tag(SSHAuthentication.password)
                        }
                        if configuration.ssh.authentication == .key {
                            TextField("Fichier de clé privée", text: $configuration.ssh.keyPath)
                        } else {
                            SecureField("Mot de passe SSH", text: $sshPassword)
                            Text("Enregistré dans le Trousseau macOS pour cet identifiant et cet hôte. Laisse le champ vide pour conserver le mot de passe déjà enregistré.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Vérifier l’empreinte SSH") { scanHost() }
                            if let scan, !scan.alreadyKnown {
                                Button("Faire confiance à cette empreinte") { confirmingTrust = true }
                            }
                        }
                        if let scan {
                            Text(scan.fingerprints).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(scan.alreadyKnown ? "Cet hôte figure déjà dans les hôtes SSH connus. Une clé modifiée sera refusée lors de la connexion." : "Compare cette empreinte avec celle du lapin avant de l’accepter.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section("Intelligence artificielle") {
                        Picker("Fournisseur", selection: $configuration.provider) {
                            ForEach(AIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                        }
                        if configuration.provider == .chatgpt {
                            Text("Utilise la connexion ChatGPT de Codex sur ce Mac et les limites de ton abonnement. Aucune clé API requise.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if configuration.provider == .claudeCode {
                            Text("Utilise l’outil officiel Claude Code et un abonnement Claude compatible sur ce Mac. Les limites et les éventuels crédits supplémentaires sont ceux de ton compte Claude. Aucune clé API n’est utilisée par ce mode.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(ClaudeCode.isInstalled ? "Claude Code est installé. La connexion au compte reste gérée par l’outil officiel." : "Claude Code n’est pas installé. Installe-le avant d’utiliser ce fournisseur.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("[Instructions d’installation officielles](https://code.claude.com/docs/en/setup)")
                                .font(.caption)
                            Text("Dans Terminal :\nclaude auth login\nclaude auth status --text")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Choisis le compte lié à ton abonnement. Aucun mot de passe ni jeton Claude n’est saisi dans cette application. Une erreur de connexion ou de quota ne déclenche aucun repli vers l’API.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if configuration.provider == .grokBuild {
                            Text("Utilise l’outil officiel Grok Build avec un abonnement SuperGrok ou X Premium+ compatible. Les limites et les éventuels crédits supplémentaires dépendent de ton compte Grok. Aucune clé API n’est utilisée par ce mode.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(GrokBuild.isInstalled ? "Grok Build est installé. La connexion au compte reste gérée par l’outil officiel." : "Grok Build n’est pas installé. Installe-le avant d’utiliser ce fournisseur.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("[Instructions d’installation officielles](https://docs.x.ai/build/overview)")
                                .font(.caption)
                            Text("Dans Terminal :\ngrok login")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Connecte le compte lié à ton abonnement. Aucun mot de passe ni jeton Grok n’est saisi dans cette application. Les erreurs sont affichées sans repli vers le connecteur Grok API.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if configuration.provider.usesAPI {
                            TextField("Modèle", text: modelBinding)
                            TextField("Adresse de l’API", text: endpointBinding)
                            SecureField("Clé API", text: $apiKey)
                            Text("Clé stockée dans le Trousseau ; un champ vide conserve la clé enregistrée pour cette adresse. Ces appels utilisent l’API du fournisseur : vérifie sa tarification et ses quotas. Les abonnements aux applications de chat ne sont pas utilisés ici.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section("Voix") {
                        Picker("Voix des réponses", selection: Binding(get: { configuration.selectedVoiceEngine }, set: { configuration.voiceEngine = $0 })) {
                            ForEach(VoiceEngine.allCases) { voice in Text(voice.title).tag(voice) }
                        }
                        Text(LocalVoice.isInstalled ? "Kokoro est installé sur ce Mac : voix française féminine Siwis, sans clé API et sans consommation de tokens. La génération reste locale." : "Kokoro n’est pas installé sur ce Mac. Le README explique son installation ; Thomas reste disponible.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("La transcription reste assurée localement par macOS. Whisper transcrit la parole et ne produit pas de voix. Le texte des questions et réponses est envoyé au fournisseur IA choisi.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    Section("Animations") {
                        Picker("Mouvements des oreilles", selection: Binding(get: { configuration.selectedEarMotion }, set: { configuration.earMotion = $0 })) {
                            ForEach(EarMotion.allCases) { motion in Text(motion.title).tag(motion) }
                        }
                        Picker("Lumières", selection: Binding(get: { configuration.selectedLightMode }, set: { configuration.lightMode = $0 })) {
                            ForEach(LightMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        if configuration.selectedLightMode == .fixed {
                            ColorPicker("Couleur des lumières", selection: lightColorBinding, supportsOpacity: false)
                        }
                        Text("Pendant les réponses et le test de voix. Aucun effet pendant l’écoute du micro.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Aide pour les clés et les autres lapins") {
                        Text("Ce lapin possède déjà le relais audio et une clé dédiée. Pour une autre machine sous Pynab, installe d’abord le relais bridge_remote.py fourni avec l’application ; le fichier README décrit la procédure. Un nom comme nabaztag-609.local convient s’il se résout sur ton réseau.")
                            .font(.callout)
                        Text("Pour créer une clé dans Terminal :\nssh-keygen -t ed25519\nPuis ajoute le contenu du fichier public .pub dans ~/.ssh/authorized_keys du compte du lapin. Seule la clé publique est copiée ; la clé privée reste sur ce Mac.")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Une erreur « Permission denied » concerne les identifiants. « Host key verification failed » nécessite de vérifier l’empreinte. « No route to host » nécessite de vérifier le Wi-Fi et l’autorisation Réseau local de macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 660, height: 700)
        .disabled(busy)
        .onChange(of: configuration.provider) { _, _ in apiKey = "" }
        .onChange(of: configuration.ssh.host) { _, _ in scan = nil; sshPassword = "" }
        .onChange(of: configuration.ssh.username) { _, _ in sshPassword = "" }
        .onChange(of: configuration.options(for: configuration.provider).baseURL) { _, _ in apiKey = "" }
        .alert("Faire confiance à cette clé SSH ?", isPresented: $confirmingTrust) {
            Button("Annuler", role: .cancel) {}
            Button("Accepter l’empreinte") { acceptHost() }
        } message: {
            Text("\(scan?.host ?? "")\n\(scan?.fingerprints ?? "")\nAccepte uniquement si cette empreinte correspond bien à ton lapin.")
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { configuration.options(for: configuration.provider).model }, set: {
            var options = configuration.options(for: configuration.provider)
            options.model = $0
            configuration.providers[configuration.provider.rawValue] = options
        })
    }

    private var lightColorBinding: Binding<Color> {
        Binding(get: {
            let value = Int(configuration.selectedLightColorHex, radix: 16) ?? 0x002838
            return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                         green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map {
                Int((min(1, max(0, $0)) * 255).rounded())
            }
            configuration.lightColorHex = String(format: "%02X%02X%02X", rgb[0], rgb[1], rgb[2])
        })
    }

    private var endpointBinding: Binding<String> {
        Binding(get: { configuration.options(for: configuration.provider).baseURL }, set: {
            var options = configuration.options(for: configuration.provider)
            options.baseURL = $0
            configuration.providers[configuration.provider.rawValue] = options
        })
    }

    private func save() {
        do {
            configuration.ssh.host = configuration.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.ssh.username = configuration.ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
            try configuration.validate()
            if configuration.selectedVoiceEngine == .kokoro && !LocalVoice.isInstalled {
                throw Bridge.Failure(message: "Installe le moteur Kokoro local avant de le sélectionner, ou choisis Thomas.")
            }
            let draft = configuration, password = sshPassword
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.provider.usesAPI && !key.isEmpty {
                let options = draft.options(for: draft.provider)
                _ = try RemoteAI.makeRequest("Vérification des réglages", provider: draft.provider,
                                             model: options.model, apiKey: key, baseURL: options.baseURL)
            }
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    try await Task.detached {
                        if draft.ssh.authentication == .password {
                            if !password.isEmpty { try KeychainSecrets.set(password, for: draft.ssh.secretAccount) }
                            else if try KeychainSecrets.read(draft.ssh.secretAccount)?.isEmpty != false {
                                throw Bridge.Failure(message: "Renseigne le mot de passe SSH.")
                            }
                        }
                        if draft.provider.usesAPI && !key.isEmpty {
                            try KeychainSecrets.set(key, for: draft.apiSecretAccount(for: draft.provider))
                        }
                        try draft.save()
                    }.value
                    onSave(draft)
                    dismiss()
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }

    private func scanHost() {
        busy = true
        message = "Lecture de l’empreinte…"
        Task { @MainActor in
            defer { busy = false }
            do { scan = try await SSHTrust.scan(host: configuration.ssh.host); message = "Empreinte lue. Aucun accès ajouté automatiquement." }
            catch { message = error.localizedDescription }
        }
    }

    private func acceptHost() {
        guard let scan else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await SSHTrust.accept(scan); self.scan = nil; message = "Empreinte SSH enregistrée." }
            catch { message = error.localizedDescription }
        }
    }
}
