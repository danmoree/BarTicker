//
//  Feed.swift
//  DotStrip
//
//  Headlines for the news ticker, from any RSS or Atom feed.
//
//  Parsed with XMLParser rather than a regex over the markup: feeds in the
//  wild wrap titles in CDATA, escape entities inconsistently, and nest the
//  same tag names at different depths (a channel has a <title> too). The
//  parser handles all three, and the delegate below only has to say which
//  <title> it actually wants.
//

import Foundation
import OSLog

final class FeedMonitor {

    /// Titles, most recent first. Empty until the first fetch lands.
    private(set) var headlines: [String] = []

    /// Set when the last fetch failed, for the menu to report.
    private(set) var trouble: String?

    var onChange: (() -> Void)?

    /// Changing this drops what's on screen and fetches again, so switching
    /// feeds doesn't leave the old outlet's headlines crawling past.
    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            headlines = []
            trouble = nil
            onChange?()
            refresh()
        }
    }

    /// Feeds update on the order of minutes and the panel is up all day, so
    /// this is deliberately unhurried.
    private let interval: TimeInterval = 10 * 60

    /// How many headlines make one lap of the crawl. A full feed would take
    /// several minutes to read past at normal speed.
    private let limit = 12

    private var timer: Timer?
    private var task: URLSessionDataTask?

    private let log = Logger(subsystem: "com.danielmoreno.projects.DotStrip",
                             category: "feed")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["User-Agent": "DotStrip/1.0"]
        return URLSession(configuration: config)
    }()

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    // MARK: Fetching

    func refresh() {
        guard let url else { return }

        task?.cancel()
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }

            // A cancelled request is us replacing it, not a failure worth
            // showing anyone.
            if let error = error as? URLError, error.code == .cancelled { return }

            let titles: [String]?
            var problem: String?

            if let error {
                problem = error.localizedDescription
                titles = nil
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
                problem = "Feed returned HTTP \(code)"
                titles = nil
            } else if let data {
                let parsed = FeedParser.titles(in: data)
                if parsed.isEmpty {
                    problem = "No headlines in that feed"
                    titles = nil
                } else {
                    titles = Array(parsed.prefix(self.limit))
                }
            } else {
                problem = "Empty response"
                titles = nil
            }

            DispatchQueue.main.async {
                if let titles {
                    // Same headlines as last time is the common case; saying so
                    // would restart the crawl from the left every 10 minutes.
                    guard titles != self.headlines || self.trouble != nil else { return }
                    self.headlines = titles
                    self.trouble = nil
                } else {
                    self.log.error("fetch failed: \(problem ?? "unknown", privacy: .public)")
                    // Headlines already up stay up: a dropped connection is no
                    // reason to blank a board that has something to show.
                    guard self.trouble != problem else { return }
                    self.trouble = problem
                }
                self.onChange?()
            }
        }
        self.task = task
        task.resume()
    }
}

// MARK: - Parsing

/// Collects the titles of a feed's entries, ignoring the feed's own title.
private final class FeedParser: NSObject, XMLParserDelegate {

    static func titles(in data: Data) -> [String] {
        let parser = XMLParser(data: data)
        let delegate = FeedParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.found
    }

    /// RSS calls one story an `item`, Atom calls it an `entry`.
    private static let containers: Set<String> = ["item", "entry"]

    private var found: [String] = []
    private var insideItem = false
    private var capturing = false
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if Self.containers.contains(element) {
            insideItem = true
        } else if insideItem, element == "title" {
            // Only the first title in an item: some feeds carry a second one
            // inside a media or content block.
            capturing = found.count == foundBeforeThisItem
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if Self.containers.contains(element) {
            insideItem = false
            capturing = false
            foundBeforeThisItem = found.count
        } else if capturing, element == "title" {
            capturing = false
            let title = Self.tidy(buffer)
            if !title.isEmpty { found.append(title) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard capturing, let text = String(data: block, encoding: .utf8) else { return }
        buffer += text
    }

    /// Tracks whether this item has already given up its title.
    private var foundBeforeThisItem = 0

    /// The board draws one line of dots: newlines and runs of spaces in a
    /// headline would come out as a long unexplained gap.
    private static func tidy(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
