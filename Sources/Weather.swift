import Foundation

enum WeatherService {
    struct Query: Codable {
        let location: String
        var countryCode: String? = nil
        var dayOffset: Int? = nil

        enum CodingKeys: String, CodingKey {
            case location, countryCode = "country_code", dayOffset = "day_offset"
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Geocoding: Decodable { let results: [Place]? }
    private struct Place: Decodable {
        let name: String
        let latitude, longitude: Double
        let country, country_code, admin1: String?
        let population: Int?

        var label: String {
            [name, admin1, country].compactMap { $0 }.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }.joined(separator: ", ")
        }
    }

    private struct Forecast: Decodable {
        let timezone: String
        let current: Current?
        let current_units: CurrentUnits?
        let daily: Daily?
        let daily_units: DailyUnits?
    }
    private struct Current: Decodable {
        let time, temperature_2m, apparent_temperature, wind_speed_10m: Double
        let weather_code: Int?
    }
    private struct CurrentUnits: Decodable {
        let time, temperature_2m, apparent_temperature, wind_speed_10m: String
    }
    private struct Daily: Decodable {
        let time: [Double]
        let temperature_2m_min, temperature_2m_max, precipitation_probability_max: [Double?]
        let weather_code: [Int?]
    }
    private struct DailyUnits: Decodable {
        let time, temperature_2m_min, temperature_2m_max, precipitation_probability_max: String
    }

    static func answer(_ query: Query, session: URLSession = .shared, now: Date = Date()) async throws -> String {
        let location = query.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = query.countryCode?.uppercased()
        guard (2...120).contains(location.count), location.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
              !location.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              country == nil || (country!.utf8.count == 2 && country!.utf8.allSatisfy({ (65...90).contains($0) })),
              query.dayOffset == nil || (0...6).contains(query.dayOffset!) else {
            throw Failure(message: "Précise une ville et, pour une prévision, un jour parmi aujourd’hui et les six prochains jours.")
        }
        var parameters = [URLQueryItem(name: "name", value: location), URLQueryItem(name: "count", value: "5"),
                          URLQueryItem(name: "language", value: "fr"), URLQueryItem(name: "format", value: "json")]
        if let country { parameters.append(URLQueryItem(name: "countryCode", value: country)) }
        let geocoding: Geocoding = try await load("https://geocoding-api.open-meteo.com/v1/search", parameters, session)
        let places = geocoding.results ?? []
        guard places.count <= 5, places.allSatisfy({
            (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) &&
            !$0.name.isEmpty && $0.label.count <= 300 &&
            !$0.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            (country == nil || $0.country_code == country)
        }) else { throw invalidData() }
        guard !places.isEmpty else {
            return "Je ne trouve pas ce lieu. Peux-tu préciser la ville, le pays ou la région ?"
        }
        let name = normalized(location.components(separatedBy: ",")[0])
        let exact = places.filter { normalized($0.name) == name }
        let candidates = exact.isEmpty ? [places[0]] : exact
        let place = candidates[0]
        // shortcut: ranking and a tenfold population lead resolve famous homonyms; ask for the region otherwise.
        let ambiguous = candidates.dropFirst().contains {
            (abs(place.latitude - $0.latitude) > 0.1 || abs(place.longitude - $0.longitude) > 0.1) &&
            Double(place.population ?? 0) < 10 * Double(max(1, $0.population ?? 0))
        }
        if ambiguous {
            return "Plusieurs lieux portent ce nom : " + candidates.prefix(3).map(\.label).joined(separator: " ; ") +
                ". Lequel veux-tu, ou dans quel pays et quelle région ?"
        }
        parameters = [URLQueryItem(name: "latitude", value: String(place.latitude)),
                      URLQueryItem(name: "longitude", value: String(place.longitude)),
                      URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "timeformat", value: "unixtime"),
                      URLQueryItem(name: "temperature_unit", value: "celsius"), URLQueryItem(name: "wind_speed_unit", value: "kmh")]
        if query.dayOffset == nil {
            parameters.append(URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"))
        } else {
            parameters += [URLQueryItem(name: "forecast_days", value: "7"),
                           URLQueryItem(name: "daily", value: "weather_code,temperature_2m_min,temperature_2m_max,precipitation_probability_max")]
        }
        let forecast: Forecast = try await load("https://api.open-meteo.com/v1/forecast", parameters, session)
        guard let zone = TimeZone(identifier: forecast.timezone) else { throw invalidData() }
        let numbers = NumberFormatter()
        numbers.locale = Locale(identifier: "fr_FR")
        numbers.maximumFractionDigits = 1
        numbers.usesGroupingSeparator = false
        func number(_ value: Double) -> String { numbers.string(from: NSNumber(value: value))! }
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "fr_FR")
        dateFormat.timeZone = zone
        if let offset = query.dayOffset {
            guard let daily = forecast.daily, let units = forecast.daily_units,
                  units.time == "unixtime", units.temperature_2m_min == "°C", units.temperature_2m_max == "°C",
                  units.precipitation_probability_max == "%", daily.time.count == 7,
                  daily.temperature_2m_min.count == 7, daily.temperature_2m_max.count == 7,
                  daily.precipitation_probability_max.count == 7, daily.weather_code.count == 7 else { throw invalidData() }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let today = calendar.startOfDay(for: now)
            guard daily.time[0].isFinite, abs(daily.time[0] - today.timeIntervalSince1970) <= 3600,
                  calendar.isDate(Date(timeIntervalSince1970: daily.time[0]), inSameDayAs: now) else { throw invalidData() }
            let target = calendar.date(byAdding: .day, value: offset, to: today)!
            guard let index = daily.time.firstIndex(where: {
                $0.isFinite && abs($0 - target.timeIntervalSince1970) <= 48 * 3600 &&
                    calendar.isDate(Date(timeIntervalSince1970: $0), inSameDayAs: target)
            }),
                  let minimum = daily.temperature_2m_min[index], let maximum = daily.temperature_2m_max[index],
                  validTemperature(minimum), validTemperature(maximum), minimum <= maximum else { throw invalidData() }
            let rain: String
            if let probability = daily.precipitation_probability_max[index] {
                guard probability.isFinite, (0...100).contains(probability) else { throw invalidData() }
                rain = "La probabilité maximale de précipitations est de \(number(probability)) pour cent."
            } else { rain = "La probabilité de précipitations n’est pas disponible." }
            dateFormat.dateFormat = "EEEE d MMMM"
            return "Selon Open-Meteo, à \(place.label), la prévision pour \(dateFormat.string(from: target)) est : \(condition(daily.weather_code[index])), avec des températures entre \(number(minimum)) et \(number(maximum)) degrés. \(rain)"
        }
        guard let current = forecast.current, let units = forecast.current_units,
              units.time == "unixtime", units.temperature_2m == "°C", units.apparent_temperature == "°C", units.wind_speed_10m == "km/h",
              current.time.isFinite, validTemperature(current.temperature_2m), validTemperature(current.apparent_temperature),
              current.wind_speed_10m.isFinite, (0...1000).contains(current.wind_speed_10m) else { throw invalidData() }
        let timestamp = Date(timeIntervalSince1970: current.time)
        guard now.timeIntervalSince(timestamp) <= 3 * 3600, timestamp.timeIntervalSince(now) <= 3600 else {
            throw Failure(message: "Les données météo reçues ne sont pas assez récentes. Réessaie dans un instant.")
        }
        dateFormat.dateFormat = "HH'h'mm"
        return "Selon Open-Meteo, à \(place.label), à \(dateFormat.string(from: timestamp)) heure locale, les conditions estimées sont : \(condition(current.weather_code)), \(number(current.temperature_2m)) degrés, avec un ressenti de \(number(current.apparent_temperature)) degrés. Le vent est de \(number(current.wind_speed_10m)) kilomètres par heure."
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func validTemperature(_ value: Double) -> Bool { value.isFinite && (-150...100).contains(value) }
    private static func invalidData() -> Failure { Failure(message: "Les données météo reçues sont incomplètes ou invalides. Réessaie dans un instant.") }

