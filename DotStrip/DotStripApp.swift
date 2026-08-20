//
//  DotStripApp.swift
//  DotStrip
//
//  Created by Daniel Moreno on 8/17/26.
//

import SwiftUI

@main
struct DotStripApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var ticker: TickerView?

    // Layers are long-lived so their scroll position and turn-over state
    // survive a change of layout underneath them.
    /// Quotes and headlines share one crawling line — a real ticker runs them
    /// in the same band — so this layer's text is composed from both.
    private let crawl = TextLayer()

    // A line each for the windows layout, where every widget scrolls its own
    // content inside its own slice of the board.
    private let trackLine = TextLayer()
    private let newsLine = TextLayer()
    private let stockLine = TextLayer()
    private let weatherLine = TextLayer()
    private let progress = ProgressLayer()
    private let divider = DividerLayer()

    private let nowPlaying = NowPlayingMonitor()
    private let feed = FeedMonitor()
    private let stocks = StockMonitor()
    private let weather = WeatherMonitor()

    /// What the current zones were built from. Sources report far more often
    /// than the layout actually changes — a track's position moves every few
    /// seconds without moving a single zone boundary — so the zones are only
    /// rebuilt when one of these does change.
    private var layoutKey = ""

    /// A stock window is too narrow for a whole watchlist, so it shows one
    /// symbol and turns over to the next. Rotating beats crawling here: the
    /// line is still between turns, and a quote is a thing you read at a
    /// glance rather than follow across the board.
    private var stockIndex = 0

    /// The weather window turns the same way, between the current temperature
    /// and today's high and low.
    private var weatherIndex = 0

    /// One timer for both, so two turning windows cost one wakeup rather than
    /// two that drift against each other. It ticks at the shorter of the two
    /// dwells and each window decides for itself whether its turn is due.
    private var rotation: Timer?
    private let rotationDwell: TimeInterval = 5

    /// The weather window rests on the current temperature and only makes an
    /// excursion to the range now and then. The range is context, not the
    /// reading — a window that spent two thirds of its life showing tomorrow's
    /// numbers would be answering a question nobody asked.
    private let weatherRestDwell: TimeInterval = 30
    private var weatherTurnedAt: CFTimeInterval = 0

    /// Drives the board between widths when a window opens or closes.
    private var widthAnimation: Timer?
    private var widthTarget: CGFloat?


    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        Preferences.register()

        let item = NSStatusBar.system.statusItem(withLength: Preferences.boardWidth)
        guard let button = item.button else { return }

        let ticker = TickerView(frame: button.bounds)
        ticker.autoresizingMask = [.width, .height]
        button.addSubview(ticker)

        ticker.onResize = { [weak self] width in
            guard let self else { return }
            // Dragging is someone asking for a width of their own.
            Preferences.autoSize = false
            self.endWidthAnimation()
            self.applyBoardWidth(width)
        }

        ticker.theme = Preferences.theme
        ticker.usesHDR = Preferences.hdr && Preferences.displaySupportsHDR

        // A crawl never stops, a title only moves when it has to, and the
        // weather is short enough that it never should.
        crawl.scroll = .always
        // Quotes refresh while the line is mid-lap. `.cut` would snap the crawl
        // back to its start every time a price moved; `.pushUp` waits for the
        // line to come round, then turns it over — which is what the flip was
        // built for.
        crawl.change = .pushUp
        trackLine.scroll = .ifOverflow
        trackLine.change = .pushUp
        newsLine.scroll = .always
        newsLine.change = .pushUp
        stockLine.scroll = .ifOverflow
        stockLine.change = .pushUp
        weatherLine.scroll = .fixed
        weatherLine.change = .pushUp

        progress.source = { [weak self] in self?.nowPlaying.current?.fraction ?? 0 }

        nowPlaying.onChange = { [weak self] info in self?.trackChanged(to: info) }
        feed.onChange = { [weak self] in self?.rebuildContent() }
        stocks.onChange = { [weak self] in self?.rebuildContent() }
        weather.onChange = { [weak self] in self?.weatherChanged() }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.statusItem = item
        self.ticker = ticker

        // A width stored on a roomier setup may not fit this one.
        applyBoardWidth(CGFloat(Preferences.boardWidth))
        applyWidgets()

        // Four windows on a board sized for one line would be four slivers.
        if Preferences.layout == .windows {
            if Preferences.autoSize {
                if let needed = widthNeeded() {
                    applyBoardWidth(needed, persist: false, auto: true)
                }
            } else {
                growToFitWindows()
            }
        }
    }

    // MARK: Wiring

    /// Starts and stops the sources to match what's switched on, then lays the
    /// panel out again. Nothing polls or fetches for a widget that is off.
    private func applyWidgets() {
        applyScrollSpeed()

        if Preferences.isOn(.nowPlaying) {
            nowPlaying.start()
        } else {
            nowPlaying.stop()
        }

        if Preferences.isOn(.ticker) {
            feed.url = Preferences.feedURL
            feed.start()
        } else {
            feed.stop()
        }

        if Preferences.isOn(.stocks) {
            stocks.symbols = Preferences.stockSymbols
            stocks.start()
        } else {
            stocks.stop()
        }

        if rotationNeeded {
            startRotation()
        } else {
            rotation?.invalidate()
            rotation = nil
        }

        rebuildContent()

        if Preferences.isOn(.weather) {
            weather.place = Preferences.weatherPlace
            weather.start()
        } else {
            weather.stop()
        }

        rebuildZones(force: true)
    }

    /// Which line gets the wide zone.
    ///
    /// Only one can have it, so they queue: a playing track outranks the crawl,
    /// and the crawl fills in when nothing is playing rather than leaving the
    /// panel to say "nothing playing" all day. With both on and neither having
    /// anything to say, now playing keeps the slot so its status text explains
    /// itself.
    private var primaryLine: TextLayer? {
        if !crawl.text.isEmpty { return crawl }
        if Preferences.isOn(.nowPlaying) { return trackLine }
        return nil
    }

    /// The widgets with something to show right now.
    ///
    /// A widget that is switched on but has nothing to say closes its window,
    /// and with auto size on the board hands those columns back to the menu
    /// bar. Now playing is the one that does this constantly — a paused
    /// afternoon should not cost the bar a third of its width.
    private var openWidgets: [Widget] {
        Widget.allCases.filter { widget in
            guard Preferences.isOn(widget) else { return false }

            switch widget {
            case .nowPlaying:
                // Playing, not merely loaded: a paused track is not something
                // to watch, so the window gives its columns straight back and
                // takes them again when playback resumes. The pause glyph in
                // the title still matters in the shared band, where this line
                // holds the wide zone either way.
                //
                // A permission problem is the exception and keeps the window:
                // that message is the only place the user finds out why it is
                // empty.
                if nowPlaying.trouble == .notAuthorized { return true }
                return nowPlaying.current?.isPlaying == true
            case .stocks:
                return !Preferences.stockSymbols.isEmpty
            case .ticker, .weather:
                return true
            }
        }
    }

    /// Width of the zone holding the rule between two windows. The rule sits
    /// in the middle of it, so this is also the air on either side: one column
    /// of gap reads as a cramped join at this dot pitch, two reads as a seam.
    private static let dividerColumns = 5

    /// Shown when every window has closed but widgets are still switched on.
    /// A status item with no width cannot be clicked, so something has to hold
    /// the board open — and this says the app is running and idle rather than
    /// broken.
    private static let idleMark = "\u{266A}"

    /// A window each, left to right in widget order, with a rule between.
    ///
    /// Every window is flexible except the weather, which is cut to its own
    /// text — a temperature is a fixed handful of columns and giving it an
    /// equal share of the board would starve the lines that actually need
    /// room. Each window scrolls independently, so a narrow one is a small
    /// moving sign rather than a truncated line.
    private func windowZones() -> [Zone] {
        var zones: [Zone] = []

        for widget in openWidgets {
            if !zones.isEmpty {
                zones.append(Zone(.fixed(Self.dividerColumns), [divider]))
            }

            switch widget {
            case .nowPlaying:
                var layers: [BoardLayer] = [trackLine]
                if Preferences.showProgress, nowPlaying.current != nil {
                    layers.append(progress)
                }
                zones.append(Zone(.flexible, layers))

            case .ticker:
                zones.append(Zone(.flexible, [newsLine]))

            case .stocks:
                zones.append(Zone(.flexible, [stockLine]))

            case .weather:
                refreshWeatherWindow()
                let indent = zones.isEmpty ? Self.weatherLeading : 0
                weatherLine.indent = indent
                zones.append(Zone(.fixed(weatherColumns(indent: indent)), [weatherLine]))
            }
        }
        return zones
    }

    private func rebuildZones(force: Bool = false) {
        guard let ticker else { return }

        if Preferences.layout == .windows {
            let open = openWidgets
            let key = ["windows"]
                + open.map(\.rawValue)
                + [nowPlaying.current != nil && Preferences.showProgress ? "bar" : "",
                   Preferences.isOn(.weather)
                       ? "w\(weatherColumns(indent: weatherStandsAlone ? Self.weatherLeading : 0))"
                       : ""]

            let joined = key.joined(separator: "|")
            guard force || joined != layoutKey else { return }
            layoutKey = joined

            var zones = windowZones()
            if zones.isEmpty {
                // Every window closed is a different state from every widget
                // switched off: the first is idle, the second needs to tell
                // the user where the menu is.
                let anythingOn = Widget.allCases.contains { Preferences.isOn($0) }
                trackLine.text = anythingOn ? Self.idleMark : "NOTHING TO SHOW"
                let width = anythingOn ? PixelFont.width(of: Self.idleMark) + 2 : 0
                zones = [anythingOn ? Zone(.fixed(width), [trackLine])
                                    : Zone(.flexible, [trackLine])]
            }
            ticker.zones = zones
            applyAutoSize()
            return
        }

        let primary = primaryLine

        // The bar belongs to now playing, not to the title, so it stays on the
        // top row while quotes and headlines go by underneath. That is what
        // lets all four widgets be present at once: three share the wide band
        // over time, and this one is always visible while something plays.
        let showsProgress = Preferences.showProgress
            && Preferences.isOn(.nowPlaying)
            && nowPlaying.current != nil
        // In the shared band the weather sits at the right unless nothing is
        // crawling at all, in which case it is the only thing on the board.
        let weatherIndent = primary == nil ? Self.weatherLeading : 0
        let weatherColumnsOrNil = Preferences.isOn(.weather)
            ? weatherColumns(indent: weatherIndent) : nil

        // Everything the layout depends on, and nothing that only changes what
        // a layer draws inside its own zone.
        let key = [
            "band",
            primary === trackLine ? "track" : (primary === crawl ? "crawl" : "none"),
            showsProgress ? "bar" : "",
            weatherColumnsOrNil.map(String.init) ?? "",
        ].joined(separator: "|")

        guard force || key != layoutKey else { return }
        layoutKey = key

        var zones: [Zone] = []

        if let primary {
            var layers: [BoardLayer] = [primary]
            if showsProgress { layers.append(progress) }
            zones.append(Zone(.flexible, layers))
        }

        if let weatherColumnsOrNil {
            refreshWeatherWindow()
            weatherLine.indent = weatherIndent
            if !zones.isEmpty {
                zones.append(Zone(.fixed(Self.dividerColumns), [divider]))
            }
            zones.append(Zone(.fixed(weatherColumnsOrNil), [weatherLine]))
        }

        // Everything switched off. Better to say so than to look broken.
        if zones.isEmpty {
            trackLine.text = "NOTHING TO SHOW"
            zones = [Zone(.flexible, [trackLine])]
        }

        ticker.zones = zones
    }

    // MARK: Sources

    /// The glyph says whether it's playing, so the title no longer has to
    /// spend columns spelling out "PAUSED".
    private static func trackText(for info: NowPlaying) -> String {
        let indicator = info.isPlaying ? "\u{266B}" : "\u{23F8}"
        return "\(indicator) \(info.title) \u{2014} \(info.artist)"
    }

    private func trackChanged(to info: NowPlaying?) {
        if let info {
            trackLine.text = Self.trackText(for: info)
        } else {
            switch nowPlaying.trouble {
            case .notAuthorized:
                trackLine.text = "ALLOW AUTOMATION IN PRIVACY SETTINGS"
            default:
                // Only ever seen in the shared-band layout, where this line
                // holds the wide zone whatever the player is doing. In the
                // windows layout the window has already closed.
                trackLine.text = "NOTHING PLAYING"
            }
        }
        rebuildContent()
    }

    /// Fills whichever lines the current layout actually draws.
    private func rebuildContent() {
        switch Preferences.layout {
        case .band:    rebuildCrawl()
        case .windows: rebuildWindows()
        }
    }

    private func rebuildWindows() {
        // Nothing shares the band in this layout, so the composed line is
        // emptied — otherwise switching back and forth would show a stale one.
        crawl.text = ""

        if Preferences.isOn(.ticker) {
            if feed.headlines.isEmpty {
                newsLine.text = feed.trouble == nil ? "LOADING NEWS" : "NEWS UNAVAILABLE"
            } else {
                let separator = "   \u{2022}   "
                newsLine.text = feed.headlines.joined(separator: separator) + separator
            }
        }

        refreshStockWindow()
        rebuildZones()
    }

    /// Puts the current symbol in the stock window.
    private func refreshStockWindow() {
        guard Preferences.isOn(.stocks) else { return }

        let quotes = stocks.quotes
        guard !quotes.isEmpty else {
            if stocks.trouble != nil {
                stockLine.text = "QUOTES UNAVAILABLE"
            } else {
                stockLine.text = Preferences.stockSymbols.isEmpty ? "NO SYMBOLS" : "LOADING QUOTES"
            }
            return
        }

        stockIndex = min(stockIndex, quotes.count - 1)
        stockLine.text = quotes[stockIndex].boardText
    }

    /// Whether anything on the board is currently a turning window.
    private var rotationNeeded: Bool {
        let turningStocks = Preferences.layout == .windows && Preferences.isOn(.stocks)
        let turningWeather = Preferences.isOn(.weather) && Preferences.weatherHighLow
        return turningStocks || turningWeather
    }

    private func startRotation() {
        guard rotation == nil else { return }
        weatherTurnedAt = CACurrentMediaTime()
        let t = Timer(timeInterval: rotationDwell, repeats: true) { [weak self] _ in
            self?.turnWindows()
        }
        RunLoop.main.add(t, forMode: .common)
        rotation = t
    }

    private func turnWindows() {
        if Preferences.layout == .windows, Preferences.isOn(.stocks) {
            let count = stocks.quotes.count
            if count > 1 {
                stockIndex = (stockIndex + 1) % count
                refreshStockWindow()
            }
        }

        if Preferences.isOn(.weather) {
            let count = weatherFrames.count
            let dwell = weatherIndex == 0 ? weatherRestDwell : rotationDwell
            let now = CACurrentMediaTime()

            // Half a tick of slack: the timer fires a hair late as often as
            // not, and without it a 30 second dwell waits for the 35 second
            // tick every time.
            if count > 1, now - weatherTurnedAt >= dwell - rotationDwell / 2 {
                weatherIndex = (weatherIndex + 1) % count
                weatherTurnedAt = now
                refreshWeatherWindow()
            }
        }
    }

    // MARK: Weather window

    /// The frames the weather window turns between.
    private var weatherFrames: [String] {
        guard let reading = weather.current else {
            // A degree sign with nothing in front of it holds the window open
            // at roughly its eventual width, so the layout doesn't jump when
            // the first reading lands.
            return ["\u{2014}\u{00B0}"]
        }
        return reading.boardFrames(fahrenheit: Preferences.fahrenheit,
                                   highLow: Preferences.weatherHighLow)
    }

    /// Air kept after the temperature, so the last dot is not flush against
    /// the edge of the panel.
    private static let weatherTrailing = 2

    /// The same air before it, for a weather window with nothing to its left.
    private static let weatherLeading = 2

    /// Cut to the widest frame, not to the frame showing. A window that
    /// resized on every turn would relayout the whole board twice a minute.
    private func weatherColumns(indent: Int) -> Int {
        let widest = weatherFrames.map { PixelFont.width(of: $0) }.max() ?? 0
        return widest + indent + Self.weatherTrailing
    }

    /// Whether the weather window will be the leftmost thing on the board.
    private var weatherStandsAlone: Bool {
        openWidgets.first == .weather
    }

    private func refreshWeatherWindow() {
        let frames = weatherFrames
        guard !frames.isEmpty else { return }
        weatherIndex = min(weatherIndex, frames.count - 1)
        weatherLine.text = frames[weatherIndex]
    }

    /// Composes the crawling line out of whatever wants to crawl.
    ///
    /// Quotes lead and headlines follow, the way a broadcast ticker runs them:
    /// the prices are the part being checked at a glance, so they come round
    /// again sooner if the reader missed them.
    private func rebuildCrawl() {
        var segments: [String] = []

        // A title only joins the crawl when something else is already
        // crawling. On its own it keeps the wide zone to itself, where it
        // stands still unless it overflows — a board that holds still is worth
        // more than one that moves for no reason.
        let othersCrawling = Preferences.isOn(.stocks) || Preferences.isOn(.ticker)
        if othersCrawling, Preferences.isOn(.nowPlaying), let track = nowPlaying.current {
            segments.append(Self.trackText(for: track))
        }

        if Preferences.isOn(.stocks) {
            if !stocks.quotes.isEmpty {
                segments.append(contentsOf: stocks.quotes.map(\.boardText))
            } else if stocks.trouble != nil {
                segments.append("QUOTES UNAVAILABLE")
            } else if !Preferences.stockSymbols.isEmpty {
                segments.append("LOADING QUOTES")
            }
        }

        if Preferences.isOn(.ticker) {
            if !feed.headlines.isEmpty {
                segments.append(contentsOf: feed.headlines)
            } else {
                segments.append(feed.trouble == nil ? "LOADING NEWS" : "NEWS FEED UNAVAILABLE")
            }
        }

        // A bullet between segments, and one on the end as well: the crawl
        // wraps around to its own start, so without it the last item runs
        // straight into the first.
        let separator = "   \u{2022}   "
        crawl.text = segments.isEmpty ? "" : segments.joined(separator: separator) + separator

        rebuildZones()
    }

    private func weatherChanged() {
        rebuildZones()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for line in statusLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("Show"))
        for widget in Widget.allCases {
            let item = choice(widget.title, #selector(toggleWidget(_:)),
                              checked: Preferences.isOn(widget))
            item.representedObject = widget.rawValue
            menu.addItem(item)
        }

        if Preferences.isOn(.nowPlaying) {
            menu.addItem(.separator())
            menu.addItem(choice("Progress Bar", #selector(toggleProgress),
                                checked: Preferences.showProgress))
        }

        if Preferences.isOn(.ticker) {
            menu.addItem(.separator())
            var feeds: [(title: String, checked: Bool, represented: Any, image: NSImage?)] =
                Preferences.feedChoices.map {
                    (title: $0.name, checked: Preferences.feed == $0.url,
                     represented: $0.url as Any, image: nil)
                }
            feeds.append((title: "Custom\u{2026}", checked: Preferences.feedName == nil,
                          represented: "" as Any, image: nil))
            menu.addItem(submenu("News Feed", items: feeds, action: #selector(chooseFeed(_:))))
        }

        if Preferences.isOn(.stocks) {
            menu.addItem(.separator())
            menu.addItem(symbolsMenu())
        }

        if Preferences.isOn(.weather) {
            menu.addItem(.separator())
            // The region and country are part of the title, not a detail
            // tucked away: which of the world's several Portlands this is
            // should be answerable without opening anything.
            let location = NSMenuItem(title: "Location: \(Preferences.weatherLabel)\u{2026}",
                                      action: #selector(chooseLocation), keyEquivalent: "")
            location.target = self
            menu.addItem(location)
            menu.addItem(choice("High / Low", #selector(toggleHighLow),
                                checked: Preferences.weatherHighLow))
            menu.addItem(submenu("Units", items: [
                (title: "Fahrenheit", checked: Preferences.fahrenheit,
                 represented: true as Any, image: nil),
                (title: "Celsius", checked: !Preferences.fahrenheit,
                 represented: false as Any, image: nil),
            ], action: #selector(chooseUnits(_:))))
        }

        menu.addItem(.separator())
        menu.addItem(submenu("Layout", items: [
            (title: "Separate Windows", checked: Preferences.layout == .windows,
             represented: BoardLayout.windows.rawValue as Any, image: nil),
            (title: "One Shared Band", checked: Preferences.layout == .band,
             represented: BoardLayout.band.rawValue as Any, image: nil),
        ], action: #selector(chooseLayout(_:))))

        if Preferences.layout == .windows {
            menu.addItem(choice("Auto Size", #selector(toggleAutoSize),
                                checked: Preferences.autoSize))

            if !Preferences.autoSize {
                let fit = NSMenuItem(title: "Fit Width to Windows", action: #selector(fitWidth),
                                     keyEquivalent: "")
                fit.target = self
                menu.addItem(fit)
            }
        }

        let reset = NSMenuItem(title: "Reset Width", action: #selector(resetWidth),
                               keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        menu.addItem(submenu("Color", items: BoardTheme.all.map {
            (title: $0.name, checked: Preferences.theme == $0,
             represented: $0.id as Any, image: $0.swatch())
        }, action: #selector(chooseTheme(_:))))

        let hdr = choice(hdrItemTitle, #selector(toggleHDR),
                         checked: Preferences.hdr && Preferences.displaySupportsHDR)
        if !Preferences.displaySupportsHDR {
            // No action means AppKit greys it out for us.
            hdr.action = nil
            hdr.target = nil
        }
        menu.addItem(hdr)

        menu.addItem(submenu("Scroll Speed", items: Preferences.speedChoices.map {
            (title: $0.name, checked: Preferences.scrollSpeed == $0.value,
             represented: $0.value as Any, image: nil)
        }, action: #selector(chooseSpeed(_:))))

        menu.addItem(.separator())
        menu.addItem(credit())
        let quit = NSMenuItem(title: "Quit DotStrip",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// The byline at the foot of the menu.
    ///
    /// Set as an attributed title rather than a plain one: a disabled item is
    /// drawn in the greyed-out colour, which says "unavailable" about a line
    /// that is only there to be read. Smaller and secondary says "footer".
    private func credit() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: "Created by Daniel Moreno \u{00B7} 2026",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        return item
    }

    /// One line per widget that's on, so the menu says what the board is
    /// showing in full — including the parts the board had to abbreviate.
    private var statusLines: [String] {
        var lines: [String] = []

        if Preferences.isOn(.nowPlaying) {
            if let track = nowPlaying.current {
                lines.append("\(track.title) \u{2014} \(track.artist)")
            } else {
                lines.append(nowPlaying.trouble == .notAuthorized
                             ? "Automation permission needed"
                             : "Nothing playing")
            }
        }

        if Preferences.isOn(.ticker) {
            let source = Preferences.feedName ?? Preferences.feed
            if let problem = feed.trouble {
                lines.append("\(source): \(problem)")
            } else if feed.headlines.isEmpty {
                lines.append("\(source): loading\u{2026}")
            } else {
                lines.append("\(source): \(feed.headlines.count) headlines")
            }
        }

        if Preferences.isOn(.stocks) {
            if let problem = stocks.trouble {
                lines.append("Quotes: \(problem)")
            } else if stocks.quotes.isEmpty {
                lines.append(Preferences.stockSymbols.isEmpty
                             ? "No symbols yet"
                             : "Quotes: loading\u{2026}")
            } else {
                lines.append(stocks.quotes.map(\.summary).joined(separator: "    "))
            }
        }

        if Preferences.isOn(.weather) {
            if let reading = weather.current {
                lines.append(reading.summary(fahrenheit: Preferences.fahrenheit))
            } else {
                lines.append(weather.trouble ?? "Fetching weather\u{2026}")
            }
        }

        return lines.isEmpty ? ["Nothing to show"] : lines
    }

    /// Only the two cases that actually disable the switch get spelled out.
    /// Momentary headroom is not one of them: it sits at 1.0 until something
    /// asks for it, so reporting it would nag about a state the toggle works in.
    private var hdrItemTitle: String {
        // The headroom tagging this needs only exists from macOS 26 on, so
        // say that rather than blaming a display that may well be capable.
        guard #available(macOS 26.0, *) else { return "HDR Glow (needs macOS 26)" }
        return Preferences.displaySupportsHDR ? "HDR Glow" : "HDR Glow (display has no headroom)"
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String,
                         items: [(title: String, checked: Bool, represented: Any, image: NSImage?)],
                         action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        for entry in items {
            let item = choice(entry.title, action, checked: entry.checked)
            item.representedObject = entry.represented
            item.image = entry.image
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    /// Each symbol is a checked item that unchecks itself away, which is the
    /// one gesture a menu can offer for "remove" without a window to put a
    /// table in. The prices are shown here too, since a menu has the room for
    /// them that the board does not.
    private func symbolsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Symbols", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Symbols")

        let add = NSMenuItem(title: "Add Symbol\u{2026}", action: #selector(addSymbol),
                             keyEquivalent: "")
        add.target = self
        sub.addItem(add)

        if !Preferences.stockSymbols.isEmpty {
            sub.addItem(.separator())

            let quoted = Dictionary(uniqueKeysWithValues: stocks.quotes.map { ($0.symbol, $0) })
            for symbol in Preferences.stockSymbols {
                let detail: String
                if let quote = quoted[symbol.uppercased()] {
                    detail = "   \(quote.summary.dropFirst(symbol.count))"
                } else if stocks.unknown.contains(symbol) {
                    detail = "   not found"
                } else {
                    detail = ""
                }
                let item = choice(symbol + detail, #selector(removeSymbol(_:)), checked: true)
                item.representedObject = symbol
                sub.addItem(item)
            }
        }

        parent.submenu = sub
        return parent
    }

    private func choice(_ title: String, _ action: Selector, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    /// A one-field prompt. There is no settings window to put this in, and a
    /// whole window for one string is more app than this needs.
    private func ask(_ question: String, explanation: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = explanation
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field

        // An accessory view is not first responder by default, so without this
        // the user has to click the field they were just asked to fill in.
        alert.window.initialFirstResponder = field

        // Menu bar apps are not active when their menu is used; an alert from
        // an inactive app opens behind whatever is in front.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let answer = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }

    // MARK: Menu actions

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let widget = Widget(rawValue: raw) else { return }
        Preferences.set(widget, on: !Preferences.isOn(widget))
        applyWidgets()
    }

    @objc private func chooseFeed(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }

        if url.isEmpty {
            let current = Preferences.feedName == nil ? Preferences.feed : ""
            guard let entered = ask("News feed URL",
                                    explanation: "The address of an RSS or Atom feed.",
                                    value: current),
                  let parsed = URL(string: entered), parsed.scheme != nil else { return }
            Preferences.feed = parsed.absoluteString
        } else {
            Preferences.feed = url
        }

        feed.url = Preferences.feedURL
        rebuildContent()
    }

    @objc private func addSymbol() {
        guard let entered = ask("Add a symbol",
                                explanation: "A ticker symbol as the market lists it \u{2014} AAPL, "
                                           + "^GSPC for the S&P 500, BTC-USD for bitcoin.",
                                value: "") else { return }

        let symbol = entered.uppercased()
        var symbols = Preferences.stockSymbols
        guard !symbols.contains(symbol) else { return }
        symbols.append(symbol)

        Preferences.stockSymbols = symbols
        stocks.symbols = symbols
        rebuildContent()
    }

    @objc private func removeSymbol(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        let symbols = Preferences.stockSymbols.filter { $0 != symbol }

        Preferences.stockSymbols = symbols
        stocks.symbols = symbols
        rebuildContent()
    }

    @objc private func chooseLocation() {
        LocationPicker.shared.present(query: Preferences.weatherPlace) { [weak self] place in
            self?.weather.use(place)
        }
    }

    @objc private func toggleHighLow() {
        Preferences.weatherHighLow.toggle()
        weatherTurnedAt = CACurrentMediaTime()
        // Back to the current temperature, and the window is cut to its widest
        // frame — so this changes the layout, not just what one zone draws.
        weatherIndex = 0
        applyWidgets()
    }

    @objc private func chooseUnits(_ sender: NSMenuItem) {
        guard let fahrenheit = sender.representedObject as? Bool else { return }
        guard fahrenheit != Preferences.fahrenheit else { return }
        Preferences.fahrenheit = fahrenheit
        // The reading is held in Celsius, so this is a re-render, not a re-fetch.
        rebuildZones()
    }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = BoardLayout(rawValue: raw),
              layout != Preferences.layout else { return }
        Preferences.layout = layout

        // Windows only work if there is board to divide. Growing to fit is the
        // difference between four readable signs and four unreadable slivers;
        // it only ever grows, so a board already wide enough is left alone.
        if layout == .windows { growToFitWindows() }
        applyWidgets()
    }

    /// The narrowest board that still gives every open window room to read in.
    private var columnsNeeded: Int {
        let open = openWidgets
        guard !open.isEmpty else { return PixelFont.width(of: Self.idleMark) + 2 }

        var total = 0
        for (index, widget) in open.enumerated() {
            if index > 0 { total += Self.dividerColumns }
            total += widget == .weather
                ? weatherColumns(indent: index == 0 ? Self.weatherLeading : 0)
                : Preferences.minimumWindowColumns
        }
        return total
    }

    private func widthNeeded() -> CGFloat? {
        guard let ticker, ticker.dotPitch > 0 else { return nil }
        return CGFloat(columnsNeeded) * ticker.dotPitch
    }

    private func growToFitWindows() {
        guard let needed = widthNeeded(), needed > CGFloat(Preferences.boardWidth) else { return }
        applyBoardWidth(needed)
    }

    @objc private func fitWidth() {
        guard let needed = widthNeeded() else { return }
        applyBoardWidth(needed)
    }

    // MARK: Auto size

    /// Takes the board to whatever the open windows currently need.
    ///
    /// The width is not stored while this is driving: the number in
    /// preferences stays the one the user last set by hand, so switching auto
    /// size off puts their own board back rather than freezing whatever size
    /// an idle moment happened to leave behind.
    private func applyAutoSize() {
        guard Preferences.autoSize, Preferences.layout == .windows,
              let needed = widthNeeded() else { return }
        animateBoardWidth(to: needed)
    }

    /// Slides the status item to a new width instead of snapping to it, so a
    /// window closing reads as a window closing.
    private func animateBoardWidth(to target: CGFloat) {
        guard let item = statusItem else { return }

        let clamped = Self.clamp(target, auto: true)
        widthTarget = CGFloat(clamped)

        guard abs(CGFloat(clamped) - item.length) > 1 else {
            widthTarget = nil
            return
        }
        guard widthAnimation == nil else { return }

        let t = Timer(timeInterval: 1.0 / TickerView.frameRate, repeats: true) { [weak self] _ in
            self?.stepBoardWidth()
        }
        RunLoop.main.add(t, forMode: .common)
        widthAnimation = t
    }

    private func stepBoardWidth() {
        guard let item = statusItem, let target = widthTarget else {
            return endWidthAnimation()
        }

        let remaining = target - item.length
        guard abs(remaining) > 0.75 else {
            item.length = target
            return endWidthAnimation()
        }

        // A third of what is left each frame: fast at the start, easing into
        // the new width rather than stopping dead on it.
        item.length = item.length + remaining * 0.34
    }

    private func endWidthAnimation() {
        widthAnimation?.invalidate()
        widthAnimation = nil
        widthTarget = nil
    }

    @objc private func toggleAutoSize() {
        Preferences.autoSize.toggle()

        if Preferences.autoSize {
            applyAutoSize()
        } else {
            // Back to the width they last set by hand.
            endWidthAnimation()
            applyBoardWidth(CGFloat(Preferences.boardWidth))
        }
    }

    @objc private func resetWidth() {
        Preferences.autoSize = false
        endWidthAnimation()
        applyBoardWidth(Preferences.defaultBoardWidth)
    }

    private func applyBoardWidth(_ requested: CGFloat,
                                 persist: Bool = true, auto: Bool = false) {
        guard let item = statusItem else { return }
        let width = Self.clamp(requested, auto: auto)

        item.length = width
        if persist { Preferences.boardWidth = width }
    }

    /// Auto size may shrink the board far past the floor a dragging hand is
    /// held to; see `Preferences.minimumAutoWidth`.
    private static func clamp(_ requested: CGFloat, auto: Bool) -> Double {
        let range = Preferences.boardWidthRange
        let lower = auto ? Preferences.minimumAutoWidth : range.lowerBound
        return min(max(Double(requested), lower), range.upperBound)
    }

    @objc private func toggleProgress() {
        Preferences.showProgress.toggle()
        rebuildZones()
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Preferences.theme = BoardTheme.named(id)
        ticker?.theme = Preferences.theme
    }

    @objc private func toggleHDR() {
        Preferences.hdr.toggle()
        ticker?.usesHDR = Preferences.hdr && Preferences.displaySupportsHDR
    }

    @objc private func chooseSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Double else { return }
        Preferences.scrollSpeed = speed
        applyScrollSpeed()
    }

    /// Every line that can crawl, so a new speed reaches the windows layout
    /// too — the news and stock lines are the ones actually moving there.
    private func applyScrollSpeed() {
        for line in [crawl, trackLine, newsLine, stockLine] {
            line.columnsPerSecond = Preferences.scrollSpeed
        }
    }
}
