//
//  Preferences.swift
//  DotStrip
//

import AppKit

/// One thing the panel can show.
///
/// Widgets are not exclusive: several can be on at once and they lay out side
/// by side as zones (see Board.swift). Only one of them can hold the flexible
/// zone though, so the ones that need a whole line of text — the track title,
/// the news crawl — take it in order of priority rather than sharing it.
enum Widget: String, CaseIterable {
    case nowPlaying
    case ticker
    case stocks
    case weather

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .ticker:     return "News Ticker"
        case .stocks:     return "Stocks"
        case .weather:    return "Weather"
        }
    }
}

/// How the enabled widgets divide the panel up.
enum BoardLayout: String {
    /// One wide band that everything takes a turn in, read over time.
    case band
    /// A window each, side by side, every one of them scrolling its own
    /// content independently — what a multi-panel sign does.
    case windows
}

enum Preferences {

    private enum Key {
        static let showProgress = "showProgress"
        static let scrollSpeed = "scrollSpeed"
        static let boardWidth = "boardWidth"
        static let theme = "theme"
        static let layout = "layout"
        static let autoSize = "autoSize"
        static let hdr = "hdr"
        static let feed = "feedURL"
        static let symbols = "stockSymbols"
        static let weatherPlace = "weatherPlace"
        static let weatherDetail = "weatherDetail"
        static let weatherLatitude = "weatherLatitude"
        static let weatherLongitude = "weatherLongitude"
        static let weatherResolved = "weatherResolvedPlace"
        static let fahrenheit = "weatherFahrenheit"
        static let highLow = "weatherHighLow"

        static func widget(_ widget: Widget) -> String { "widget.\(widget.rawValue)" }

