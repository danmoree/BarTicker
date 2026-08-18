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

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let sampleText = """
    BREAKING — this is a deliberately long sentence whose entire purpose is to \
    overflow the menu bar and prove that a dot-matrix news crawl is actually \
    readable up here, at which point you get to decide whether the idea is any \
    good.   •••   
    """

    private var statusItem: NSStatusItem?
    private var ticker: TickerView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

        let item = NSStatusBar.system.statusItem(withLength: 320)
        guard let button = item.button else { return }

        let ticker = TickerView(frame: button.bounds)
        ticker.autoresizingMask = [.width, .height]
        ticker.text = Self.sampleText
        button.addSubview(ticker)

        let menu = NSMenu()
        menu.addItem(withTitle: "pixelScreen", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        self.statusItem = item
        self.ticker = ticker
    }
}
