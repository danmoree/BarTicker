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

    /// What happens when `text` is replaced.
    enum Change {
        /// The new line simply appears.
        case cut
        /// The old line rises out of the band and the new one follows it up
        /// into place, the way a split-flap board turns over.
        ///
        /// A line caught mid-crawl finishes its lap first: cutting away from
        /// half a sentence loses whatever the reader was in the middle of. So
        /// the change waits for the text to come back round to the front,
        /// holds it there for a beat, turns over, then holds the new line the
        /// same beat before it sets off.
        case pushUp
    }

    var scroll: Scroll = .ifOverflow
    var change: Change = .cut

    /// Rows per second during a `.pushUp`. At the panel's frame rate that is
    /// one row per frame, so the lines step rather than glide.
    var changeRowsPerSecond: Double = 30

    /// How long the line stands at the front on each side of the turn.
    var changeDwell: CFTimeInterval = 0.5

    /// Kept at a whole number of columns per frame by the view's frame rate,
    /// so the text steps evenly instead of stalling every few frames.
    var columnsPerSecond: Double = 30

    /// Blank columns between the end of the text and its repeat.
    var gapColumns = 16

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            guard change == .pushUp, bitmap.width > 0 else { return adopt(text) }

            // Queued rather than shown: the next frame works out whether the
            // board is in a fit state to turn over yet. Setting it back to
            // what's already up withdraws the change instead of turning twice.
            pending = text == displayed ? nil : text
        }
    }

    /// Where the line has got to in the handover from one string to the next.
    private enum Phase {
        /// Nothing pending; the line crawls or stands as it normally would.
        case steady
        /// A change is waiting for the crawl to come back round to the front.
        case homing
        /// Held at the front, before the turn.
        case pausedBefore(until: CFTimeInterval)
        /// Mid-turn.
        case turning(start: CFTimeInterval)
        /// The new line held at the front, before it sets off.
        case pausedAfter(until: CFTimeInterval)
    }

    /// How far the pair travels during a turn: the whole text band plus a
    /// blank row, so the two lines are never on the panel touching.
    private static let travel = Board.rows - Board.textTop + 1

    private var bitmap = PixelBitmap.empty
    private var displayed = ""
    private var pending: String?
    private var outgoing: PixelBitmap?
    private var phase = Phase.steady
    private var epoch: CFTimeInterval?
    private var lastOffset = 0

    func render(into columns: UnsafeMutableBufferPointer<DotColumn>, at time: BoardTime) {
        let width = columns.count
        guard width > 0 else { return }

        takePending(width: width, at: time)

        switch phase {

        case .steady, .homing:
            let (offset, cycle) = crawl(width: width, at: time)

            // A wrap back past the start is the line arriving at the front,
            // and the front is the only place a change is allowed to happen.
            if case .homing = phase, offset == 0 || offset < lastOffset {
                phase = .pausedBefore(until: time.absolute + changeDwell)
                lastOffset = 0
                draw(bitmap, into: columns, shift: 0)
            } else {
                lastOffset = offset
                draw(bitmap, into: columns, offset: offset, cycle: cycle, shift: 0)
            }

        case .pausedBefore(let until):
            guard time.absolute >= until else {
                draw(bitmap, into: columns, shift: 0)
                break
            }
            guard let next = pending else {
                // Withdrawn while we waited — pick the crawl back up.
                resume()
                draw(bitmap, into: columns, shift: 0)
                break
            }

            let leaving = bitmap
            outgoing = leaving
            adopt(next)
            pending = nil
            phase = .turning(start: time.absolute)

            // Nothing has travelled yet on this frame: the old line is still
            // home and the new one is below the band.
            draw(leaving, into: columns, shift: 0)

        case .turning(let start):
            // Rounded, not truncated: the frame clock is a sum of 1/30ths, so
            // the row boundary lands a hair short as often as not and the
            // lines would sit out every other frame.
            let rows = ((time.absolute - start) * changeRowsPerSecond).rounded()
            let advance = min(Self.travel, Int(rows))

            if advance < Self.travel {
                if let leaving = outgoing {
                    draw(leaving, into: columns, shift: -advance)
                }
            } else {
                outgoing = nil
                phase = .pausedAfter(until: time.absolute + changeDwell)
            }
            draw(bitmap, into: columns, shift: Self.travel - advance)

        case .pausedAfter(let until):
            if time.absolute >= until { resume() }
            draw(bitmap, into: columns, shift: 0)
        }
    }

    // MARK: Sequence

    /// Picks up a queued change once the line is in a state to begin one.
    private func takePending(width: Int, at time: BoardTime) {
        guard case .steady = phase, pending != nil else { return }

        // A standing line has no lap to finish, so it turns at once; a
        // crawling one has to come back round to its start first.
        phase = crawls(width: width)
            ? .homing
            : .pausedBefore(until: time.absolute)
    }

    /// Back to normal: the crawl sets off again from the left edge.
    private func resume() {
        epoch = nil
        lastOffset = 0
        phase = .steady
    }

    private func adopt(_ string: String) {
        displayed = string
        bitmap = PixelFont.rasterize(string)
        epoch = nil          // new text starts from the left edge
        lastOffset = 0
    }

    // MARK: Drawing

    private func crawls(width: Int) -> Bool {
        switch scroll {
        case .fixed:      return false
        case .always:     return true
        case .ifOverflow: return bitmap.width > width
        }
    }

    /// Where the crawl has got to: the bitmap column sitting at the left edge,
    /// and the width of one repeat. A cycle of 0 means the line is standing.
    private func crawl(width: Int, at time: BoardTime) -> (offset: Int, cycle: Int) {
        guard crawls(width: width) else { return (0, 0) }

        let cycle = bitmap.width + gapColumns
        let start = epoch ?? time.scroll
        epoch = start
        return (Int((time.scroll - start) * columnsPerSecond) % cycle, cycle)
    }

    /// `shift` moves the line down the panel; anything pushed outside the text
    /// band is clipped, which is what makes the turn look like a window.
    private func draw(_ bitmap: PixelBitmap,
                      into columns: UnsafeMutableBufferPointer<DotColumn>,
                      offset: Int = 0, cycle: Int = 0, shift: Int) {
        for x in 0..<columns.count {
            let source = cycle > 0 ? (offset + x) % cycle : x
            var bits: DotColumn = 0
            for row in 0..<PixelFont.rows where bitmap.isOn(source, row) {
                let panelRow = Board.textTop + row + shift
                guard panelRow >= Board.textTop, panelRow < Board.rows else { continue }
                bits |= 1 << DotColumn(panelRow)
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
