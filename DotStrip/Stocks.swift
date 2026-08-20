//
//  Stocks.swift
//  DotStrip
//
//  Quotes for the stock ticker.
//
//  There is no keyless, documented source for equity prices. The one that
//  works today is Yahoo's chart endpoint, which is undocumented and can be
//  withdrawn — their multi-symbol quote endpoint already was, and now answers
//  "Unauthorized". So the fetch sits behind `QuoteProvider`: when this route
//  closes, a replacement is one type, not a rewrite. Everything above the
//  protocol deals in `Quote` and knows nothing about where it came from.
//

import Foundation
import OSLog

struct Quote: Equatable {
    let symbol: String
    let price: Double
    let previousClose: Double

    var change: Double { price - previousClose }

    var percent: Double {
        guard previousClose > 0 else { return 0 }
        return change / previousClose * 100
    }

    /// Flat gets a dash rather than an arrow: at this size an arrow that means
    /// "barely moved" is indistinguishable from one that means "moved".
    var glyph: Character {
        if abs(percent) < 0.05 { return "\u{2013}" }
        return change > 0 ? "\u{25B2}" : "\u{25BC}"
    }

    /// Cheap stocks and indices need different precision, and the board has no
    /// columns to waste on trailing zeros nobody reads.
    private var priceText: String {
        let decimals = price >= 1000 ? 0 : (price >= 1 ? 2 : 4)
        return String(format: "%.\(decimals)f", price)
    }

    /// What the crawl shows.
    ///
    /// Three fields with a double space between them, and a single space
    /// inside the last one. Spacing is the only grouping a dot board has —
    /// there is no weight or colour to separate a symbol from its price — so
    /// an even gap everywhere reads as one long run of characters. The arrow
    /// sits closer to the percentage than to the price because it belongs to
    /// it: it is the sign of that number, not a field of its own.
    var boardText: String {
        String(format: "%@  %@  %@ %.1f%%", symbol, priceText,
               String(glyph), abs(percent))
    }

    /// Signed, for the menu, where the arrow isn't doing the work.
    var summary: String {
        String(format: "%@  %@  %@%.2f%%", symbol, priceText,
               percent < 0 ? "-" : "+", abs(percent))
    }
}

// MARK: - Provider

/// Where quotes come from. One call per refresh, however many symbols.
protocol QuoteProvider {
    /// The name to show when explaining a failure.
    var name: String { get }

    /// Reports on the main queue. `unknown` are symbols the source did not
    /// recognise, so the menu can point at the typo rather than saying the
    /// whole fetch failed.
    func quotes(for symbols: [String],
                then handle: @escaping (_ quotes: [Quote],
                                        _ unknown: [String],
                                        _ trouble: String?) -> Void)
}

/// Yahoo's per-symbol chart endpoint.
///
/// One request per symbol, which is why the refresh interval is measured in
/// minutes and not seconds. It answers 429 to a request with no User-Agent, so
/// the session below always sends one.
struct YahooChartProvider: QuoteProvider {

    let name = "Yahoo Finance"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["User-Agent": "DotStrip/1.0"]
        return URLSession(configuration: config)
    }()

    // `nonisolated` because the decode happens on the URLSession callback,
    // not the main actor the rest of the target defaults to.
    private nonisolated struct Response: Decodable {
        struct Chart: Decodable {
            struct Result: Decodable {
                struct Meta: Decodable {
                    let symbol: String
                    let regularMarketPrice: Double?
                    let chartPreviousClose: Double?
                }
                let meta: Meta
            }
            let result: [Result]?
        }
        let chart: Chart
    }

    func quotes(for symbols: [String],
                then handle: @escaping ([Quote], [String], String?) -> Void) {
        guard !symbols.isEmpty else { return handle([], [], nil) }

        // Each symbol is its own request, so results are collected on a serial
        // queue rather than assumed to arrive in order.
        let group = DispatchGroup()
        let collector = DispatchQueue(label: "DotStrip.quotes")
        var found: [String: Quote] = [:]
        var unknown: [String] = []
        var failure: String?

        for symbol in symbols {
            guard let url = Self.url(for: symbol) else {
                collector.async { unknown.append(symbol) }
                continue
            }

            group.enter()
            Self.session.dataTask(with: url) { data, response, error in
                defer { group.leave() }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if let error {
                    collector.async { failure = failure ?? error.localizedDescription }
                    return
                }
                // 404 is this symbol not existing; anything else in the 400s is
                // the endpoint itself turning us away, which is worth saying.
                if status == 404 {
                    collector.async { unknown.append(symbol) }
                    return
                }
                if status >= 400 {
                    collector.async { failure = failure ?? "Yahoo returned HTTP \(status)" }
                    return
                }

                guard let data,
                      let decoded = try? JSONDecoder().decode(Response.self, from: data),
                      let meta = decoded.chart.result?.first?.meta,
                      let price = meta.regularMarketPrice,
                      let close = meta.chartPreviousClose else {
                    collector.async { unknown.append(symbol) }
                    return
                }

                let quote = Quote(symbol: meta.symbol.uppercased(),
                                  price: price, previousClose: close)
                collector.async { found[symbol] = quote }
            }.resume()
        }

        group.notify(queue: collector) {
            // Back into the order the user listed them in, which is the order
            // they expect to read them in.
            let ordered = symbols.compactMap { found[$0] }
            let missing = unknown
            let problem = failure
            DispatchQueue.main.async { handle(ordered, missing, problem) }
        }
    }

    private static func url(for symbol: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-^="))
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: allowed),
              !escaped.isEmpty else { return nil }
        return URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escaped)?interval=1d&range=1d")
    }
}

