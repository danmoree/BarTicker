//
//  NowPlaying.swift
//  DotStrip
//
//  Reads the currently playing track from Spotify or Music.
//
//  This goes through AppleScript rather than MediaRemote on purpose: Apple
//  entitlement-gated MediaRemote in macOS 15.4, so the private-framework trick
//  every menu bar player used to rely on returns nothing now. The cost of the
//  supported route is that it only reaches apps with a scripting dictionary —
//  a track playing in a browser tab is invisible to us.
//
//  Both apps post a distributed notification when playback changes, so the
//  poll below is only a safety net for the cases they don't announce (seeking,
//  and position drift while paused).
//

import AppKit
import OSLog

struct NowPlaying: Equatable {
    var app: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool

    /// Seconds, as of `sampledAt`.
    var position: Double
    var duration: Double
    var sampledAt: CFTimeInterval

    /// Position carried forward to `time`, so the progress bar keeps moving
    /// between polls instead of stepping once every couple of seconds.
    func position(at time: CFTimeInterval) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + (time - sampledAt))
    }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return position(at: CACurrentMediaTime()) / duration
    }

    /// Equality ignores the sample time so a re-poll of the same track doesn't
    /// look like a change.
    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.app == b.app && a.title == b.title && a.artist == b.artist
            && a.album == b.album && a.isPlaying == b.isPlaying
            && abs(a.position - b.position) < 1.5 && a.duration == b.duration
    }
}

final class NowPlayingMonitor {

    enum Trouble: Error, Equatable {
        case notAuthorized      // user declined the Automation prompt
        case nothingPlaying
    }

    private(set) var current: NowPlaying?
    private(set) var trouble: Trouble? = .nothingPlaying

    var onChange: ((NowPlaying?) -> Void)?

    private var timer: Timer?
    private var compiled: [String: NSAppleScript] = [:]

    /// Held so they can be handed back. The block-based observer API registers
    /// an opaque token rather than the caller, so `removeObserver(self)` takes
    /// nothing away — and a stopped monitor would keep running AppleScript
    /// every time a player announced a change.
    private var observers: [NSObjectProtocol] = []

    /// The first poll has to report even when it finds nothing, otherwise the
    /// panel sits empty because "no track" matches the state we started in.
    private var hasReported = false
    private var lastRefresh: CFTimeInterval = 0

    private let log = Logger(subsystem: "com.danielmoreno.projects.DotStrip",
                             category: "nowPlaying")

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }

        let notifications = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged",
                     "com.apple.iTunes.playerInfo"] {
            let observer = notifications.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            observers.append(observer)
        }

        // Only a safety net: the notifications above catch every real change,
        // and position is interpolated between polls.
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
        current = nil

        // The next start has to report whatever it finds, including nothing:
        // its first poll is compared against the state we are leaving here.
        hasReported = false
    }

    // MARK: Polling

    func refresh() {
        // Spotify fires several notifications per state change; running the
        // script for each one puts needless AppleScript on the main thread.
        let now = CACurrentMediaTime()
        guard now - lastRefresh > 0.3 else { return }
        lastRefresh = now

        apply(runScript())
    }

    private func apply(_ result: Result<String, Trouble>) {
        let previous = current
        let previousTrouble = trouble

        switch result {
        case .failure(let why):
            current = nil
            trouble = why
        case .success(let raw):
            if let parsed = Self.parse(raw) {
                current = parsed
                trouble = nil
            } else {
                current = nil
                trouble = .nothingPlaying
            }
        }

        if !hasReported || current != previous || trouble != previousTrouble {
            hasReported = true
            onChange?(current)
        }
    }

    // MARK: AppleScript

    private struct Player {
        let bundleID: String
        let name: String
        /// Spotify reports track length in milliseconds and Music in seconds.
        let durationScale: Double
    }

    /// Which player wins when both are running, most preferred first.
    private static let players = [
        Player(bundleID: "com.spotify.client", name: "Spotify", durationScale: 0.001),
        Player(bundleID: "com.apple.Music", name: "Music", durationScale: 1.0),
    ]

    /// Tab-delimited: app, title, artist, album, position, duration, playing.
    ///
    /// Addressed by bundle id rather than by name, and with no blanket `try`:
    /// inside the sandbox `application "Spotify" is running` answers false and a
    /// wrapping `try` swallows the authorization error along with it, which
    /// leaves you staring at an empty panel with nothing in the log.
    private static func source(for player: Player) -> String {
        """
        tell application id "\(player.bundleID)"
            if player state is stopped then return ""
            set p to 0
            try
                set p to player position
            end try
            set s to "0"
            if player state is playing then set s to "1"
            return "\(player.name)" & tab & (name of current track) & tab & ¬
                (artist of current track) & tab & (album of current track) & tab & ¬
                (p as text) & tab & \
                (((duration of current track) * \(player.durationScale)) as text) & tab & s
        end tell
        """
    }

    /// NSAppleScript runs in-process, which matters here: this target is
    /// sandboxed, and a spawned `osascript` would inherit the sandbox and lose
    /// the Apple Events entitlement along the way.
    private func runScript() -> Result<String, Trouble> {
        for player in Self.players {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: player.bundleID)
            guard !running.isEmpty else { continue }

            guard let script = compiledScript(for: player) else { continue }

            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)

            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                log.error("\(player.name) script failed: \(code, privacy: .public)")
                // -1743 is a declined Automation prompt. Anything else is
                // usually the app shutting down mid-script.
                if code == -1743 { return .failure(.notAuthorized) }
                continue
            }

            let text = result.stringValue ?? ""
            if !text.isEmpty { return .success(text) }
        }
        return .failure(.nothingPlaying)
    }

    private func compiledScript(for player: Player) -> NSAppleScript? {
        if let existing = compiled[player.bundleID] { return existing }
        guard let script = NSAppleScript(source: Self.source(for: player)) else {
            log.error("could not compile script for \(player.name, privacy: .public)")
            return nil
        }
        compiled[player.bundleID] = script
        return script
    }

    private static func parse(_ raw: String) -> NowPlaying? {
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        guard fields.count >= 7, !fields[1].isEmpty else { return nil }

        return NowPlaying(
            app: fields[0],
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            isPlaying: fields[6] == "1",
            position: Double(fields[4]) ?? 0,
            duration: Double(fields[5]) ?? 0,
            sampledAt: CACurrentMediaTime()
        )
    }
}
