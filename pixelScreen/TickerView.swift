//
//  TickerView.swift
//  pixelScreen
//
//  An LED-style scrolling ticker. Scrolls in whole dot-columns rather than
//  smooth subpixel steps, which is what makes it read as a physical board.
//

import AppKit

final class TickerView: NSView {

    // MARK: Look & feel

    private let rows = PixelFont.rows
    private let gapColumns = 16              // blank columns between loops
    private let columnsPerSecond: Double = 26

    /// Dot diameter as a fraction of the spacing between dot centres.
    private let dotFill: CGFloat = 0.85

    /// Blank dot-rows above the capitals. Matching the descender rows below
    /// the baseline keeps the text optically centred: capitals would otherwise
    /// sit flush against the top edge while the empty descender rows below
    /// read as padding.
    var topMarginRows = PixelFont.descenderRows

    private let onColor  = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.22, alpha: 1.0)
    private let offColor = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.22, alpha: 0.07)
    private let panelColor = NSColor(srgbRed: 0.06, green: 0.05, blue: 0.04, alpha: 1.0)

    // MARK: State

    private var bitmap = PixelBitmap.empty
    private var offset = 0
    private var timer: Timer?
    private var isPaused = false

    var text: String = "" {
        didSet {
            bitmap = PixelFont.rasterize(text)
            offset = 0
            needsDisplay = true
        }
    }

    /// Total scroll cycle: the text plus the trailing gap.
    private var cycleWidth: Int { max(1, bitmap.width + gapColumns) }

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
        let t = Timer(timeInterval: 1.0 / columnsPerSecond, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.offset = (self.offset + 1) % self.cycleWidth
            self.needsDisplay = true
        }
        // .common so the ticker keeps moving while menus are tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Hover to pause

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isPaused = true }
    override func mouseExited(with event: NSEvent) { isPaused = false }

    /// Let clicks fall through to the status item button so its menu still opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let panelRect = bounds.insetBy(dx: 0, dy: 1)
        panelColor.setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 3, yRadius: 3).fill()

        guard bitmap.width > 0 else { return }

        // Fit the capital band plus equal margins above and below into the panel.
        let visibleRows = topMarginRows + rows
        let pitch = panelRect.height / CGFloat(visibleRows)
        let dotSize = pitch * dotFill
        let inset = (pitch - dotSize) / 2

        let visibleColumns = Int(bounds.width / pitch)
        let xInset = (bounds.width - CGFloat(visibleColumns) * pitch) / 2

        let lit = CGMutablePath()
        let dark = CGMutablePath()

        for column in 0..<visibleColumns {
            let source = (offset + column) % cycleWidth
            let x = xInset + CGFloat(column) * pitch + inset

            for row in 0..<visibleRows {
                // Row 0 is the top of the panel; the view is bottom-up.
                let y = panelRect.maxY - CGFloat(row + 1) * pitch + inset
                let dot = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                if row >= topMarginRows, bitmap.isOn(source, row - topMarginRows) {
                    lit.addEllipse(in: dot)
                } else {
                    dark.addEllipse(in: dot)
                }
            }
        }

        ctx.addPath(dark)
        ctx.setFillColor(offColor.cgColor)
        ctx.fillPath()

        ctx.addPath(lit)
        ctx.setFillColor(onColor.cgColor)
        ctx.fillPath()
    }
}
