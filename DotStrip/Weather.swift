//
//  Weather.swift
//  DotStrip
//
//  Current conditions for the weather widget, from Open-Meteo.
//
//  Open-Meteo rather than WeatherKit: WeatherKit needs a paid developer
//  entitlement and a signed token dance, which is a lot of machinery for two
//  numbers in a menu bar. This needs no key and no account.
//
//  Temperature is always requested in Celsius and converted here, so flipping
//  the unit in the menu is instant instead of a round trip.
//

import Foundation
import OSLog

struct Weather: Equatable {
    /// Degrees Celsius, as reported.
    var celsius: Double

    /// Today's forecast range, in Celsius. Optional because a reading is still
    /// worth showing if the daily block is missing.
    var highCelsius: Double?
    var lowCelsius: Double?

    /// WMO weather interpretation code.
    var code: Int

    /// Whether it is daylight where the reading came from. Reported by the
    /// source rather than worked out from the clock here, so it follows the
    /// actual sunrise at that latitude and time of year.
    var isDay: Bool

    var place: String

    private static func degrees(_ celsius: Double, fahrenheit: Bool) -> Int {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return Int(value.rounded())
    }

    func degrees(fahrenheit: Bool) -> Int {
        Self.degrees(celsius, fahrenheit: fahrenheit)
    }

    /// What the weather window shows, one frame at a time.
    ///
    /// The range is a second and third frame rather than more text on the
    /// first: three temperatures side by side would triple the width of the
    /// narrowest window on the board, and those columns come out of the lines
    /// either side of it. The window turns over instead, the way the stock
    /// window does.
    func boardFrames(fahrenheit: Bool, highLow: Bool) -> [String] {
        var frames = ["\(Weather.glyph(for: code, isDay: isDay)) \(degrees(fahrenheit: fahrenheit))\u{00B0}"]

        if highLow, let high = highCelsius, let low = lowCelsius {
            frames.append("\u{25B2} \(Self.degrees(high, fahrenheit: fahrenheit))\u{00B0}")
            frames.append("\u{25BC} \(Self.degrees(low, fahrenheit: fahrenheit))\u{00B0}")
        }
        return frames
    }

    /// Written out for the menu, where there is room for words.
    func summary(fahrenheit: Bool) -> String {
        var text = "\(place)  \(degrees(fahrenheit: fahrenheit))\u{00B0}\(fahrenheit ? "F" : "C")"
        text += "  \(Weather.describe(code))"

        if let high = highCelsius, let low = lowCelsius {
            text += "   High \(Self.degrees(high, fahrenheit: fahrenheit))\u{00B0}"
            text += "  Low \(Self.degrees(low, fahrenheit: fahrenheit))\u{00B0}"
        }
        return text
    }

    /// WMO code groups, collapsed to the handful of glyphs the font draws.
    /// Anything unrecognised falls back to cloud rather than showing the
    /// missing-glyph box.
    ///
    /// Only the two conditions the sun appears in have a night form. Rain at
    /// midnight looks like rain at noon, and inventing a night version of it
    /// would say something the reading does not.
    static func glyph(for code: Int, isDay: Bool = true) -> Character {
        switch code {
        case 0:              return isDay ? "\u{2600}" : "\u{263D}"   // clear
        case 1, 2:           return isDay ? "\u{26C5}" : "\u{E000}"   // partly cloudy
        case 3:              return "\u{2601}"   // overcast
        case 45, 48:         return "\u{2261}"   // fog
        case 51...67, 80...82: return "\u{2602}" // drizzle, rain, showers
        case 71...77, 85, 86:  return "\u{2744}" // snow
        case 95...99:        return "\u{26A1}"   // thunderstorm
        default:             return "\u{2601}"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0:                return "Clear"
        case 1, 2:             return "Partly cloudy"
        case 3:                return "Overcast"
        case 45, 48:           return "Fog"
        case 51...57:          return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86:  return "Snow"
        case 95...99:          return "Thunderstorms"
        default:               return "—"
        }
    }
}

final class WeatherMonitor {

    private(set) var current: Weather?
    private(set) var trouble: String?

    var onChange: (() -> Void)?

    private var reporting: String = Preferences.weatherPlace

    /// The place name to report for. Setting it to a bare name throws away the
    /// cached coordinates and looks the name up again, so it is the route for
    /// a name with nothing behind it; a place the user picked comes in through
    /// `use(_:)` with its coordinates already attached.
    var place: String {
        get { reporting }
        set {
            guard newValue != reporting else { return }
            reporting = newValue
            Preferences.weatherPlace = newValue
            Preferences.weatherDetail = nil
            Preferences.weatherCoordinate = nil
            restart()
        }
    }

    /// Adopts a place the user picked from a list of candidates.
    ///
    /// This is the route that skips geocoding entirely: the coordinates came
    /// back with the choice, so there is no name left to resolve and no chance
    /// of resolving it to the wrong one of two towns. Two places can share a
    /// name, so this refreshes even when the name has not changed.
    func use(_ chosen: GeocodedPlace) {
        reporting = chosen.name
        Preferences.setWeatherLocation(name: chosen.name, detail: chosen.detail,
                                       latitude: chosen.latitude, longitude: chosen.longitude)
        restart()
    }

