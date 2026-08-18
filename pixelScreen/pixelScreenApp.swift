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

    /// Placeholder until a real ticker source is wired up.
    private static let sampleText = """
    BREAKING — this is a deliberately long sentence whose entire purpose is to \
    overflow the menu bar and prove that a dot-matrix news crawl is actually \
    readable up here, at which point you get to decide whether the idea is any \
    good.   •••   
    """

    private var statusItem: NSStatusItem?
    private var ticker: TickerView?

    // Layers are long-lived so their scroll position and peak-hold state
    // survive switching modes back and forth.
    private let headline = TextLayer()
    private let trackLine = TextLayer()
    private let progress = ProgressLayer()

    private let nowPlaying = NowPlayingMonitor()

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

        headline.text = Self.sampleText
        headline.scroll = .always
        trackLine.scroll = .ifOverflow
        progress.source = { [weak self] in self?.nowPlaying.current?.fraction ?? 0 }

        nowPlaying.onChange = { [weak self] info in self?.trackChanged(to: info) }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.statusItem = item
        self.ticker = ticker

        // A width stored on a roomier setup may not fit this one.
        applyBoardWidth(CGFloat(Preferences.boardWidth))
        applyMode()

    }

    // MARK: Wiring

    private func applyMode() {
        headline.columnsPerSecond = Preferences.scrollSpeed
        trackLine.columnsPerSecond = Preferences.scrollSpeed

        switch Preferences.mode {
        case .ticker:
            nowPlaying.stop()
        case .nowPlaying:
            nowPlaying.start()
        }
        rebuildZones()
    }

    private func rebuildZones() {
        guard let ticker else { return }

        switch Preferences.mode {
        case .ticker:
            ticker.zones = [Zone(.flexible, [headline])]

        case .nowPlaying:
            var layers: [BoardLayer] = [trackLine]
            if Preferences.showProgress { layers.append(progress) }
            ticker.zones = [Zone(.flexible, layers)]
        }
    }

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
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(header("Mode"))
        menu.addItem(choice("News Ticker", #selector(chooseTicker),
                            checked: Preferences.mode == .ticker))
        menu.addItem(choice("Now Playing", #selector(chooseNowPlaying),
                            checked: Preferences.mode == .nowPlaying))

        if Preferences.mode == .nowPlaying {
            menu.addItem(.separator())
            menu.addItem(choice("Progress Bar", #selector(toggleProgress),
                                checked: Preferences.showProgress))
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

    private var statusLine: String {
        switch Preferences.mode {
        case .ticker:
            return "News Ticker"
        case .nowPlaying:
            if let track = nowPlaying.current {
                return "\(track.title) — \(track.artist)"
            }
            return nowPlaying.trouble == .notAuthorized
                ? "Automation permission needed"
                : "Nothing playing"
        }
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

    // MARK: Menu actions

    @objc private func chooseTicker() {
        Preferences.mode = .ticker
        applyMode()
    }

    @objc private func chooseNowPlaying() {
        Preferences.mode = .nowPlaying
        applyMode()
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
