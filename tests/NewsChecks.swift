import Foundation

private final class NewsFixture: URLProtocol {
    static var reply: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                              httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct NewsChecks {
    static let now = ISO8601DateFormatter().date(from: "2026-11-11T21:00:00Z")!
    static func item(_ title: String, date: String = "Wed, 11 Nov 2026 20:00:00 GMT") -> String {
        "<item><title>\(title)</title><link>https://example.invalid/not-fetched</link><pubDate>\(date)</pubDate></item>"
    }
    static func feed(_ items: String) -> Data { Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss version=\"2.0\"><channel><title>Ce titre de flux ne doit pas être lu</title>\(items)</channel></rss>".utf8) }

    static func result(_ category: NewsService.Category = .france, data: Data = feed(item("Un titre français")),
                       status: Int = 200, failingPath: String? = nil) async throws -> (String, [URLRequest]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewsFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var requests = [URLRequest]()
        NewsFixture.reply = { request in
            requests.append(request)
            assert(request.httpMethod == "GET" && request.timeoutInterval == 15)
            assert(request.url!.scheme == "https" && request.url!.query == nil)
            assert(request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
            assert(!request.httpShouldHandleCookies && request.cachePolicy == .reloadIgnoringLocalCacheData)
            assert(request.value(forHTTPHeaderField: "User-Agent") == "NabaztagIA/0.12")
            return (request.url!.path == failingPath ? 503 : status, data)
        }
        return (try await NewsService.answer(.init(category: category), session: session, now: now), requests)
    }

    static func fails(_ operation: () async throws -> Void) async {
        do { try await operation(); assertionFailure("Un flux invalide doit être refusé.") }
        catch { assert(error is NewsService.Failure, String(describing: error)) }
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            for category in [NewsService.Category.france, .international, .technology, .all] {
                print(try await NewsService.answer(.init(category: category)))
            }
            return
        }
        let query = try JSONDecoder().decode(NewsService.Query.self, from: Data(#"{"tool":"news","category":"technology"}"#.utf8))
        assert(query.category == .technology)
        do {
            _ = try JSONDecoder().decode(NewsService.Query.self, from: Data(#"{"category":"sports"}"#.utf8))
            assertionFailure("Une catégorie inconnue doit être refusée.")
        } catch {}
        let (france, requests) = try await result()
        assert(france.contains("France, selon France 24") && france.contains("Un titre français"))
        assert(france.contains("11 novembre") && france.contains(TimeZone.current.identifier))
        assert(!france.contains("Ce titre de flux") && !france.contains("not-fetched") && requests.count == 1)
        assert(requests[0].url!.absoluteString == "https://www.france24.com/fr/france/rss")
        let (world, worldRequests) = try await result(.international)
        assert(world.contains("International, selon Le Monde") && worldRequests[0].url!.path == "/international/rss_full.xml")
        let (tech, techRequests) = try await result(.technology)
        assert(tech.contains("Haute technologie, selon Le Monde") && techRequests[0].url!.path == "/technologies/rss_full.xml")

        let unordered = feed(item("Deuxième", date: "Wed, 11 Nov 2026 19:00:00 GMT") +
            item("Premier &amp; récent", date: "Wed, 11 Nov 2026 21:30:00 +0100") +
            item("Deuxième", date: "Wed, 11 Nov 2026 18:00:00 GMT") +
            item("Troisième", date: "Tue, 10 Nov 2026 20:00:00 GMT") +
            item("Quatrième", date: "Mon, 09 Nov 2026 20:00:00 GMT"))
        let (sorted, _) = try await result(data: unordered)
        assert(sorted.range(of: "Premier & récent")!.lowerBound < sorted.range(of: "Deuxième")!.lowerBound)
        assert(sorted.range(of: "Deuxième")!.lowerBound < sorted.range(of: "Troisième")!.lowerBound)
        assert(sorted.components(separatedBy: "Deuxième").count == 2 && !sorted.contains("Quatrième"))
        let oldAndInvalid = feed(item("Périmé", date: "Sun, 08 Nov 2026 20:59:59 GMT") +
            item("Futur", date: "Wed, 11 Nov 2026 21:05:01 GMT") + item("Date absente", date: "") +
            item("Date invalide", date: "not-a-date") + item(""))
        let (empty, _) = try await result(data: oldAndInvalid)
        assert(empty.contains("aucun titre daté de moins de 72 heures") && !empty.contains("Périmé") && !empty.contains("Futur"))
        let (boundary, _) = try await result(data: feed(item("Limite 72h", date: "Sun, 08 Nov 2026 21:00:00 GMT")))
        assert(boundary.contains("Limite 72h"))
        let (cdata, _) = try await result(data: feed(item("<![CDATA[Une <b>nouvelle</b>\n française &amp; internationale]]>")))
        assert(cdata.contains("Une nouvelle française & internationale") && !cdata.contains("<b>"))

        let (all, allRequests) = try await result(.all, data: unordered)
        assert(allRequests.count == 3 && all.components(separatedBy: "Premier & récent").count == 4)
        assert(!all.contains("Deuxième") && all.contains("France 24") && all.contains("Le Monde"))
        let (partial, partialRequests) = try await result(.all, failingPath: "/international/rss_full.xml")
        assert(partialRequests.count == 3 && partial.contains("International : le flux de Le Monde est momentanément indisponible"))
        assert(partial.contains("France, selon France 24") && partial.contains("Haute technologie, selon Le Monde"))
        let longTitle = String(repeating: "e\u{301}", count: 500)
        for category in [NewsService.Category.france, .all] {
            let (long, _) = try await result(category, data: feed(item(longTitle) + item(longTitle + "bis") + item(longTitle + "ter")))
            assert(long.unicodeScalars.count < 1800 && long.contains("…"))
        }
        await fails { _ = try await result(status: 503) }
        await fails { _ = try await result(status: 302) }
        await fails { _ = try await result(data: Data("<rss><channel><item>".utf8)) }
        await fails { _ = try await result(data: Data("<html><body>Not RSS</body></html>".utf8)) }
        await fails { _ = try await result(data: Data(repeating: 32, count: 512 * 1024 + 1)) }
        await fails { _ = try await result(data: Data("<!DOCTYPE rss [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><rss><channel/></rss>".utf8)) }
        await fails { _ = try await result(data: Data("<!doctype rss><rss><channel/></rss>".utf8)) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NewsService.answer(.init(category: .all))
        }
        do { _ = try await cancelled.value; assertionFailure("L’annulation doit se propager.") }
        catch { assert(error is CancellationError) }
        print("Tests News : OK (rubriques, sources, dates, tri, dédoublonnage, fraîcheur, XML, erreurs et bulletin partiel). Aucun réseau.")
    }
}
