import SwiftUI

struct ConversationEntry: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

func conversationPrompt(history: [ConversationEntry], question: String) -> String {
    let context = history.suffix(6).map {
        "Utilisateur : \($0.question)\nAssistant : \($0.answer)"
    }.joined(separator: "\n\n")
    return """
    Tu es l'assistant vocal d'un Nabaztag. Réponds en français, naturellement, en une à trois phrases.
    Date et heure actuelles : \(Date().ISO8601Format()), fuseau du Mac : \(TimeZone.current.identifier).
    Sois exact et signale une incertitude si nécessaire. N'exécute aucune commande ni aucun outil externe.
    Pour les questions ordinaires, réponds uniquement par du texte à lire à voix haute.
    Tu disposes d'un service météo géré par l'application. Pour toute demande de météo actuelle ou de prévisions,
    y compris la pluie, la température ou une suite comme « et demain ? », ne devine aucune donnée météo.
    Réponds exclusivement par ce JSON, sans autre texte ni bloc de code :
    {"tool":"weather","location":"ville ou ville, région","country_code":null,"day_offset":null}
    location est le lieu demandé, ou celui clairement établi dans la conversation. country_code est un code ISO
    à deux lettres si le pays est connu avec confiance, sinon null (sans guillemets). Ne fournis jamais d'URL ni de coordonnées.
    day_offset vaut null pour maintenant, 0 pour les prévisions d'aujourd'hui, 1 pour demain, jusqu'à 6 pour le sixième jour,
    toujours selon la date locale de la ville. Le service ne fournit ni historique ni prévisions au-delà de six jours : explique cette limite si besoin.
    Si le lieu manque, si « ici » n'est pas établi, ou si une ville est ambiguë, demande la ville, le pays ou la région en texte normal.
    N'affirme pas que tu ne peux pas consulter la météo : l'application exécutera cette demande et fournira les données.
    Tu disposes aussi d'un service d'actualités récentes géré par l'application. Pour demander les dernières infos,
    un journal ou bulletin d'actualité, y compris une suite comme « et en France ? », n'utilise jamais ta mémoire.
    Réponds exclusivement par ce JSON, sans autre texte ni bloc de code :
    {"tool":"news","category":"all"}
    category vaut "france" pour la France, "international" pour le monde, "technology" pour la haute technologie,
    la tech ou le numérique, et "all" pour un bulletin général ou plusieurs catégories.
    L'application récupère et lit les titres récents avec leur source et leur date. Ne fournis jamais d'URL.
    Il s'agit de titres de presse, pas d'articles complets ni d'une recherche par sujet. Pour une demande de détails
    absents des titres déjà fournis, explique cette limite et n'invente aucune information récente.
    N'affirme pas que tu ne peux pas consulter les actualités : l'application exécutera cette demande.

    \(context)

    Utilisateur : \(question)
    Assistant :
    """
}

func checkConversationPrompt() {
    let history = (0..<8).map {
        ConversationEntry(question: "question-\($0)-fin", answer: "réponse-\($0)-fin")
    }
    let prompt = conversationPrompt(history: history, question: "nouvelle-question")
    assert(!prompt.contains("question-0-fin") && !prompt.contains("question-1-fin"))
    assert(prompt.contains("question-2-fin") && prompt.contains("réponse-7-fin"))
    assert(prompt.contains("nouvelle-question"))
    assert(prompt.contains("\"tool\":\"weather\"") && prompt.contains("day_offset"))
    assert(prompt.contains("\"tool\":\"news\"") && prompt.contains("\"technology\"") && prompt.contains("\"international\""))
}

@main
struct NabaztagApp: App {
    init() {
        if CommandLine.arguments.contains("--self-test") {
            checkConversationPrompt()
            print("Tests contexte conversation : OK.")
            exit(0)
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        Window("Nabaztag IA", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 540)
        }
        .defaultSize(width: 740, height: 650)
    }
}

