//
//  PlaceSearch.swift
//  DotStrip
//
//  Turning a typed place name into somewhere on the globe.
//
//  Open-Meteo's geocoding service, same house as the forecast itself, so the
//  coordinates it hands back are the ones the forecast is happiest with.
//
//  A name on its own is not a location: there are more than thirty Springfields
//  and two dozen Cambridges, and "Paris" is a town in Texas as well as the
//  capital of France. Everything here exists so the choice between them is made
//  by the user looking at a list rather than by whichever one a search happened
//  to rank first.
//

import Foundation

/// A failure worth reporting in the menu, carrying its own wording. Shared by
/// the search and the forecast fetch, which report the same way.
struct FetchFailure: Error {
    let message: String
}

/// One candidate from a search: a place, said precisely enough to tell it from
/// its namesakes.
nonisolated struct GeocodedPlace: Equatable, Decodable {
    let name: String
    let latitude: Double
    let longitude: Double

    /// State or region, and the country. Both optional — the service leaves
    /// admin1 out for city states and small islands.
    let admin1: String?
    let country: String?
    let countryCode: String?

    /// Present for populated places, missing for landmarks and stations. Used
    /// to rank, and shown, because size is what usually tells two same-named
    /// towns apart.
    let population: Int?

    enum CodingKeys: String, CodingKey {
        case name, latitude, longitude, admin1, country, population
        case countryCode = "country_code"
    }

    /// Everything except the name itself: "Texas, United States".
    var detail: String {
        [admin1, country].compactMap { $0 }.joined(separator: ", ")
    }

    /// The full thing, for menus and windows with room for it.
    var label: String {
        detail.isEmpty ? name : "\(name), \(detail)"
    }

    /// Rounded to the arcsecond or so the service reports. Shown in the picker
    /// as the last word on which of two identically named towns this is.
    var coordinates: String {
        let latitudeText = String(format: "%.2f\u{00B0} %@", abs(latitude), latitude < 0 ? "S" : "N")
        let longitudeText = String(format: "%.2f\u{00B0} %@", abs(longitude), longitude < 0 ? "W" : "E")
        return "\(latitudeText)  \(longitudeText)"
    }

    /// Population, said the way a person would: 2.1M, 340k, 900.
    var populationText: String? {
        guard let population, population > 0 else { return nil }
        switch population {
        case 1_000_000...:
            return String(format: "%.1fM people", Double(population) / 1_000_000)
        case 10_000...:
            return "\(population / 1_000)k people"
        default:
            return "\(population) people"
        }
    }

    /// The regional flag, from the two-letter code. Purely to make a list of
    /// near-identical lines scannable — the country is written out as well, so
    /// nothing is lost where the glyph doesn't render.
    var flag: String? {
        guard let code = countryCode, code.count == 2 else { return nil }
        let base: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            guard let value = UnicodeScalar(base + scalar.value - 65) else { return nil }
            flag.unicodeScalars.append(value)
        }
        return flag
    }
}

/// The search response is nothing but its results.
///
/// Decoded on the URL session's own queue, so it stays off the main actor the
/// project otherwise defaults to.
private nonisolated struct SearchResponse: Decodable {
    let results: [GeocodedPlace]?
}

/// Name in, candidates out.
enum PlaceSearch {

    /// A session of its own rather than the weather monitor's: searches run
    /// while the user types, and they should not be cancelling the forecast
    /// fetch out from under the board.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Looks `query` up and hands back what it found, best match first.
    ///
    /// Returns a cancellable task so a picker typing ahead of the network can
    /// throw away the answer to a question the user has already changed.
    @discardableResult
    static func run(_ query: String, limit: Int = 10,
                    then handle: @escaping (Result<[GeocodedPlace], FetchFailure>) -> Void) -> URLSessionTask? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handle(.success([]))
            return nil
        }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: String(limit)),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            handle(.failure(FetchFailure(message: "That name can't be searched for")))
            return nil
        }

        let task = session.dataTask(with: url) { data, response, error in
            let outcome: Result<[GeocodedPlace], FetchFailure>

            if let error = error as? URLError, error.code == .cancelled { return }
            if let error {
                outcome = .failure(FetchFailure(message: error.localizedDescription))
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
                outcome = .failure(FetchFailure(message: "Search service returned HTTP \(code)"))
            } else if let data, let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) {
                outcome = .success(decoded.results ?? [])
            } else {
                outcome = .failure(FetchFailure(message: "Unreadable response"))
            }

            DispatchQueue.main.async { handle(outcome) }
        }
        task.resume()
        return task
    }

    /// The one to take when nobody is choosing: the biggest exact match on the
    /// name, falling back to whatever ranked first.
    ///
    /// Used only for the time zone's guess at launch, where there is no user
    /// in the loop to ask. Anything typed goes through the picker instead.
    static func best(of results: [GeocodedPlace], for query: String) -> GeocodedPlace? {
        let wanted = query.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .current)
        let exact = results.filter {
            $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                            locale: .current) == wanted
        }
        let pool = exact.isEmpty ? results : exact
        return pool.max { ($0.population ?? 0) < ($1.population ?? 0) } ?? results.first
    }
}
