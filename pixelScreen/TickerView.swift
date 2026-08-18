//
//  TickerView.swift
//  pixelScreen
//
//  An LED-style dot panel. It scrolls in whole dot-columns rather than smooth
//  subpixel steps, which is what makes it read as a physical board.
//
//  The view owns the clock and the geometry; what actually lights up comes from
//  the zones it's given (see Board.swift). It rebuilds the dot buffer every
//  frame but only repaints when the buffer actually changed, so a still panel
//  costs nothing.
//

import AppKit

final class TickerView: NSView {

    // MARK: Look & feel

    /// Dot diameter as a fraction of the spacing between dot centres.
    private let dotFill: CGFloat = 0.85

    /// Changing this throws away the cached grid: the unlit dots are baked into
    /// it, so it is wrong the moment the scheme changes.
    var theme: BoardTheme = .amber {
        didSet {
            guard theme != oldValue else { return }
            background = nil
            previous = []
            needsDisplay = true
        }
    }

    /// 30 divides evenly into the scroll speeds on offer, so text advances by a
    /// whole number of columns every frame instead of stalling on some of them.
    static let frameRate: Double = 30

    // MARK: Content

    /// Called while the grip is dragged, with the width the board should take.
    var onResize: ((CGFloat) -> Void)?

    /// Width of the drag strip on the leading edge. Status items are anchored
    /// to the right, so dragging this edge leftwards widens the board, which is
    /// the direction it visibly grows.
    private let gripWidth: CGFloat = 10

    var zones: [Zone] = [] {
        didSet {
            previous = []          // force a repaint on the next tick
        }
    }

    // MARK: State

    private var columns: [DotColumn] = []
    private var previous: [DotColumn] = []
    private var absolute: CFTimeInterval = 0
    private var scrollClock: CFTimeInterval = 0
    private var timer: Timer?
    private var isPaused = false
    private var dragAnchor: CGFloat?
    private var dragStartWidth: CGFloat = 0