@MainActor
private struct ContentView: View {
    @State private var draft = ""
    @State private var speechDraft = ""
    @State private var history: [ConversationEntry] = []
    @State private var pendingQuestion = ""
    @State private var diagnostic = ""
    @State private var status = "Prêt"
    @State private var error: String?
    @State private var busy = false
    @StateObject private var buttonWatcher = ButtonWatcher()
    @State private var configuration = AppConfiguration.load()
    @State private var showingSettings = false
    @State private var showingConversation = false
    @State private var operationTask: Task<Void, Never>?
    @State private var recording: Bridge.RemoteSession?
    @State private var thinkingForward = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nabaztag IA").font(.title.bold())
                Spacer()
                Text(configuration.ssh.host).foregroundStyle(.secondary).monospaced()
                Button("Réglages", systemImage: "gearshape") { showingSettings = true }.disabled(busy)
            }

            Text("Micro et haut-parleur du lapin · Transcription locale sur le Mac")
                .font(.subheadline).foregroundStyle(.secondary)

            Picker("Intelligence artificielle", selection: providerBinding) {
                ForEach(AIProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }
            .disabled(busy)

            HStack {
                Button("Vérifier") {
                    run("Vérification…") {
                        diagnostic = try await Bridge.diagnostic()
                        status = "Vérification terminée"
                    }
                }
                .disabled(busy)
                Button("Tester la voix") {
                    run("Préparation et lecture du message de test…") {
                        try await Bridge.speak("Bonjour, je suis ton Nabaztag. Voici un aperçu de ma voix française, entièrement générée sur ton Mac.")
                        status = "Test de la voix terminé"
                    }
                }
                .disabled(busy)
                Spacer()
                Button(recording == nil ? "Parler" : "Arrêter l’enregistrement", systemImage: recording == nil ? "mic.fill" : "stop.fill") {
                    listen()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy && recording == nil)
            }

            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.callout)
            }
            .accessibilityElement(children: .combine)

            HStack {
                Text(buttonWatcher.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reconnecter le bouton") {
                    buttonWatcher.start(onClick: listen)
                }
                .disabled(busy)
            }

            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }

            if !diagnostic.isEmpty {
                DisclosureGroup("Diagnostic") {
                    ScrollView { Text(diagnostic)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled) }
                        .frame(maxHeight: 160)
                }
            }

            Divider()

            DisclosureGroup(showingConversation ? "Conversation" : "Afficher la conversation", isExpanded: $showingConversation) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if history.isEmpty && pendingQuestion.isEmpty {
                                Text("Fais un clic court sur le bouton du lapin ou clique sur Parler. Attends le bip, puis pose ta question près de lui.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(history) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Vous : \(entry.question)").fontWeight(.medium)
                                    Text("Nabaztag : \(entry.answer)")
                                    if entry.answer.contains("Open-Meteo") {
                                        HStack(spacing: 8) {
                                            Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                                            Link("GeoNames", destination: URL(string: "https://www.geonames.org/")!)
                                            Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                            if !pendingQuestion.isEmpty {
                                Text("Vous : \(pendingQuestion)").fontWeight(.medium)
                            }
                            Color.clear.frame(height: 1).id("fin")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }
                    .onAppear { proxy.scrollTo("fin", anchor: .bottom) }
                    .onChange(of: history.count) { _, _ in proxy.scrollTo("fin", anchor: .bottom) }
                    .onChange(of: pendingQuestion) { _, _ in proxy.scrollTo("fin", anchor: .bottom) }
                }
            }

            HStack(alignment: .bottom) {
                TextField("Écrire une question", text: $draft, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                Button("Envoyer") {
                    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    run("Préparation de la réponse…") {
                        try await respond(to: question)
                        draft = ""
                    }
                }
                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Après le bip, parle puis rappuie sur le bouton du lapin ou sur Arrêter l’enregistrement. Arrêt de sécurité à 90 secondes. Les 6 derniers échanges sont envoyés au fournisseur choisi ; l’audio est traité localement.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Faire dire au lapin").font(.headline)
                    Text("Lecture directe · sans IA").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom) {
                    TextField("Texte à lire à voix haute", text: $speechDraft, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                    Button("Lire", systemImage: "speaker.wave.2.fill") {
                        let text = speechDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        run("Préparation de la voix et lecture sur le Nabaztag…") {
                            try await Bridge.speak(text)
                            status = "Prêt"
                        }
                    }
                    .disabled(busy || speechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            buttonWatcher.start(onClick: listen)
            if configuration.selectedVoiceEngine == .kokoro { LocalVoice.prewarm() }
        }
        .onChange(of: configuration.selectedVoiceEngine) { _, engine in
            if engine == .kokoro { LocalVoice.prewarm() } else { LocalVoice.shutdown() }
        }
        .onDisappear {
            operationTask?.cancel()
            recording?.cancel()
            buttonWatcher.stop()
            StreamPlayback.cancelActive()
            LocalVoice.shutdown()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            operationTask?.cancel()
            recording?.cancel()
            buttonWatcher.stop()
            StreamPlayback.cancelActive()
            LocalVoice.shutdown()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(configuration: configuration) { updated in
                if configuration.provider != updated.provider || configuration.options(for: configuration.provider) != updated.options(for: updated.provider) { history = [] }
                configuration = updated
                error = nil
                buttonWatcher.start(onClick: listen)
            }
        }
    }

    private var providerBinding: Binding<AIProvider> {
        Binding(get: { configuration.provider }, set: { provider in
            var updated = configuration
            updated.provider = provider
            do {
                try updated.save()
                configuration = updated
                history = []
                error = nil
            } catch { self.error = error.localizedDescription }
        })
    }

    private func listen() {
        guard !showingSettings else { return }
        if let recording {
            recording.stop()
            status = "Fin de l’enregistrement…"
            return
        }
        guard !busy else { return }
        let session = Bridge.RemoteSession()
        recording = session
        run("Préparation du micro… attends le bip, puis parle et rappuie pour arrêter.") {
            defer { recording = nil; session.cancel() }
            let question = try await Bridge.listen(session: session) {
                recording = nil
                status = "Transcription locale…"
            }
            try await respond(to: question)
        }
    }

    private func run(_ initialStatus: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        status = initialStatus
        operationTask = Task { @MainActor in
            defer { busy = false; operationTask = nil }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch {
                self.error = error.localizedDescription
                status = "Opération interrompue"
            }
        }
    }

    private func respond(to question: String) async throws {
        pendingQuestion = question
        defer { pendingQuestion = "" }
        status = "Réponse de l'agent IA…"
        let direction = thinkingForward ? "forward" : "backward"
        thinkingForward.toggle()
        let answer = try await Bridge.askWhileThinking(conversationPrompt(history: history, question: question), direction: direction)
        try Task.checkCancellation()
        history.append(ConversationEntry(question: question, answer: answer))
        status = "Préparation de la voix et lecture sur le Nabaztag…"
        try await Bridge.speak(answer)
        status = "Prêt"
    }
}