    /// Drops the reading for the old place and goes after the new one. The
    /// board shows the source's status line in the gap rather than last hour's
    /// temperature under this hour's city.
    private func restart() {
        current = nil
        trouble = nil
        onChange?()
        refresh()
    }

    /// Conditions don't move faster than this, and Open-Meteo itself only
    /// updates on a quarter-hour boundary.
    private let interval: TimeInterval = 15 * 60

    private var timer: Timer?
    private var task: URLSessionDataTask?

    private let log = Logger(subsystem: "com.danielmoreno.projects.DotStrip",
                             category: "weather")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    // MARK: Fetching

    func refresh() {
        guard !place.isEmpty else { return report(trouble: "No location set") }

        if let coordinate = Preferences.weatherCoordinate {
            fetchConditions(at: coordinate)
        } else {
            geocode { [weak self] coordinate in
                guard let self, let coordinate else { return }
                Preferences.weatherCoordinate = coordinate
                self.fetchConditions(at: coordinate)
            }
        }
    }

    // MARK: Geocoding

    /// Resolves a bare name, which at this point means the time zone's guess
    /// at launch: anything the user chose arrived with its coordinates.
    ///
    /// It asks for the whole shortlist rather than one result so it can take
    /// the largest exact match instead of whichever the ranking favoured, and
    /// it writes down which place it settled on. That last part is what lets
    /// the menu say "Paris, Île-de-France, France" — a guess the user can see
    /// is wrong is a guess they can fix.
    private func geocode(then handle: @escaping ((latitude: Double, longitude: Double)?) -> Void) {
        let wanted = place
        PlaceSearch.run(wanted) { [weak self] outcome in
            guard let self, self.place == wanted else { return }
            switch outcome {
            case .success(let places):
                guard let match = PlaceSearch.best(of: places, for: wanted) else {
                    self.report(trouble: "No place called \u{201C}\(wanted)\u{201D}")
                    return handle(nil)
                }
                // Straight to the backing name: this is the answer to the
                // request in flight, not a new one, and going through `place`
                // would throw away the coordinates it just resolved.
                self.reporting = match.name
                Preferences.setWeatherLocation(name: match.name, detail: match.detail,
                                               latitude: match.latitude,
                                               longitude: match.longitude)
                handle((match.latitude, match.longitude))
            case .failure(let failure):
                self.report(trouble: failure.message)
                handle(nil)
            }
        }
    }

    // MARK: Conditions

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature: Double
            let code: Int

            /// 1 by day, 0 by night. Optional so a source that stops sending
            /// it leaves the board in daylight rather than permanent midnight.
            let isDay: Int?

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case code = "weather_code"
                case isDay = "is_day"
            }
        }

        /// Arrays, one entry per forecast day; we ask for one.
        struct Daily: Decodable {
            let high: [Double]
            let low: [Double]

            enum CodingKeys: String, CodingKey {
                case high = "temperature_2m_max"
                case low = "temperature_2m_min"
            }
        }

        let current: Current
        let daily: Daily?
    }

    private func fetchConditions(at coordinate: (latitude: Double, longitude: Double)) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            // Without this the daily block is bucketed by GMT, so "today's
            // high" would roll over at the wrong hour for most of the world.
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { return }

        get(url, as: ForecastResponse.self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                let reading = Weather(celsius: response.current.temperature,
                                      highCelsius: response.daily?.high.first,
                                      lowCelsius: response.daily?.low.first,
                                      code: response.current.code,
                                      isDay: (response.current.isDay ?? 1) != 0,
                                      place: self.place)
                guard reading != self.current || self.trouble != nil else { return }
                self.current = reading
                self.trouble = nil
                self.onChange?()
            case .failure(let failure):
                // Anything already on the board stays: a stale temperature
                // beats a blank zone that changes the layout under the user.
                self.report(trouble: failure.message)
            }
        }
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ url: URL, as type: T.Type,
                                   then handle: @escaping (Result<T, FetchFailure>) -> Void) {
        task?.cancel()
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error as? URLError, error.code == .cancelled { return }

            let outcome: Result<T, FetchFailure>
            if let error {
                outcome = .failure(FetchFailure(message: error.localizedDescription))
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
                outcome = .failure(FetchFailure(message: "Weather service returned HTTP \(code)"))
            } else if let data, let decoded = try? JSONDecoder().decode(T.self, from: data) {
                outcome = .success(decoded)
            } else {
                outcome = .failure(FetchFailure(message: "Unreadable response"))
            }

            DispatchQueue.main.async { handle(outcome) }
        }
        self.task = task
        task.resume()
    }

    private func report(trouble message: String) {
        log.error("\(message, privacy: .public)")
        guard trouble != message else { return }
        trouble = message
        onChange?()
    }
}
