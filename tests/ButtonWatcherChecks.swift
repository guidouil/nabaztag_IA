import Foundation

@main
struct ButtonWatcherChecks {
    @MainActor
    static func main() {
        var parser = ButtonLineParser()
        assert(parser.append(Data("rea".utf8)).isEmpty)
        assert(parser.append(Data("dy\ncli".utf8)) == ["ready"])
        assert(parser.append(Data("ck\nclick\nready\r\n".utf8)) == ["click", "click", "ready"])
        assert(parser.append(Data("unknown\nclick extra\n ready\n".utf8)).isEmpty)
        assert(parser.append(Data(repeating: 120, count: 10000)).isEmpty)
        assert(parser.append(Data("click\nready\nclick\n".utf8)) == ["ready", "click"])
        assert(parser.append(Data([0xff, 10])).isEmpty)
        let watcher = ButtonWatcher()
        watcher.stop()
        watcher.stop()
        assert(watcher.status == "Bouton du lapin déconnecté")
        print("Tests ButtonWatcher : OK (lignes fragmentées, groupées, invalides, limite mémoire, arrêt).")
    }
}
