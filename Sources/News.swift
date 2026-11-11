import Foundation

enum NewsService {
    enum Category: String, Codable, CaseIterable {
        case france, international, technology, all

        var label: String {
            switch self {
            case .france: return "France"
            case .international: return "International"
            case .technology: return "Haute technologie"
            case .all: return "Actualités"
            }
        }

        var feed: (url: String, source: String) {
            switch self {
            case .france: return ("https://www.france24.com/fr/france/rss", "France 24")
            case .international: return ("https://www.lemonde.fr/international/rss_full.xml", "Le Monde")
            case .technology: return ("https://www.lemonde.fr/technologies/rss_full.xml", "Le Monde")
            case .all: preconditionFailure("Un bulletin général consulte chaque rubrique.")
            }
        }
    }

    struct Query: Codable { let category: Category }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func answer(_ query: Query, session: URLSession = .shared, now: Date = Date()) async throws -> String {
        let categories: [Category] = query.category == .all ? [.france, .international, .technology] : [query.category]
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "fr_FR")
        dates.timeZone = .current
        dates.dateFormat = "d MMMM 'à' HH'h'mm"
        var sections = [String]()
        for category in categories {
            try Task.checkCancellation()
            do {
                let items = try await load(category, session: session)
                    .filter { (-300...72 * 3600).contains(now.timeIntervalSince($0.date)) }
                    .sorted { $0.date > $1.date }
                var seen = Set<String>()
                let latest = items.filter { seen.insert($0.title.lowercased()).inserted }.prefix(query.category == .all ? 1 : 3)
                let heading = "\(category.label), selon \(category.feed.source) : "
                if latest.isEmpty {
                    sections.append(heading + "aucun titre daté de moins de 72 heures n’est disponible.")
                } else {
                    sections.append(heading + latest.map { "Le \(dates.string(from: $0.date)), \($0.title)." }.joined(separator: " "))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard query.category == .all else { throw error }
                sections.append("\(category.label) : le flux de \(category.feed.source) est momentanément indisponible.")
            }
        }
        return "Derniers titres publiés, heures du Mac (\(TimeZone.current.identifier)). " + sections.joined(separator: " ")
    }

    private struct Item { let title: String; let date: Date }

    private static func load(_ category: Category, session: URLSession) async throws -> [Item] {
        var request = URLRequest(url: URL(string: category.feed.url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("NabaztagIA/0.12", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request, delegate: RemoteAI.RedirectBlocker())
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(message: "Le flux d’actualités \(category.label) de \(category.feed.source) est momentanément indisponible.")
            }
            // shortcut: fixed publisher hosts are trusted; use streaming if a hard download cap becomes necessary.
            guard data.count <= 512 * 1024, let xml = String(data: data, encoding: .utf8),
                  xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw invalidData() }
            let feed = FeedParser()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = feed
            guard parser.parse(), feed.hasChannel else { throw invalidData() }
            try Task.checkCancellation()
            return feed.items
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure(message: "Je n’arrive pas à joindre le flux d’actualités \(category.label) de \(category.feed.source). Réessaie dans un instant.")
        }
    }

    private static func invalidData() -> Failure {
        Failure(message: "Le flux d’actualités reçu est incomplet ou invalide. Réessaie dans un instant.")
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        var items = [Item]()
        var hasChannel = false
        private var path = [String]()
        private var title = ""
        private var date = ""
        private let dates: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            formatter.isLenient = false
            return formatter
        }()

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            path.append(elementName)
            if path == ["rss", "channel"] { hasChannel = true }
            if path == ["rss", "channel", "item"] { title = ""; date = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if path == ["rss", "channel", "item", "title"] { title += string }
            if path == ["rss", "channel", "item", "pubDate"] { date += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if path == ["rss", "channel", "item"] {
                var cleaned = title.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
                                        ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
                    cleaned = cleaned.replacingOccurrences(of: entity, with: value)
                }
                cleaned = cleaned
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty, !cleaned.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                   let published = dates.date(from: date.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    let bounded = cleaned.unicodeScalars.count > 240 ? String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(240))) + "…" : cleaned
                    items.append(Item(title: bounded, date: published))
                }
            }
            path.removeLast()
        }
    }
}
