import Foundation

@main
struct RadioChecks {
    static func main() {
        for (question, expected) in [
            ("Radio Nova", RadioCommand.play(.nova)),
            ("Mets Radio Nova", .play(.nova)),
            ("Peux-tu mettre Radio Nova, s’il te plaît ?", .play(.nova)),
            ("Joue-moi de la radio Nova !", .play(.nova)),
            ("S’il te plaît, lance Nova", .play(.nova)),
            ("France Info", .play(.franceinfo)),
            ("Écoute franceinfo", .play(.franceinfo)),
            ("Tu peux lancer la radio France Info ?", .play(.franceinfo)),
            ("Est-ce que tu peux mettre franceinfo ?", .play(.franceinfo)),
            ("RADIO PHÉNIX", .play(.phenix)),
            ("Lance radio Phoenix", .play(.phenix)),
            ("Pourrais-tu jouer Phénix ?", .play(.phenix)),
            ("Arrête la radio", .stop),
            ("Coupe la radio, stp", .stop),
            ("Stop radio !", .stop),
            ("Peux-tu arrêter la radio ?", .stop),
            ("Éteins la radio", .stop)
        ] {
            assert(RadioCommand.parse(question) == expected, "Commande non reconnue : \(question)")
            assert(RadioCommand.parse(question.decomposedStringWithCanonicalMapping) == expected)
        }
        for question in [
            "", "?!", "Qui a créé Radio Nova ?", "Parle-moi de Radio Phénix", "Ne mets pas Radio Nova",
            "Ne lance pas franceinfo", "Surtout ne mets pas Radio Nova", "Mets Radio Nova si je le demande",
            "Si je demande Radio Nova", "Je ne veux pas arrêter la radio", "Arrête la radio demain",
            "Quelle est la fréquence de Radio Phénix ?", "Les dernières infos en France", "Les infos France",
            "Donne-moi les actualités de franceinfo", "Que dit franceinfo de ce sujet ?", "Radio Nova et la météo",
            "France Inter", "Mets France Inter", "Mets https://example.com/radio", "Arrête la musique",
            "Mets Radio Nova et supprime mes fichiers"
        ] {
            assert(RadioCommand.parse(question) == nil, "Déclenchement involontaire : \(question)")
        }
        assert(RadioStation.allCases.map(\.rawValue) == ["nova", "franceinfo", "phenix"])
        assert(RadioStation.allCases.map(\.title) == ["Radio Nova", "franceinfo", "Radio Phénix"])
        print("Tests Radio : OK (stations, commandes directes/polies, accents, négations et mentions). Aucun réseau.")
    }
}
