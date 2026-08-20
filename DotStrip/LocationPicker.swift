//
//  LocationPicker.swift
//  DotStrip
//
//  Picking the weather location from a list of real places.
//
//  This replaces a text prompt. A prompt asks for a name and then quietly
//  resolves it to whichever match ranked first, which is a coin toss for the
//  Portlands, Cambridges and San Josés of the world — and the board goes on
//  showing the name that was typed, so a wrong guess never looks wrong. Here
//  the search is the same but the choice is visible: region, country, size and
//  coordinates for every candidate, and nothing is stored until one is picked.
//

import AppKit

final class LocationPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                            NSSearchFieldDelegate, NSWindowDelegate {

    static let shared = LocationPicker()

    private var window: NSWindow?
    private var searchField: NSSearchField!
    private var table: NSTableView!
    private var status: NSTextField!
    private var useButton: NSButton!

    private var results: [GeocodedPlace] = []
    private var onPick: ((GeocodedPlace) -> Void)?

    /// Typing outruns the network, so a keystroke schedules a search rather
    /// than starting one, and any search still in flight is dropped.
    private var pending: DispatchWorkItem?
    private var task: URLSessionTask?
    private let typingDelay: TimeInterval = 0.3

    private override init() { super.init() }

    // MARK: Presenting

    /// Opens the picker, seeded with the place already in use so the common
    /// case — correcting a guess to the right town of that name — is one search
    /// the user did not have to type.
    func present(query: String, onPick: @escaping (GeocodedPlace) -> Void) {
        self.onPick = onPick

        let window = window ?? makeWindow()
        self.window = window

        searchField.stringValue = query
        results = []
        table.reloadData()
        show(status: query.isEmpty ? "Type a city or town name." : "Searching\u{2026}")
        useButton.isEnabled = false

        // Menu bar apps are not active when their menu is used, so a window
        // ordered front from here would open behind whatever is in front.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)

        if !query.isEmpty { search(query) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 440),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Weather Location"
        window.delegate = self
        // The picker is opened from a menu and dismissed by choosing; keeping
        // it around means the next visit reuses the table and its geometry.
        window.isReleasedWhenClosed = false

        let search = NSSearchField()
        search.placeholderString = "City or town"
        search.delegate = self
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = false
        searchField = search

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 46
        table.style = .inset
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(useSelection)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place")))
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        self.status = status

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded

        let use = NSButton(title: "Use Location", target: self, action: #selector(useSelection))
        use.keyEquivalent = "\r"
        use.bezelStyle = .rounded
        use.isEnabled = false
        useButton = use

        let buttons = NSStackView(views: [status, NSView(), cancel, use])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        // The status text takes the slack; the buttons keep their own size.
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        return window
    }

    // MARK: Searching

    private func searchAfterTyping() {
        pending?.cancel()
        let query = searchField.stringValue

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            task?.cancel()
            results = []
            table.reloadData()
            useButton.isEnabled = false
            show(status: "Type a city or town name.")
            return
        }

        let work = DispatchWorkItem { [weak self] in self?.search(query) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typingDelay, execute: work)
    }

    private func search(_ query: String) {
        show(status: "Searching\u{2026}")
        task?.cancel()
        task = PlaceSearch.run(query) { [weak self] outcome in
            guard let self, self.searchField.stringValue == query else { return }

            switch outcome {
            case .success(let places):
                self.results = places
                self.table.reloadData()
                if places.isEmpty {
                    self.useButton.isEnabled = false
                    self.show(status: "No place called \u{201C}\(query)\u{201D}.")
                } else {
                    // The first row is the service's best guess, selected so
                    // Return does the obvious thing — but visibly, and next to
                    // the alternatives it was picked over.
                    self.table.selectRowIndexes([0], byExtendingSelection: false)
                    self.table.scrollRowToVisible(0)
                    self.useButton.isEnabled = true
                    self.show(status: places.count == 1
                              ? "1 match" : "\(places.count) matches \u{2014} pick one")
                }
            case .failure(let failure):
                self.results = []
                self.table.reloadData()
                self.useButton.isEnabled = false
                self.show(status: failure.message)
            }
        }
    }

    private func show(status message: String) {
        status.stringValue = message
        status.toolTip = message
    }

    // MARK: Choosing

    @objc private func useSelection() {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard results.indices.contains(row) else { return }
        let place = results[row]

        close()
        onPick?(place)
        onPick = nil
    }

    @objc private func cancel() {
        close()
        onPick = nil
    }

    private func close() {
        pending?.cancel()
        task?.cancel()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        pending?.cancel()
        task?.cancel()
        onPick = nil
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) {
        searchAfterTyping()
    }

    /// Down-arrow out of the field and into the list, the way a search field
    /// with results under it is expected to behave.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), !results.isEmpty else { return false }
        window?.makeFirstResponder(table)
        if table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PlaceRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? PlaceRow
            ?? PlaceRow(identifier: identifier)
        view.show(results[row])
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        useButton.isEnabled = table.selectedRow >= 0
    }
}

/// Two lines per candidate: what the place is called, and everything needed to
/// tell it from the other place called that.
private final class PlaceRow: NSTableCellView {

    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Set so the table recolours the title on a selected row for us.
        textField = name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ place: GeocodedPlace) {
        name.stringValue = [place.flag, place.name].compactMap { $0 }.joined(separator: "  ")

        // Region and country first, since that is what the choice usually
        // turns on; size and coordinates settle the rest.
        var parts = [place.detail.isEmpty ? "Unknown region" : place.detail]
        if let population = place.populationText { parts.append(population) }
        parts.append(place.coordinates)
        detail.stringValue = parts.joined(separator: "  \u{00B7}  ")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            detail.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            detail.alphaValue = selected ? 0.85 : 1
        }
    }
}
