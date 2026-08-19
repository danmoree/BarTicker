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

    /// Drives the lit dots past SDR white on displays with headroom.
    ///
    /// Only the lit dots are boosted — the panel and the unlit grid stay put.
    /// That is the whole point: on a real sign the emitter is far brighter than
    /// the mask around it, and SDR cannot express that ratio because the
    /// brightest thing it has is paper white.
    var usesHDR = false {
        didSet {
            guard usesHDR != oldValue else { return }
            applyDynamicRange()
            background = nil
            previous = []
            needsDisplay = true
        }
    }

    /// How far past SDR white a lit dot is driven.
    var hdrGain: CGFloat = 5.0

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
    private var background: CGImage?
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
        applyDynamicRange()

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

    /// Drawing happens into our own bitmap, which is then handed to the layer.
    ///
    /// This is not a stylistic choice. Anything rendered through `draw(_:)` is
    /// clamped at SDR white no matter what colours you feed it — verified by
    /// capturing the screen in HDR and measuring, with both plain out-of-range
    /// colours and properly headroom-tagged ones. The only route to real EDR
    /// short of Metal is to render an extended-range image yourself, tag it
    /// with its content headroom, and set it as `contents`.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.contentsGravity = .resize
        layer.contentsFormat = .RGBA16Float
        if #available(macOS 26.0, *) {
            // `constrainedHigh` rather than `high`: this shares the menu bar
            // with everything else and is never what the user is looking at.
            layer.preferredDynamicRange = usesHDR ? .constrainedHigh : .standard
        }
        layer.contents = renderBoard()
    }

    private func applyDynamicRange() { needsDisplay = true }

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

    /// Points per dot column, for callers that need to turn a column count
    /// into a board width — sizing the status item to fit its windows, say.
    var dotPitch: CGFloat { geometry().pitch }

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

    // MARK: Rendering

    /// sRGB components are perceptual; the bitmap is linear. Converting is what
    /// keeps the amber the same amber instead of a darker one.
    private func linear(_ value: CGFloat) -> CGFloat {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func color(_ source: NSColor, gain: CGFloat) -> CGColor? {
        guard let space = Self.workingSpace,
              let c = source.usingColorSpace(.sRGB) else { return nil }
        return CGColor(colorSpace: space, components: [
            linear(c.redComponent) * gain,
            linear(c.greenComponent) * gain,
            linear(c.blueComponent) * gain,
            c.alphaComponent,
        ])
    }

    private static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

    private func makeContext(pixelWidth: Int, pixelHeight: Int) -> CGContext? {
        guard let space = Self.workingSpace else { return nil }
        let info = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                         bitsPerComponent: 32, bytesPerRow: 0,
                         space: space, bitmapInfo: info)
    }

    private func renderBoard() -> CGImage? {
        let geo = geometry()
        let scale = window?.backingScaleFactor ?? 2
        let pw = Int(bounds.width * scale), ph = Int(bounds.height * scale)
        guard pw > 0, ph > 0, let ctx = makeContext(pixelWidth: pw, pixelHeight: ph) else { return nil }

        ctx.scaleBy(x: scale, y: scale)

        if let base = backgroundImage(for: geo) {
            ctx.draw(base, in: bounds)
        }

        guard geo.visibleColumns > 0, !columns.isEmpty,
              let lit = color(theme.on, gain: usesHDR ? hdrGain : 1.0) else {
            return ctx.makeImage()
        }

        let dotSize = geo.pitch * dotFill
        let inset = (geo.pitch - dotSize) / 2
        let path = CGMutablePath()

        for (column, bits) in columns.enumerated() where bits != 0 {
            let x = geo.xInset + CGFloat(column) * geo.pitch + inset
            for row in 0..<Board.rows where bits & (1 << DotColumn(row)) != 0 {
                let y = geo.panel.maxY - CGFloat(row + 1) * geo.pitch + inset
                path.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
            }
        }

        if isPaused, geo.pitch > 0 {
            addGrip(to: path, geo: geo, dotSize: dotSize, inset: inset)
        }

        ctx.addPath(path)
        ctx.setFillColor(lit)
        ctx.fillPath()

        guard let image = ctx.makeImage() else { return nil }
        guard usesHDR else { return image }

        // Untagged, the extended values are just tone mapped back to SDR.
        // Nothing reaches this below macOS 26 — `displaySupportsHDR` is false
        // there, so `usesHDR` is too — but the compiler still wants the check.
        guard #available(macOS 15.0, *) else { return image }
        return CGImageCreateCopyWithContentHeadroom(Float(hdrGain), image) ?? image
    }

    /// Panel and unlit grid, rendered once per size/scheme and reused.
    private func backgroundImage(for geo: Geometry) -> CGImage? {
        if let background, backgroundSize == bounds.size { return background }

        let scale = window?.backingScaleFactor ?? 2
        let pw = Int(bounds.width * scale), ph = Int(bounds.height * scale)
        guard pw > 0, ph > 0, let ctx = makeContext(pixelWidth: pw, pixelHeight: ph),
              let panel = color(theme.panel, gain: 1.0),
              let unlit = color(theme.off, gain: 1.0) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        ctx.addPath(CGPath(roundedRect: geo.panel, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(panel)
        ctx.fillPath()

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
            ctx.addPath(dark)
            ctx.setFillColor(unlit)
            ctx.fillPath()
        }

        background = ctx.makeImage()
        backgroundSize = bounds.size
        return background
    }

    /// Two short vertical rules on the leading edge, shown only while the
    /// pointer is over the board.
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
}
