import Foundation

enum RadioStation: String, CaseIterable, Identifiable {
    case nova, franceinfo, phenix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nova: return "Radio Nova"
        case .franceinfo: return "franceinfo"
        case .phenix: return "Radio Phénix"
        }
    }
}

enum RadioCommand: Equatable {
    case play(RadioStation)
    case stop

    static func parse(_ question: String) -> RadioCommand? {
        var text = question.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        for prefix in ["s il te plait ", "stp "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        for suffix in [" s il te plait", " stp"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        for prefix in ["est ce que tu peux ", "pourrais tu ", "peux tu ", "tu peux "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        if text.range(of: #"^(arrete|arreter|coupe|couper|stop|stoppe|stopper|eteins|eteindre)( la)? radio$"#,
                      options: .regularExpression) != nil {
            return .stop
        }
        if let action = text.range(of: #"^(mets|met|mettre|lance|lancer|joue|jouer|ecoute|ecouter|allume|allumer|demarre|demarrer|passe|passer)( moi)? (la |de la )?"#,
                                   options: .regularExpression) {
            text.removeSubrange(action)
        }
        switch text {
        case "nova", "radio nova": return .play(.nova)
        case "franceinfo", "france info", "radio franceinfo", "radio france info": return .play(.franceinfo)
        case "phenix", "phoenix", "radio phenix", "radio phoenix": return .play(.phenix)
        default: return nil
        }
    }
}