    /// The panel and its unlit dots never change, so they're rendered once and
    /// replayed each frame. Only lit dots are drawn per frame — for a view that
    /// sits on screen animating forever, that is the difference between cheap
    /// and expensive.
    private var background: CGLayer?
    private var backgroundSize: CGSize = .zero

    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        start()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        start()
    }

    deinit { timer?.invalidate() }

    private func start() {
        // Layer-backed so a repaint composites the view's own surface instead
        // of dragging the whole translucent menu bar through a redraw.
        wantsLayer = true
        layer?.drawsAsynchronously = false

        let step = 1.0 / Self.frameRate
        let t = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Nothing to compute while the menu bar is hidden behind a
            // fullscreen app or the display is asleep.
            if let window = self.window, !window.occlusionState.contains(.visible) { return }

            self.absolute += step
            if !self.isPaused { self.scrollClock += step }
            if self.rebuildColumns() { self.needsDisplay = true }
        }
        // .common so the panel keeps animating while menus are tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        previous = []
        background = nil
    }

    // MARK: Hover to pause

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isPaused = true
        previous = []           // repaint to show the grip
    }

    override func mouseExited(with event: NSEvent) {
        isPaused = false
        previous = []
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    /// Only the grip takes the mouse. Everywhere else clicks fall through to
    /// the status item button so its menu still opens.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return convert(point, from: superview).x <= gripWidth ? self : nil
    }

    // MARK: Resizing

    override func mouseDown(with event: NSEvent) {
        dragAnchor = NSEvent.mouseLocation.x
        dragStartWidth = bounds.width
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        // Global coordinates: the view itself slides as the board resizes, so
        // its own coordinate space is not a stable reference mid-drag.
        let widened = dragAnchor - NSEvent.mouseLocation.x
        onResize?(dragStartWidth + widened)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    // MARK: Geometry

    private struct Geometry {
        var panel: CGRect
        var pitch: CGFloat
        var visibleColumns: Int
        var xInset: CGFloat
    }

    private func geometry() -> Geometry {
        let panel = bounds.insetBy(dx: 0, dy: 1)
        let pitch = panel.height / CGFloat(Board.rows)
        guard pitch > 0 else {
            return Geometry(panel: panel, pitch: 0, visibleColumns: 0, xInset: 0)
        }
        let visible = max(0, Int(bounds.width / pitch))
        let xInset = (bounds.width - CGFloat(visible) * pitch) / 2
        return Geometry(panel: panel, pitch: pitch, visibleColumns: visible, xInset: xInset)
    }

    // MARK: Frame build

    /// Redraws the dot buffer from the zones. Returns whether anything changed.
    private func rebuildColumns() -> Bool {
        let geo = geometry()
        guard geo.visibleColumns > 0 else { return false }

        if columns.count == geo.visibleColumns {
            for i in columns.indices { columns[i] = 0 }
        } else {
            columns = [DotColumn](repeating: 0, count: geo.visibleColumns)
        }

        let time = BoardTime(absolute: absolute, scroll: scrollClock)
        let ranges = Zone.layout(zones, total: geo.visibleColumns)

        columns.withUnsafeMutableBufferPointer { buffer in
            for (zone, range) in zip(zones, ranges) where !range.isEmpty {
                let slice = UnsafeMutableBufferPointer(rebasing: buffer[range])
                for layer in zone.layers {
                    layer.render(into: slice, at: time)
                }
            }
        }

        defer { previous = columns }
        return columns != previous
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let geo = geometry()
        if let layer = backgroundLayer(for: geo, in: ctx) {
            ctx.draw(layer, at: .zero)
        }

        guard geo.visibleColumns > 0, !columns.isEmpty else { return }

        let dotSize = geo.pitch * dotFill
        let inset = (geo.pitch - dotSize) / 2
        let lit = CGMutablePath()

        for (column, bits) in columns.enumerated() where bits != 0 {
            let x = geo.xInset + CGFloat(column) * geo.pitch + inset
            for row in 0..<Board.rows where bits & (1 << DotColumn(row)) != 0 {
                // Row 0 is the top of the panel; the view is bottom-up.
                let y = geo.panel.maxY - CGFloat(row + 1) * geo.pitch + inset
                lit.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
            }
        }

        if isPaused, geo.pitch > 0 {
            addGrip(to: lit, geo: geo, dotSize: dotSize, inset: inset)
        }

        ctx.addPath(lit)
        ctx.setFillColor(theme.on.cgColor)
        ctx.fillPath()
    }

    /// Two short vertical rules on the leading edge, shown only while the
    /// pointer is over the board — the handle should be findable without
    /// permanently spending columns that the text wants.
    private func addGrip(to path: CGMutablePath, geo: Geometry,
                         dotSize: CGFloat, inset: CGFloat) {
        for column in [0, 2] {
            let x = geo.xInset + CGFloat(column) * geo.pitch + inset
            for row in 2..<(Board.rows - 2) {
                let y = geo.panel.maxY - CGFloat(row + 1) * geo.pitch + inset
                path.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
            }
        }
    }

    /// The unlit grid, rendered once per size and replayed thereafter.
    private func backgroundLayer(for geo: Geometry, in ctx: CGContext) -> CGLayer? {
        if let background, backgroundSize == bounds.size { return background }
        guard bounds.width > 0, bounds.height > 0,
              let layer = CGLayer(ctx, size: bounds.size, auxiliaryInfo: nil),
              let layerContext = layer.context else { return nil }

        layerContext.addPath(CGPath(roundedRect: geo.panel, cornerWidth: 3,
                                    cornerHeight: 3, transform: nil))
        layerContext.setFillColor(theme.panel.cgColor)
        layerContext.fillPath()

        if geo.visibleColumns > 0 {
            let dotSize = geo.pitch * dotFill
            let inset = (geo.pitch - dotSize) / 2
            let dark = CGMutablePath()

            for column in 0..<geo.visibleColumns {
                let x = geo.xInset + CGFloat(column) * geo.pitch + inset
                for row in 0..<Board.rows {
                    let y = geo.panel.maxY - CGFloat(row + 1) * geo.pitch + inset
                    dark.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
                }
            }

            layerContext.addPath(dark)
            layerContext.setFillColor(theme.off.cgColor)
            layerContext.fillPath()
        }

        background = layer
        backgroundSize = bounds.size
        return layer
    }
}
