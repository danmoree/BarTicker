//
//  TickerView.swift
//  DotStrip
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

    /// The lit dots. Its mask holds the circles, its contents holds which of
    /// them are on; see the rendering section for why the two are separate.
    private let dotsLayer = CALayer()
    private var latticeSize: CGSize = .zero

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

        dotsLayer.magnificationFilter = .nearest
        dotsLayer.minificationFilter = .nearest
        dotsLayer.contentsGravity = .resize
        dotsLayer.allowsEdgeAntialiasing = false
        layer?.addSublayer(dotsLayer)

        applyDynamicRange()

        let step = 1.0 / Self.frameRate
        let t = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Nothing to compute while the menu bar is hidden behind a
            // fullscreen app or the display is asleep.
            if let window = self.window, !window.occlusionState.contains(.visible) { return }

            self.absolute += step
            if !self.isPaused { self.scrollClock += step }
            if self.rebuildColumns() { self.refreshDots() }
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
        // The panel and the unlit grid are SDR; only the lit dots are driven
        // past white, and they live in `dotsLayer`, which is tagged for
        // itself. `constrainedHigh` rather than `high` there: this shares the
        // menu bar with everything else and is never what the user is
        // looking at.
        layer.contents = backgroundImage(for: geometry())
        latticeSize = .zero     // colours or size may have moved under it
        refreshDots()
    }

    private func applyDynamicRange() { needsDisplay = true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        previous = []
        background = nil
        latticeSize = .zero
        needsDisplay = true
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

        // The grip is just more lit dots, so it goes in the buffer rather than
        // into a separate pass: that way the change check below covers it too,
        // and hovering doesn't need a repaint path of its own.
        if isPaused { addGrip(to: &columns) }

        defer { previous = columns }
        return columns != previous
    }

    /// Two short vertical rules on the leading edge, shown only while the
    /// pointer is over the board.
    private func addGrip(to columns: inout [DotColumn]) {
        for column in [0, 2] where column < columns.count {
            for row in 2..<(Board.rows - 2) {
                columns[column] |= (1 << DotColumn(row))
            }
        }
    }

    // MARK: Rendering
    //
    // The board is three layers that each change on their own schedule, which
    // is the whole point: the expensive one never changes.
    //
    //   * the view's own layer holds the panel and its unlit grid — redrawn
    //     only when the size or the colours do,
    //   * `dotsLayer` is masked to the dot lattice, a ring of antialiased
    //     circles rasterized once per size,
    //   * inside that mask its contents is a *one pixel per dot* image saying
    //     which dots are lit, magnified with nearest-neighbour sampling.
    //
    // So a frame costs one small buffer write and a texture upload of a few
    // kilobytes. Rasterizing the circles per frame — which is what this used
    // to do — was measured at 88% of the app's CPU.

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

    /// Where the dots live, in view coordinates. The lit map is stretched
    /// across exactly this rect, so one texel covers one dot cell.
    private func dotRect(for geo: Geometry) -> CGRect {
        CGRect(x: geo.xInset, y: geo.panel.minY,
               width: CGFloat(geo.visibleColumns) * geo.pitch,
               height: CGFloat(Board.rows) * geo.pitch)
    }

    /// Positions the dot layer and gives it the lattice to be masked by.
    private func layoutDots(for geo: Geometry) {
        let scale = window?.backingScaleFactor ?? 2
        let rect = dotRect(for: geo)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        dotsLayer.frame = rect
        dotsLayer.contentsFormat = .RGBA16Float
        if #available(macOS 26.0, *) {
            dotsLayer.preferredDynamicRange = usesHDR ? .constrainedHigh : .standard
        }

        guard geo.visibleColumns > 0, rect.width > 0, rect.height > 0 else {
            dotsLayer.mask = nil
            latticeSize = .zero
            return
        }

        if latticeSize == rect.size, dotsLayer.mask != nil { return }

        guard let lattice = latticeImage(for: geo, scale: scale) else { return }
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: rect.size)
        mask.contentsScale = scale
        mask.contentsGravity = .resize
        mask.contents = lattice
        dotsLayer.mask = mask
        latticeSize = rect.size
    }

    /// Every dot position as a filled circle, opaque on transparent. This is
    /// the antialiased rasterization that used to happen every frame; it now
    /// happens once per size and is reused as a mask for as long as the board
    /// keeps its width.
    private func latticeImage(for geo: Geometry, scale: CGFloat) -> CGImage? {
        let rect = dotRect(for: geo)
        let pw = Int(rect.width * scale), ph = Int(rect.height * scale)
        guard pw > 0, ph > 0, let ctx = makeContext(pixelWidth: pw, pixelHeight: ph),
              let space = Self.workingSpace else { return nil }

        ctx.scaleBy(x: scale, y: scale)

        let dotSize = geo.pitch * dotFill
        let inset = (geo.pitch - dotSize) / 2
        let path = CGMutablePath()
        for column in 0..<geo.visibleColumns {
            let x = CGFloat(column) * geo.pitch + inset
            for row in 0..<Board.rows {
                let y = rect.height - CGFloat(row + 1) * geo.pitch + inset
                path.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
            }
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// One pixel per dot: lit dots carry the board's colour, dark ones are
    /// clear. A few kilobytes at most, which is the entire per-frame cost.
    ///
    /// Written straight into the bitmap rather than drawn: at one pixel a dot
    /// there is no shape to rasterize, and bitmap rows run top-down while
    /// drawing coordinates do not — writing the buffer keeps board row 0 and
    /// image row 0 the same row.
    private func litImage(for geo: Geometry) -> CGImage? {
        let cols = geo.visibleColumns
        guard cols > 0, columns.count == cols,
              let ctx = makeContext(pixelWidth: cols, pixelHeight: Board.rows),
              let data = ctx.data,
              let source = theme.on.usingColorSpace(.sRGB) else { return nil }

        let gain = usesHDR ? hdrGain : 1.0
        let alpha = Float(source.alphaComponent)
        // Premultiplied, and the alpha of a lit dot is 1, so the stored
        // components are the linear ones as they stand.
        let rgba: [Float] = [
            Float(linear(source.redComponent) * gain) * alpha,
            Float(linear(source.greenComponent) * gain) * alpha,
            Float(linear(source.blueComponent) * gain) * alpha,
            alpha,
        ]

        let rowBytes = ctx.bytesPerRow
        let base = data.assumingMemoryBound(to: UInt8.self)
        // The context arrives zeroed, so only the lit dots need writing.
        for row in 0..<Board.rows {
            let pixels = (base + row * rowBytes).withMemoryRebound(to: Float.self,
                                                                  capacity: cols * 4) { $0 }
            let bit: DotColumn = 1 << DotColumn(row)
            for column in 0..<cols where columns[column] & bit != 0 {
                let offset = column * 4
                pixels[offset]     = rgba[0]
                pixels[offset + 1] = rgba[1]
                pixels[offset + 2] = rgba[2]
                pixels[offset + 3] = rgba[3]
            }
        }

        guard let image = ctx.makeImage() else { return nil }
        guard usesHDR else { return image }

        // Untagged, the extended values are just tone mapped back to SDR.
        // Nothing reaches this below macOS 26 — `displaySupportsHDR` is false
        // there, so `usesHDR` is too — but the compiler still wants the check.
        guard #available(macOS 15.0, *) else { return image }
        return CGImageCreateCopyWithContentHeadroom(Float(gain), image) ?? image
    }

    /// Hands the current dot pattern to the compositor.
    private func refreshDots() {
        let geo = geometry()
        guard geo.visibleColumns > 0 else { return }

        // Only when the board has actually moved under the dots: rebuilding
        // the lattice means rasterizing every circle again, which is the one
        // expensive thing left in here.
        if latticeSize != dotRect(for: geo).size { layoutDots(for: geo) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no crossfade between frames
        dotsLayer.contents = litImage(for: geo)
        CATransaction.commit()
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
}
