//
//  pixelScreenApp.swift
//  pixelScreen
//
//  Created by Daniel Moreno on 8/17/26.
//

import SwiftUI

@main
struct pixelScreenApp: App {
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
            self?.applyBoardWidth(width)
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
        // This only ever grows, and the grip and Reset Width still overrule it.
        if Preferences.layout == .windows { growToFitWindows() }
    }

    // MARK: Wiring

    /// Starts and stops the sources to match what's switched on, then lays the
    /// panel out again. Nothing polls or fetches for a widget that is off.
    private func applyWidgets() {
        for line in [crawl, trackLine, newsLine, stockLine] {
            line.columnsPerSecond = Preferences.scrollSpeed
        }

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

    /// A window each, left to right in widget order, with a rule between.
    ///
    /// Every window is flexible except the weather, which is cut to its own
    /// text — a temperature is a fixed handful of columns and giving it an
    /// equal share of the board would starve the lines that actually need
    /// room. Each window scrolls independently, so a narrow one is a small
    /// moving sign rather than a truncated line.
    private func windowZones() -> [Zone] {
        var zones: [Zone] = []

        for widget in Widget.allCases where Preferences.isOn(widget) {
            if !zones.isEmpty { zones.append(Zone(.fixed(4), [divider])) }

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
                zones.append(Zone(.fixed(weatherColumns), [weatherLine]))
            }
        }
        return zones
    }

    private func rebuildZones(force: Bool = false) {
        guard let ticker else { return }

        if Preferences.layout == .windows {
            let enabled = Widget.allCases.filter { Preferences.isOn($0) }
            let key = ["windows"]
                + enabled.map(\.rawValue)
                + [nowPlaying.current != nil && Preferences.showProgress ? "bar" : "",
                   Preferences.isOn(.weather) ? "w\(weatherColumns)" : ""]

            let joined = key.joined(separator: "|")
            guard force || joined != layoutKey else { return }
            layoutKey = joined

            var zones = windowZones()
            if zones.isEmpty {
                trackLine.text = "NOTHING TO SHOW"
                zones = [Zone(.flexible, [trackLine])]
            }
            ticker.zones = zones
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
        let weatherColumnsOrNil = Preferences.isOn(.weather) ? weatherColumns : nil

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
            if !zones.isEmpty {
                zones.append(Zone(.fixed(4), [divider]))
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

    /// Cut to the widest frame, not to the frame showing. A window that
    /// resized on every turn would relayout the whole board twice a minute.
    private var weatherColumns: Int {
        (weatherFrames.map { PixelFont.width(of: $0) }.max() ?? 0) + 1
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
            let location = NSMenuItem(title: "Location: \(Preferences.weatherPlace)\u{2026}",
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
            let fit = NSMenuItem(title: "Fit Width to Windows", action: #selector(fitWidth),
                                 keyEquivalent: "")
            fit.target = self
            menu.addItem(fit)
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
        let quit = NSMenuItem(title: "Quit pixelScreen",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
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

    /// Headroom is granted dynamically, so a display that is capable in
    /// principle can still be offering nothing at this brightness. Saying so
    /// here beats letting the switch look broken.
    private var hdrItemTitle: String {
        guard Preferences.displaySupportsHDR else { return "HDR Glow (display has no headroom)" }
        return Preferences.currentHeadroom > 1.0 ? "HDR Glow" : "HDR Glow — no headroom right now"
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
        NSApp.activate()

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
        rebuildCrawl()
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
        rebuildCrawl()
    }

    @objc private func removeSymbol(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        let symbols = Preferences.stockSymbols.filter { $0 != symbol }

        Preferences.stockSymbols = symbols
        stocks.symbols = symbols
        rebuildCrawl()
    }

    @objc private func chooseLocation() {
        guard let entered = ask("Weather location",
                                explanation: "A city or town name.",
                                value: Preferences.weatherPlace) else { return }
        weather.place = entered
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

    /// The narrowest board that still gives every window room to read in.
    private var columnsNeeded: Int {
        var total = 0
        var count = 0
        for widget in Widget.allCases where Preferences.isOn(widget) {
            if count > 0 { total += 4 }          // the rule between windows
            switch widget {
            case .weather: total += weatherColumns
            default:       total += Preferences.minimumWindowColumns
            }
            count += 1
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

    @objc private func resetWidth() {
        applyBoardWidth(Preferences.defaultBoardWidth)
    }

    private func applyBoardWidth(_ requested: CGFloat) {
        guard let item = statusItem else { return }
        let range = Preferences.boardWidthRange
        let width = min(max(Double(requested), range.lowerBound), range.upperBound)

        item.length = width
        Preferences.boardWidth = width
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
        crawl.columnsPerSecond = speed
        trackLine.columnsPerSecond = speed
    }
}