        /// Superseded by the per-widget keys. Read once, to carry a previous
        /// install's choice across.
        static let legacyMode = "mode"
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.widget(.nowPlaying): true,
            Key.widget(.ticker): false,
            Key.widget(.stocks): false,
            Key.widget(.weather): true,
            Key.showProgress: true,
            Key.scrollSpeed: 30.0,
            Key.boardWidth: defaultBoardWidth,
            Key.theme: BoardTheme.amber.id,
            Key.layout: BoardLayout.windows.rawValue,
            Key.autoSize: true,
            Key.hdr: false,
            Key.feed: feedChoices[0].url,
            Key.symbols: defaultSymbols,
            Key.weatherPlace: guessedPlace,
            Key.fahrenheit: Locale.current.measurementSystem == .us,
            Key.highLow: true,
        ])
        migrateMode()
    }

    /// The panel used to be one mode at a time. Somebody who left it on the
    /// news ticker should not find it showing their music after an update.
    private static func migrateMode() {
        let defaults = UserDefaults.standard
        guard let mode = defaults.string(forKey: Key.legacyMode) else { return }
        defaults.removeObject(forKey: Key.legacyMode)

        let wasTicker = mode == "ticker"
        set(.ticker, on: wasTicker)
        set(.nowPlaying, on: !wasTicker)
    }

    // MARK: Widgets

    static func isOn(_ widget: Widget) -> Bool {
        UserDefaults.standard.bool(forKey: Key.widget(widget))
    }

    static func set(_ widget: Widget, on: Bool) {
        UserDefaults.standard.set(on, forKey: Key.widget(widget))
    }

    // MARK: News ticker

    struct FeedChoice {
        let name: String
        let url: String
    }

    static let feedChoices = [
        FeedChoice(name: "Hacker News", url: "https://hnrss.org/frontpage"),
        FeedChoice(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml"),
        FeedChoice(name: "NPR News", url: "https://feeds.npr.org/1001/rss.xml"),
        FeedChoice(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index"),
    ]

    static var feed: String {
        get { UserDefaults.standard.string(forKey: Key.feed) ?? feedChoices[0].url }
        set { UserDefaults.standard.set(newValue, forKey: Key.feed) }
    }

    static var feedURL: URL? { URL(string: feed) }

    /// The name of the built-in feed this is, or nil when it's a custom one.
    static var feedName: String? {
        feedChoices.first { $0.url == feed }?.name
    }

    // MARK: Stocks

    /// Somewhere to start. The list is the user's to edit from the menu; this
    /// only decides what the widget shows the first time it is switched on.
    static let defaultSymbols = ["AAPL", "MSFT", "NVDA"]

    /// Ticker symbols, in the order they crawl past. Yahoo's own spellings:
    /// "^GSPC" for the S&P, "BTC-USD" for bitcoin.
    static var stockSymbols: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.symbols) ?? defaultSymbols }
        set { UserDefaults.standard.set(newValue, forKey: Key.symbols) }
    }

    // MARK: Weather

    /// A first guess at where the user is, taken from the time zone.
    ///
    /// The alternative is CoreLocation, which means a second permission prompt
    /// on top of the Automation one for a widget that only needs to be right to
    /// the nearest city. The time zone is already on the machine, costs
    /// nothing, and is usually correct; anyone it's wrong for can type their
    /// own in from the menu.
    private static var guessedPlace: String {
        let identifier = TimeZone.current.identifier
        guard let city = identifier.split(separator: "/").last else { return "New York" }
        return city.replacingOccurrences(of: "_", with: " ")
    }

    static var weatherPlace: String {
        get { UserDefaults.standard.string(forKey: Key.weatherPlace) ?? guessedPlace }
        set { UserDefaults.standard.set(newValue, forKey: Key.weatherPlace) }
    }

    /// Region and country for the place above, once something has actually
    /// resolved it. Nil until then — the time zone's guess is a bare name,
    /// and claiming a region for it would be inventing one.
    static var weatherDetail: String? {
        get { UserDefaults.standard.string(forKey: Key.weatherDetail) }
        set {
            let defaults = UserDefaults.standard
            guard let newValue, !newValue.isEmpty else {
                return defaults.removeObject(forKey: Key.weatherDetail)
            }
            defaults.set(newValue, forKey: Key.weatherDetail)
        }
    }

    /// The place said in full, for the menu: "Paris, Île-de-France, France".
    /// Falls back to the bare name while nothing has been resolved yet.
    static var weatherLabel: String {
        guard let detail = weatherDetail, !detail.isEmpty else { return weatherPlace }
        return "\(weatherPlace), \(detail)"
    }

    /// Name, region and coordinates written together, so the three can never
    /// end up describing different towns.
    static func setWeatherLocation(name: String, detail: String?,
                                   latitude: Double, longitude: Double) {
        weatherPlace = name
        weatherDetail = detail
        weatherCoordinate = (latitude, longitude)
    }

    /// Coordinates are stored alongside the name they were looked up for, so a
    /// changed place is detectable and a stable one never gets geocoded twice.
    static var weatherCoordinate: (latitude: Double, longitude: Double)? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.string(forKey: Key.weatherResolved) == weatherPlace,
                  defaults.object(forKey: Key.weatherLatitude) != nil else { return nil }
            return (defaults.double(forKey: Key.weatherLatitude),
                    defaults.double(forKey: Key.weatherLongitude))
        }
        set {
            let defaults = UserDefaults.standard
            guard let newValue else {
                defaults.removeObject(forKey: Key.weatherResolved)
                return
            }
            defaults.set(newValue.latitude, forKey: Key.weatherLatitude)
            defaults.set(newValue.longitude, forKey: Key.weatherLongitude)
            defaults.set(weatherPlace, forKey: Key.weatherResolved)
        }
    }

    /// Today's forecast range alongside the current temperature. Worth a
    /// switch of its own: it is the widest part of the weather window, and on
    /// a narrow board those columns come out of the lines either side of it.
    static var weatherHighLow: Bool {
        get { UserDefaults.standard.bool(forKey: Key.highLow) }
        set { UserDefaults.standard.set(newValue, forKey: Key.highLow) }
    }

    static var fahrenheit: Bool {
        get { UserDefaults.standard.bool(forKey: Key.fahrenheit) }
        set { UserDefaults.standard.set(newValue, forKey: Key.fahrenheit) }
    }

    // MARK: Panel

    static let defaultBoardWidth: Double = 320

    /// The upper bound is deliberately conservative.
    ///
    /// When a status item no longer fits, macOS does not shrink it — it stops
    /// drawing it, and the board simply vanishes. There is no reliable signal
    /// for that: the item's window keeps reporting a frame that looks like it
    /// fits, both immediately and after layout settles, so it cannot be
    /// detected and corrected at runtime. The only safe move is to stay well
    /// inside what the bar can seat. How much that is depends on the frontmost
    /// app's menus, so this leaves real headroom rather than finding the edge.
    static var boardWidthRange: ClosedRange<Double> {
        let screen = Double(NSScreen.main?.frame.width ?? 1440)
        return 140...max(defaultBoardWidth, screen * 0.29)
    }

    /// How small the board may get when it is sizing itself.
    ///
    /// The 140pt floor above is there to stop someone dragging the board down
    /// to a stub they can no longer grab. Auto size is not a hand on the grip
    /// and has a reason for every column it drops, so it is allowed much
    /// further — down to about the width of an ordinary menu bar icon, which
    /// is still a comfortable click target for the menu.
    static let minimumAutoWidth: Double = 24

    static var boardWidth: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.boardWidth)
            guard stored > 0 else { return defaultBoardWidth }
            return min(max(stored, boardWidthRange.lowerBound), boardWidthRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, boardWidthRange.lowerBound), boardWidthRange.upperBound)
            UserDefaults.standard.set(clamped, forKey: Key.boardWidth)
        }
    }

    static var layout: BoardLayout {
        get { BoardLayout(rawValue: UserDefaults.standard.string(forKey: Key.layout) ?? "") ?? .windows }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.layout) }
    }

    /// Whether the board sizes itself to the windows that are open.
    ///
    /// With this on, a widget with nothing to say closes its window and the
    /// board gives those columns back to the menu bar. Dragging the grip turns
    /// it off, since a hand on the grip is someone asking for a width of their
    /// own; the width they set is kept, so turning auto size off restores it.
    static var autoSize: Bool {
        get { UserDefaults.standard.bool(forKey: Key.autoSize) }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoSize) }
    }

    /// Dot columns a scrolling window needs before it stops being worth
    /// reading. About eleven characters — enough that a word is on screen
    /// whole rather than arriving letter by letter.
    static let minimumWindowColumns = 60

    static var theme: BoardTheme {
        get { BoardTheme.named(UserDefaults.standard.string(forKey: Key.theme) ?? "") }
        set { UserDefaults.standard.set(newValue.id, forKey: Key.theme) }
    }

    /// Off by default. Apple's own note on the EDR properties is that they
    /// "may have a significant impact on power consumption", and this view is
    /// on screen all day.
    static var hdr: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hdr) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hdr) }
    }

    /// Whether this display has any headroom to give. Reports the potential
    /// rather than what is free this instant, since the available figure sits
    /// at 1.0 until something actually asks for headroom.
    static var displaySupportsHDR: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.0
    }

    static var showProgress: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showProgress) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showProgress) }
    }

    /// Dot columns per second. The options are all whole multiples or divisors
    /// of the frame rate so the text never stutters.
    static var scrollSpeed: Double {
        get { UserDefaults.standard.double(forKey: Key.scrollSpeed) }
        set { UserDefaults.standard.set(newValue, forKey: Key.scrollSpeed) }
    }

    static let speedChoices: [(name: String, value: Double)] = [
        ("Slow", 15), ("Normal", 30), ("Fast", 60),
    ]
}
