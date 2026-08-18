//
//  PixelFont.swift
//  pixelScreen
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

    /// A glyph as vertical strips: columns[x][y], y == 0 at the top.
    private static var cache: [Character: [[Bool]]] = [:]

    private static func columns(for character: Character) -> [[Bool]] {
        if let cached = cache[character] { return cached }

        let result: [[Bool]]
        if character == " " {
            result = Array(repeating: Array(repeating: false, count: rows), count: spaceWidth)
        } else {
            let art = PixelFontData.glyphs[character] ?? PixelFontData.fallback
            result = trim(strips(from: art))
        }

        cache[character] = result
        return result
    }

    private static func strips(from art: [String]) -> [[Bool]] {
        let grid = art.map { Array($0) }
        return (0..<PixelFontData.columns).map { x in
            (0..<rows).map { y in
                guard y < grid.count, x < grid[y].count else { return false }
                return grid[y][x] == "#"
            }
        }
    }

    /// Drops blank columns from both ends so glyphs sit proportionally.
    private static func trim(_ columns: [[Bool]]) -> [[Bool]] {
        guard let first = columns.firstIndex(where: { $0.contains(true) }),
              let last = columns.lastIndex(where: { $0.contains(true) })
        else { return [] }
        return Array(columns[first...last])
    }

    // MARK: Composition

    static func rasterize(_ text: String) -> PixelBitmap {
        guard !text.isEmpty else { return .empty }

        var composed: [[Bool]] = []
        let blank = Array(repeating: false, count: rows)

        for character in text {
            if !composed.isEmpty {
                composed.append(contentsOf: Array(repeating: blank, count: letterSpacing))
            }
            composed.append(contentsOf: columns(for: character))
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
