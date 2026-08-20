//
//  PixelFont.swift
//  DotStrip
//
//  Composes lines of text from the hand-drawn glyphs in PixelFontData.
//
//  Glyphs are stored on a fixed 5-wide grid but drawn proportionally: blank
//  columns are trimmed off each side and one blank column is inserted between
//  characters, so "i" takes three columns and "W" takes five, the way a real
//  sign spaces them.
//

import Foundation

struct PixelBitmap {
    let width: Int
    let height: Int
    let pixels: [Bool]      // row-major, y == 0 is the TOP row

    func isOn(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return pixels[y * width + x]
    }

    static let empty = PixelBitmap(width: 0, height: 0, pixels: [])
}

enum PixelFont {

    static let rows = PixelFontData.rows

    /// Height of a capital, in dots.
    static let capRows = PixelFontData.capRows

    /// Dots hanging below the baseline, for descenders.
    static let descenderRows = PixelFontData.rows - PixelFontData.capRows

    /// Blank columns between two characters.
    static let letterSpacing = 1

    /// Width of a space, before letter spacing is added.
    static let spaceWidth = 2

    // MARK: Glyph cache

    /// A glyph's drawings, each as vertical strips: frames[f][x][y], y == 0 at
    /// the top. Most characters have exactly one.
    private static var cache: [Character: [[[Bool]]]] = [:]

    private static func frames(for character: Character) -> [[[Bool]]] {
        if let cached = cache[character] { return cached }

        let result: [[[Bool]]]
        if character == " " {
            result = [Array(repeating: Array(repeating: false, count: rows), count: spaceWidth)]
        } else if let arts = PixelFontData.variants[character] {
            result = trimTogether(arts.map { strips(from: $0) })
        } else {
            let art = PixelFontData.glyphs[character] ?? PixelFontData.fallback
            result = [trim(strips(from: art))]
        }

        cache[character] = result
        return result
    }

    private static func columns(for character: Character, frame: Int = 0) -> [[Bool]] {
        let drawings = frames(for: character)
        return drawings[frame % drawings.count]
    }

    /// How many drawings a line cycles through. One means it is still.
    static func frameCount(of text: String) -> Int {
        var count = 1
        for character in text {
            count = max(count, frames(for: character).count)
        }
        return count
    }

    private static func strips(from art: [String]) -> [[Bool]] {
        let grid = art.map { Array($0) }
        // Width comes from the art itself: letters share a 5-wide grid, but a
        // symbol is free to draw itself wider.
        let width = grid.map(\.count).max() ?? 0
        return (0..<width).map { x in
            (0..<rows).map { y in
                guard y < grid.count, x < grid[y].count else { return false }
                return grid[y][x] == "#"
            }
        }
    }

    /// Trims a glyph's frames as a group, to the widest extent any of them
    /// reaches.
    ///
    /// Trimming each frame to its own art would let a frame with its rays
    /// pulled in come out narrower than the rest, and the line would twitch
    /// sideways every time that frame came round. Sharing one width means a
    /// frame can be as sparse as it likes.
    private static func trimTogether(_ frames: [[[Bool]]]) -> [[[Bool]]] {
        let width = frames.map(\.count).max() ?? 0
        var bounds: (first: Int, last: Int)?

        for x in 0..<width {
            let lit = frames.contains { x < $0.count && $0[x].contains(true) }
            guard lit else { continue }
            bounds = (bounds?.first ?? x, x)
        }

        guard let bounds else { return frames.map { _ in [] } }
        let blank = Array(repeating: false, count: rows)
        return frames.map { frame in
            (bounds.first...bounds.last).map { x in x < frame.count ? frame[x] : blank }
        }
    }

    /// Drops blank columns from both ends so glyphs sit proportionally.
    private static func trim(_ columns: [[Bool]]) -> [[Bool]] {
        guard let first = columns.firstIndex(where: { $0.contains(true) }),
              let last = columns.lastIndex(where: { $0.contains(true) })
        else { return [] }
        return Array(columns[first...last])
    }

    // MARK: Measurement

    /// How many dot columns `rasterize` would produce. Zones that size
    /// themselves to their content ask this rather than rasterizing and
    /// throwing the bitmap away.
    static func width(of text: String) -> Int {
        var width = 0
        for character in text {
            if width > 0 { width += letterSpacing }
            width += columns(for: character).count
        }
        return width
    }

    // MARK: Composition

    /// `frame` selects which drawing of an animated glyph to use. Every frame
    /// of a glyph is the same width, so a line's width and its scroll position
    /// are unaffected by which one is showing.
    static func rasterize(_ text: String, frame: Int = 0) -> PixelBitmap {
        guard !text.isEmpty else { return .empty }

        var composed: [[Bool]] = []
        let blank = Array(repeating: false, count: rows)

        for character in text {
            if !composed.isEmpty {
                composed.append(contentsOf: Array(repeating: blank, count: letterSpacing))
            }
            composed.append(contentsOf: columns(for: character, frame: frame))
        }

        let width = composed.count
        guard width > 0 else { return .empty }

        var pixels = [Bool](repeating: false, count: width * rows)
        for (x, column) in composed.enumerated() {
            for y in 0..<rows where column[y] {
                pixels[y * width + x] = true
            }
        }

        return PixelBitmap(width: width, height: rows, pixels: pixels)
    }
}
