import Foundation

private final class WeatherFixture: URLProtocol {
    static var reply: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                              httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct WeatherChecks {
    static let now = ISO8601DateFormatter().date(from: "2026-11-11T02:00:00Z")!
    static let newYork: [String: Any] = ["name": "New York", "latitude": 40.71427, "longitude": -74.00597,
        "country": "États-Unis", "country_code": "US", "admin1": "État de New York", "population": 8804190]

    static func forecast(zone: String = "America/New_York", at date: Date = now) -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let today = calendar.startOfDay(for: date)
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: today)!.timeIntervalSince1970 }
        return ["timezone": zone,
            "current_units": ["time": "unixtime", "temperature_2m": "°C", "apparent_temperature": "°C", "wind_speed_10m": "km/h"],
            "current": ["time": date.timeIntervalSince1970 - 900, "temperature_2m": 6.2,
                        "apparent_temperature": 3.8, "wind_speed_10m": 14.4, "weather_code": 3],
            "daily_units": ["time": "unixtime", "temperature_2m_min": "°C", "temperature_2m_max": "°C", "precipitation_probability_max": "%"],
            "daily": ["time": days, "temperature_2m_min": Array(repeating: 3.0, count: 7),
                      "temperature_2m_max": Array(repeating: 12.0, count: 7), "weather_code": Array(repeating: 61, count: 7),
                      "precipitation_probability_max": Array(repeating: 80, count: 7)]]
    }

    static func values(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    }

    static func result(_ query: WeatherService.Query = .init(location: "New York", countryCode: "US"),
                       places: [[String: Any]] = [newYork], data: [String: Any] = forecast(), status: Int = 200,
                       at date: Date = now) async throws -> (String, [URLRequest]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var requests = [URLRequest]()
        WeatherFixture.reply = { request in
            requests.append(request)
            assert(request.httpMethod == "GET" && request.timeoutInterval == 15)
            assert(request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies)
            let object: [String: Any]
            if request.url!.host == "geocoding-api.open-meteo.com" { object = ["results": places] }
            else { assert(request.url!.host == "api.open-meteo.com"); object = data }
            return (status, try JSONSerialization.data(withJSONObject: object))
        }
        let answer = try await WeatherService.answer(query, session: session, now: date)
        return (answer, requests)
    }

    static func fails(_ operation: () async throws -> Void) async {
        do { try await operation(); assertionFailure("La météo invalide doit être refusée.") }
        catch { assert(error is WeatherService.Failure, String(describing: error)) }
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            for (location, code) in [("New York", "US"), ("Tokyo", "JP"), ("Sydney", "AU")] {
                print(try await WeatherService.answer(.init(location: location, countryCode: code)))
                print(try await WeatherService.answer(.init(location: location, countryCode: code, dayOffset: 1)))
            }
            return
        }
        let query = try JSONDecoder().decode(WeatherService.Query.self,
            from: Data(#"{"tool":"weather","location":"New York","country_code":"US","day_offset":null}"#.utf8))
        assert(query.location == "New York" && query.countryCode == "US" && query.dayOffset == nil)
        let (answer, requests) = try await result(query)
        assert(answer.contains("Selon Open-Meteo") && answer.contains("États-Unis") && answer.contains("20h45"))
        assert(answer.contains("ciel couvert") && answer.contains("6,2 degrés") && answer.contains("3,8 degrés"))
        assert(answer.contains("14,4 kilomètres par heure") && answer.contains("estimées"))
        assert(requests.count == 2)
        assert(values(requests[0]) == ["name": "New York", "count": "5", "language": "fr", "format": "json", "countryCode": "US"])
        let weatherRequest = values(requests[1])
        assert(weatherRequest["latitude"] == "40.71427" && weatherRequest["longitude"] == "-74.00597")
        assert(weatherRequest["timezone"] == "auto" && weatherRequest["timeformat"] == "unixtime")
        assert(weatherRequest["temperature_unit"] == "celsius" && weatherRequest["wind_speed_unit"] == "kmh")
        assert(weatherRequest["current"] == "temperature_2m,apparent_temperature,weather_code,wind_speed_10m")

        let (daily, dailyRequests) = try await result(.init(location: "New York", dayOffset: 1))
        assert(daily.contains("mercredi 11 novembre") && daily.contains("pluie faible"))
        assert(daily.contains("entre 3 et 12 degrés") && daily.contains("80 pour cent"))
        assert(values(dailyRequests[1])["forecast_days"] == "7" && values(dailyRequests[1])["current"] == nil)
        let (today, _) = try await result(.init(location: "New York", dayOffset: 0))
        assert(today.contains("mardi 10 novembre"), "Le jour doit être celui de New York, pas celui du Mac ou de l'UTC.")
        let (sixDays, _) = try await result(.init(location: "Tokyo", dayOffset: 6), data: forecast(zone: "Asia/Tokyo"))
        assert(sixDays.contains("mardi 17 novembre"))
        let beforeDST = ISO8601DateFormatter().date(from: "2026-10-31T20:00:00Z")!
        let dstForecast = forecast(at: beforeDST)
        let dstTimes = (dstForecast["daily"] as! [String: Any])["time"] as! [Double]
        assert(dstTimes[2] - dstTimes[1] == 25 * 3600)
        let (dstDay, _) = try await result(.init(location: "New York", dayOffset: 2), data: dstForecast, at: beforeDST)
        assert(dstDay.contains("lundi 2 novembre"))

        let (notFound, noForecast) = try await result(places: [])
        assert(notFound.contains("ne trouve pas") && noForecast.count == 1)
        var springfield = newYork
        springfield.merge(["name": "Springfield", "admin1": "Illinois", "latitude": 39.78, "population": 114000]) { _, new in new }
        var second = springfield
        second.merge(["admin1": "Massachusetts", "longitude": -72.59, "population": 155000]) { _, new in new }
        let (ambiguous, ambiguousRequests) = try await result(.init(location: "Springfield", countryCode: "US"), places: [springfield, second])
        assert(ambiguous.contains("Plusieurs lieux") && ambiguous.contains("Illinois") && ambiguous.contains("Massachusetts"))
        assert(ambiguousRequests.count == 1)
        second["name"] = "York"; second["population"] = 20000000
        let (synonym, _) = try await result(places: [newYork, second])
        assert(synonym.contains("à New York"), "Un synonyme sans le même nom ne crée pas une ambiguïté.")
        second["name"] = "New York"; second["population"] = 300
        let (dominant, _) = try await result(places: [newYork, second])
        assert(dominant.contains("conditions estimées"))

        await fails { _ = try await result(.init(location: "", countryCode: "US")) }
        await fails { _ = try await result(.init(location: "New\nYork")) }
        await fails { _ = try await result(.init(location: ",,")) }
        await fails { _ = try await result(.init(location: "New York", countryCode: "USA")) }
        await fails { _ = try await result(.init(location: "New York", dayOffset: -1)) }
        await fails { _ = try await result(.init(location: "New York", dayOffset: 7)) }
        await fails { _ = try await result(status: 503) }
        await fails { _ = try await result(status: 302) }
        var badPlace = newYork; badPlace["latitude"] = 91.0
        await fails { _ = try await result(places: [badPlace]) }
        badPlace = newYork; badPlace["latitude"] = "NaN"
        await fails { _ = try await result(places: [badPlace]) }
        var bad = forecast(); var current = bad["current"] as! [String: Any]
        current["time"] = now.timeIntervalSince1970 - 3 * 3600 - 1; bad["current"] = current
        await fails { _ = try await result(data: bad) }
        current["time"] = now.timeIntervalSince1970 + 3601; bad["current"] = current
        await fails { _ = try await result(data: bad) }
        current["time"] = now.timeIntervalSince1970; current["temperature_2m"] = NSNull(); bad["current"] = current
        await fails { _ = try await result(data: bad) }
        bad = forecast(); var units = bad["current_units"] as! [String: String]
        units["temperature_2m"] = "°F"; bad["current_units"] = units
        await fails { _ = try await result(data: bad) }
        bad = forecast(); bad["timezone"] = "Unknown/Timezone"
        await fails { _ = try await result(data: bad) }
        bad = forecast(); current = bad["current"] as! [String: Any]; current["weather_code"] = 500; bad["current"] = current
        let (unknown, _) = try await result(data: bad)
        assert(unknown.contains("conditions non précisées"))
        current["weather_code"] = 97; bad["current"] = current
        let (storm, _) = try await result(data: bad)
        assert(storm.contains("orage violent"))
        bad = forecast(); var days = bad["daily"] as! [String: Any]
        days["temperature_2m_min"] = Array(repeating: NSNull(), count: 7); bad["daily"] = days
        await fails { _ = try await result(.init(location: "New York", dayOffset: 1), data: bad) }
        days = forecast()["daily"] as! [String: Any]
        days["precipitation_probability_max"] = Array(repeating: NSNull(), count: 7); bad["daily"] = days
        let (missingRain, _) = try await result(.init(location: "New York", dayOffset: 1), data: bad)
        assert(missingRain.contains("n’est pas disponible") && !missingRain.contains("0 pour cent"))
        bad = forecast(); days = bad["daily"] as! [String: Any]
        days["time"] = (days["time"] as! [Double]).map { $0 - 86400 }; bad["daily"] = days
        await fails { _ = try await result(.init(location: "New York", dayOffset: 1), data: bad) }
        print("Tests Weather : OK (géocodage, homonymes, unités, heure locale, prévisions, données périmées/nulles, erreurs HTTP). Aucun réseau.")
    }
}
