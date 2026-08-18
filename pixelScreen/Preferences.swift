//
//  Preferences.swift
//  pixelScreen
//

import AppKit

enum BoardMode: String {
    /// A headline crawling across the whole panel.
    case ticker
    /// Track title and progress bar.
    case nowPlaying
}

enum Preferences {

    private enum Key {
        static let mode = "mode"
        static let showProgress = "showProgress"
        static let scrollSpeed = "scrollSpeed"
        static let boardWidth = "boardWidth"
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.mode: BoardMode.nowPlaying.rawValue,
            Key.showProgress: true,
            Key.scrollSpeed: 30.0,
            Key.boardWidth: defaultBoardWidth,
        ])
    }

    static var mode: BoardMode {
        get { BoardMode(rawValue: UserDefaults.standard.string(forKey: Key.mode) ?? "") ?? .nowPlaying }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.mode) }
    }

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
