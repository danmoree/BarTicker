//
//  Board.swift
//  pixelScreen
//
//  The panel is a grid of dots that several independent things draw into at
//  once: a scrolling headline, a VU meter, a progress bar. Rather than one
//  global scroll offset, the panel is split into zones — each owns a slice of
//  the columns and decides for itself whether it moves.
//

import Foundation
import QuartzCore

/// One vertical slice of the panel. Bit `r` is lit when row `r` is on,
/// row 0 at the top.
typealias DotColumn = UInt16

enum Board {

    /// Blank rows above the capitals. Matching the descender rows below the
    /// baseline keeps text optically centred; it also leaves row 0 permanently
    /// free, which is where the progress bar goes.
    static let textTop = PixelFont.descenderRows

    /// Total dot rows on the panel.
    static let rows = PixelFont.descenderRows + PixelFont.rows
}

/// The two clocks handed to every layer each frame.
struct BoardTime {
    /// Monotonic seconds since the panel started. Always advances.
    var absolute: CFTimeInterval

    /// Advances only while the panel isn't paused. Scrolling reads this, so
    /// hovering freezes text you're trying to read without freezing the meter.
    var scroll: CFTimeInterval
}

protocol BoardLayer: AnyObject {
    /// OR this layer's lit dots into `columns`, which is the layer's own slice
    /// of the panel: index 0 is its left edge.
    func render(into columns: UnsafeMutableBufferPointer<DotColumn>, at time: BoardTime)
}

// MARK: - Zones

struct Zone {

    enum Width {
        /// An exact number of dot columns.
        case fixed(Int)
        /// Splits whatever the fixed zones didn't claim.
        case flexible
    }

    var width: Width

    /// Drawn in order, OR'd together, so a progress bar can share columns with
    /// the text it belongs to.
    var layers: [BoardLayer]

    init(_ width: Width, _ layers: [BoardLayer]) {
        self.width = width
        self.layers = layers
    }

    /// Column ranges for each zone, in order. Flexible zones share the
    /// remainder; if the fixed zones already overflow, later zones get nothing.
    static func layout(_ zones: [Zone], total: Int) -> [Range<Int>] {
        var fixed = 0
        var flexibleCount = 0
        for zone in zones {
            switch zone.width {
            case .fixed(let n): fixed += max(0, n)
            case .flexible:     flexibleCount += 1
            }
        }

        let spare = max(0, total - fixed)
        let share = flexibleCount > 0 ? spare / flexibleCount : 0
        var remainder = flexibleCount > 0 ? spare % flexibleCount : 0

        var ranges: [Range<Int>] = []
        var x = 0
        for zone in zones {
            var w: Int
            switch zone.width {
            case .fixed(let n):
                w = max(0, n)
            case .flexible:
                w = share
                if remainder > 0 { w += 1; remainder -= 1 }
            }
            let start = min(x, total)
            let end = min(x + w, total)
            ranges.append(start..<end)
            x += w
        }
        return ranges
    }
}

// MARK: - Text

/// A line of dot-matrix text that crawls only when it has to.
final class TextLayer: BoardLayer {

    enum Scroll {
        /// Never moves; anything past the right edge is clipped.
        case fixed
        /// Still when it fits, crawls when it doesn't. What a real sign does.
        case ifOverflow
        /// Always crawls, even when it would fit.
        case always
    }

    var scroll: Scroll = .ifOverflow

    /// Kept at a whole number of columns per frame by the view's frame rate,
    /// so the text steps evenly instead of stalling every few frames.
    var columnsPerSecond: Double = 30

    /// Blank columns between the end of the text and its repeat.
    var gapColumns = 16

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            bitmap = PixelFont.rasterize(text)
            epoch = nil          // new text starts from the left edge
        }
    }

    private var bitmap = PixelBitmap.empty
    private var epoch: CFTimeInterval?

    func render(into columns: UnsafeMutableBufferPointer<DotColumn>, at time: BoardTime) {
        let width = columns.count
        guard width > 0, bitmap.width > 0 else { return }

        let moving: Bool
        switch scroll {
        case .fixed:      moving = false
        case .always:     moving = true
        case .ifOverflow: moving = bitmap.width > width
        }

        var offset = 0
        var cycle = 1
        if moving {
            cycle = bitmap.width + gapColumns
            let start = epoch ?? time.scroll
            epoch = start
            offset = Int((time.scroll - start) * columnsPerSecond) % cycle
        }

        for x in 0..<width {
            let source = moving ? (offset + x) % cycle : x
            var bits: DotColumn = 0
            for row in 0..<PixelFont.rows where bitmap.isOn(source, row) {
                bits |= 1 << DotColumn(Board.textTop + row)
            }
            columns[x] |= bits
        }
    }
}

// MARK: - Progress

/// A thin bar along the top margin — the one row text never occupies, so it
/// can share a zone with a title without colliding with its descenders.
final class ProgressLayer: BoardLayer {

    /// Consulted every frame when set, so the bar follows playback without
    /// anyone having to push updates at it.
    var source: (() -> Double)?

    /// Used when `source` is nil.
    var fraction: Double = 0

    var row = 0

    func render(into columns: UnsafeMutableBufferPointer<DotColumn>, at time: BoardTime) {
        let width = columns.count
        guard width > 0 else { return }

        let value = source?() ?? fraction
        let lit = Int((max(0, min(1, value)) * Double(width)).rounded())
        let bit: DotColumn = 1 << DotColumn(row)
        for x in 0..<lit {
            columns[x] |= bit
        }
    }
}
