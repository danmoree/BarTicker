//
//  Preferences.swift
//  pixelScreen
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
    case weather

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .ticker:     return "News Ticker"
        case .weather:    return "Weather"
        }
    }
}

enum Preferences {

    private enum Key {
        static let showProgress = "showProgress"
        static let scrollSpeed = "scrollSpeed"
        static let boardWidth = "boardWidth"
        static let theme = "theme"
        static let hdr = "hdr"
        static let feed = "feedURL"
        static let weatherPlace = "weatherPlace"
        static let weatherLatitude = "weatherLatitude"
        static let weatherLongitude = "weatherLongitude"
        static let weatherResolved = "weatherResolvedPlace"
        static let fahrenheit = "weatherFahrenheit"

        static func widget(_ widget: Widget) -> String { "widget.\(widget.rawValue)" }

        /// Superseded by the per-widget keys. Read once, to carry a previous
        /// install's choice across.
        static let legacyMode = "mode"
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.widget(.nowPlaying): true,
            Key.widget(.ticker): false,
            Key.widget(.weather): true,
            Key.showProgress: true,
            Key.scrollSpeed: 30.0,
            Key.boardWidth: defaultBoardWidth,
            Key.theme: BoardTheme.amber.id,
            Key.hdr: false,
            Key.feed: feedChoices[0].url,
            Key.weatherPlace: guessedPlace,
            Key.fahrenheit: Locale.current.measurementSystem == .us,
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

    /// What the display is granting this instant, which is not the same as what
    /// it is capable of: headroom is handed out dynamically and sits at 1.0
    /// until the display has room above SDR white to give.
    static var currentHeadroom: CGFloat {
        NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
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