// MARK: - Monitor

final class StockMonitor {

    private(set) var quotes: [Quote] = []
    private(set) var unknown: [String] = []
    private(set) var trouble: String?

    var onChange: (() -> Void)?

    var provider: QuoteProvider = YahooChartProvider()

    var symbols: [String] = Preferences.stockSymbols {
        didSet {
            guard symbols != oldValue else { return }
            quotes = quotes.filter { symbols.contains($0.symbol) }
            unknown = []
            onChange?()
            refresh()
        }
    }

    /// While the market is open. One request per symbol makes this the ceiling
    /// on how often the source gets asked, not a target.
    private let openInterval: TimeInterval = 60

    /// Overnight and at weekends the last close does not move, so asking again
    /// every minute is pure waste on a machine that is awake all day.
    private let closedInterval: TimeInterval = 15 * 60

    private var timer: Timer?
    private var lastFetch: Date?

    private let log = Logger(subsystem: "com.danielmoreno.projects.DotStrip",
                             category: "stocks")

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: openInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The timer runs at the open-market rate throughout and this decides
    /// whether the tick is due, which keeps the schedule right across an open
    /// or a close without rebuilding the timer.
    private func tick() {
        let due = Self.marketIsOpen ? openInterval : closedInterval
        guard let last = lastFetch, Date().timeIntervalSince(last) >= due - 1 else {
            if lastFetch == nil { refresh() }
            return
        }
        refresh()
    }

    // MARK: Fetching

    func refresh() {
        guard !symbols.isEmpty else {
            quotes = []
            trouble = nil
            onChange?()
            return
        }

        lastFetch = Date()
        provider.quotes(for: symbols) { [weak self] quotes, unknown, trouble in
            guard let self else { return }

            if let trouble {
                self.log.error("\(trouble, privacy: .public)")
                // Prices already up stay up. A stale quote with a timestamp the
                // user can reason about beats an empty board.
                guard self.trouble != trouble else { return }
                self.trouble = trouble
            } else {
                guard quotes != self.quotes
                        || unknown != self.unknown
                        || self.trouble != nil else { return }
                self.quotes = quotes
                self.unknown = unknown
                self.trouble = nil
            }
            self.onChange?()
        }
    }

    // MARK: Market hours

    /// US regular session, 9:30 to 16:00 Eastern on a weekday.
    ///
    /// Holidays are not accounted for: getting that wrong costs one needless
    /// fetch a minute on roughly nine days a year, and getting it right means
    /// shipping a calendar that goes stale.
    static var marketIsOpen: Bool {
        var calendar = Calendar(identifier: .gregorian)
        guard let eastern = TimeZone(identifier: "America/New_York") else { return true }
        calendar.timeZone = eastern

        let now = Date()
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, let hour = parts.hour,
              let minute = parts.minute else { return true }
        guard (2...6).contains(weekday) else { return false }   // Mon-Fri

        let minutes = hour * 60 + minute
        return minutes >= 9 * 60 + 30 && minutes < 16 * 60
    }
}
