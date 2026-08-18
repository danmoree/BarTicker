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
    private let headline = TextLayer()
    private let trackLine = TextLayer()
    private let weatherLine = TextLayer()
    private let progress = ProgressLayer()
    private let divider = DividerLayer()

    private let nowPlaying = NowPlayingMonitor()
    private let feed = FeedMonitor()
    private let weather = WeatherMonitor()

    /// What the current zones were built from. Sources report far more often
    /// than the layout actually changes — a track's position moves every few
    /// seconds without moving a single zone boundary — so the zones are only
    /// rebuilt when one of these does change.
    private var layoutKey = ""

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
        headline.scroll = .always
        trackLine.scroll = .ifOverflow
        trackLine.change = .pushUp
        weatherLine.scroll = .fixed
        weatherLine.change = .pushUp

        progress.source = { [weak self] in self?.nowPlaying.current?.fraction ?? 0 }

        nowPlaying.onChange = { [weak self] info in self?.trackChanged(to: info) }
        feed.onChange = { [weak self] in self?.headlinesChanged() }
        weather.onChange = { [weak self] in self?.weatherChanged() }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.statusItem = item
        self.ticker = ticker

        // A width stored on a roomier setup may not fit this one.
        applyBoardWidth(CGFloat(Preferences.boardWidth))
        applyWidgets()
    }

    // MARK: Wiring

    /// Starts and stops the sources to match what's switched on, then lays the
    /// panel out again. Nothing polls or fetches for a widget that is off.
    private func applyWidgets() {
        headline.columnsPerSecond = Preferences.scrollSpeed
        trackLine.columnsPerSecond = Preferences.scrollSpeed

        if Preferences.isOn(.nowPlaying) {
            nowPlaying.start()
        } else {
            nowPlaying.stop()
        }

        if Preferences.isOn(.ticker) {
            feed.url = Preferences.feedURL
            feed.start()
            headlinesChanged()
        } else {
            feed.stop()
        }

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
    /// Only one can have it, so they queue: a playing track outranks the news,
    /// and the news fills in when nothing is playing rather than leaving the
    /// panel to say "nothing playing" all day. With both on and neither having
    /// anything to say, now playing keeps the slot so its status text explains
    /// itself.
    private var primaryLine: TextLayer? {
        let music = Preferences.isOn(.nowPlaying)
        let news = Preferences.isOn(.ticker)

        if music, nowPlaying.current != nil { return trackLine }
        if news, !feed.headlines.isEmpty { return headline }
        if music { return trackLine }
        if news { return headline }
        return nil
    }

    private func rebuildZones(force: Bool = false) {
        guard let ticker else { return }

        let primary = primaryLine
        let showsProgress = primary === trackLine && Preferences.showProgress
        let weatherText = Preferences.isOn(.weather) ? weatherBoardText : nil

        // Everything the layout depends on, and nothing that only changes what
        // a layer draws inside its own zone.
        let key = [
            primary === trackLine ? "track" : (primary === headline ? "news" : "none"),
            showsProgress ? "bar" : "",
            weatherText ?? "",
        ].joined(separator: "|")

        guard force || key != layoutKey else { return }
        layoutKey = key

        var zones: [Zone] = []

        if let primary {
            var layers: [BoardLayer] = [primary]
            if showsProgress { layers.append(progress) }
            zones.append(Zone(.flexible, layers))
        }

        if let weatherText {
            weatherLine.text = weatherText
            // The zone is cut to the text, plus a column of air on the right so
            // the last dot isn't flush against the edge of the board.
            let width = PixelFont.width(of: weatherText) + 1
            if !zones.isEmpty {
                zones.append(Zone(.fixed(4), [divider]))
            }
            zones.append(Zone(.fixed(width), [weatherLine]))
        }

        // Everything switched off. Better to say so than to look broken.
        if zones.isEmpty {
            trackLine.text = "NOTHING TO SHOW"
            zones = [Zone(.flexible, [trackLine])]
        }

        ticker.zones = zones
    }

    // MARK: Sources

    private func trackChanged(to info: NowPlaying?) {
        if let info {
            // The glyph says whether it's playing, so the title no longer has
            // to spend columns spelling out "PAUSED".
            let indicator = info.isPlaying ? "\u{266B}" : "\u{23F8}"
            trackLine.text = "\(indicator) \(info.title) \u{2014} \(info.artist)"
        } else {
            switch nowPlaying.trouble {
            case .notAuthorized:
                trackLine.text = "ALLOW AUTOMATION IN PRIVACY SETTINGS"
            default:
                trackLine.text = "NOTHING PLAYING"
            }
        }
        rebuildZones()
    }

    private func headlinesChanged() {
        if feed.headlines.isEmpty {
            headline.text = feed.trouble == nil ? "LOADING NEWS" : "NEWS FEED UNAVAILABLE"
        } else {
            // A bullet between stories, and one on the end as well: the crawl
            // wraps around to its own start, so without it the last headline
            // runs straight into the first.
            let separator = "   \u{2022}   "
            headline.text = feed.headlines.joined(separator: separator) + separator
        }
        rebuildZones()
    }

    private func weatherChanged() {
        rebuildZones()
    }

    /// The short form the board shows: a condition glyph and a temperature.
    private var weatherBoardText: String {
        guard let reading = weather.current else {
            // A degree sign with nothing in front of it holds the zone open at
            // roughly its eventual width, so the layout doesn't jump when the
            // first reading lands.
            return "\u{2014}\u{00B0}"
        }
        return reading.boardText(fahrenheit: Preferences.fahrenheit)
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

        if Preferences.isOn(.weather) {
            menu.addItem(.separator())
            let location = NSMenuItem(title: "Location: \(Preferences.weatherPlace)\u{2026}",
                                      action: #selector(chooseLocation), keyEquivalent: "")
            location.target = self
            menu.addItem(location)
            menu.addItem(submenu("Units", items: [
                (title: "Fahrenheit", checked: Preferences.fahrenheit,
                 represented: true as Any, image: nil),
                (title: "Celsius", checked: !Preferences.fahrenheit,
                 represented: false as Any, image: nil),
            ], action: #selector(chooseUnits(_:))))
        }

        menu.addItem(.separator())
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
        headlinesChanged()
    }

    @objc private func chooseLocation() {
        guard let entered = ask("Weather location",
                                explanation: "A city or town name.",
                                value: Preferences.weatherPlace) else { return }
        weather.place = entered
    }

    @objc private func chooseUnits(_ sender: NSMenuItem) {
        guard let fahrenheit = sender.representedObject as? Bool else { return }
        guard fahrenheit != Preferences.fahrenheit else { return }
        Preferences.fahrenheit = fahrenheit
        // The reading is held in Celsius, so this is a re-render, not a re-fetch.
        rebuildZones()
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
        headline.columnsPerSecond = speed
        trackLine.columnsPerSecond = speed
    }
}