    private static func load<T: Decodable>(_ endpoint: String, _ parameters: [URLQueryItem], _ session: URLSession) async throws -> T {
        var url = URLComponents(string: endpoint)!
        url.queryItems = parameters
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request, delegate: RemoteAI.RedirectBlocker())
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(message: "Le service météo est momentanément indisponible. Réessaie dans un instant.")
            }
            // shortcut: the fixed weather hosts are trusted; use streaming for a hard download cap if that changes.
            guard data.count <= 64 * 1024 else { throw invalidData() }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw invalidData() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure(message: "Je n’arrive pas à joindre le service météo. Réessaie dans un instant.")
        }
    }

    private static func condition(_ code: Int?) -> String {
        switch code {
        case 0: return "ciel dégagé"
        case 1: return "ciel plutôt dégagé"
        case 2: return "ciel partiellement nuageux"
        case 3: return "ciel couvert"
        case 45, 48: return "brouillard"
        case 51: return "bruine légère"
        case 53: return "bruine modérée"
        case 55: return "bruine dense"
        case 56, 57: return "bruine verglaçante"
        case 61: return "pluie faible"
        case 63: return "pluie modérée"
        case 65: return "forte pluie"
        case 66, 67: return "pluie verglaçante"
        case 71: return "neige faible"
        case 73: return "neige modérée"
        case 75: return "fortes chutes de neige"
        case 77: return "neige en grains"
        case 80, 81, 82: return "averses de pluie"
        case 85, 86: return "averses de neige"
        case 95: return "orage"
        case 97: return "orage violent"
        case 96, 99: return "orage avec grêle"
        default: return "conditions non précisées"
        }
    }
}
