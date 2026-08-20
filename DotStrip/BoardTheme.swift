//
//  BoardTheme.swift
//  DotStrip
//
//  Colour schemes for the panel.
//
//  These are the colours real dot-matrix signs actually come in rather than an
//  arbitrary palette, and each one carries its own panel colour: an LED board's
//  dark background is never neutral black, it picks up a tint from the emitter
//  behind the mask, and matching that is most of what makes a scheme look like
//  a physical board instead of recoloured text.
//

import AppKit

struct BoardTheme: Equatable {

    let id: String
    let name: String

    /// A lit dot.
    let on: NSColor

    /// The board behind the dots.
    let panel: NSColor

    /// How visible an unlit dot is. Brighter emitters need it lower, or the
    /// dark grid reads as noise competing with the text.
    let unlitAlpha: CGFloat

    /// An unlit dot: the same emitter, just not driven.
    var off: NSColor { on.withAlphaComponent(unlitAlpha) }

    static func == (a: BoardTheme, b: BoardTheme) -> Bool { a.id == b.id }
}

extension BoardTheme {

    private static func srgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The original, and what most transit and highway signs use.
    static let amber = BoardTheme(
        id: "amber", name: "Amber",
        on: srgb(1.00, 0.72, 0.22), panel: srgb(0.06, 0.05, 0.04), unlitAlpha: 0.07)

    /// Phosphor green, the old terminal and departure-board look.
    static let green = BoardTheme(
        id: "green", name: "Green",
        on: srgb(0.28, 1.00, 0.44), panel: srgb(0.03, 0.06, 0.04), unlitAlpha: 0.06)

    /// The cheap bright LED sign in every shop window.
    static let red = BoardTheme(
        id: "red", name: "Red",
        on: srgb(1.00, 0.27, 0.21), panel: srgb(0.07, 0.03, 0.03), unlitAlpha: 0.08)

    /// Modern blue-white LED.
    static let ice = BoardTheme(
        id: "ice", name: "Ice",
        on: srgb(0.42, 0.82, 1.00), panel: srgb(0.03, 0.05, 0.07), unlitAlpha: 0.06)

    /// High-brightness white, the most legible and the least characterful.
    static let mono = BoardTheme(
        id: "mono", name: "White",
        on: srgb(0.94, 0.95, 1.00), panel: srgb(0.05, 0.05, 0.06), unlitAlpha: 0.05)

    static let all: [BoardTheme] = [amber, green, red, ice, mono]

    static func named(_ id: String) -> BoardTheme {
        all.first { $0.id == id } ?? amber
    }

    /// A miniature board for the menu, so the schemes can be told apart by
    /// looking rather than by reading their names.
    func swatch(size: NSSize = NSSize(width: 30, height: 14)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.panel.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

            let columns = 9, rows = 4
            let pitch = min((rect.width - 4) / CGFloat(columns),
                            (rect.height - 3) / CGFloat(rows))
            let dot = pitch * 0.8
            let originX = (rect.width - pitch * CGFloat(columns)) / 2
            let originY = (rect.height - pitch * CGFloat(rows)) / 2

            // An arbitrary but fixed pattern, so every swatch shows both a lit
            // and an unlit dot in the same places.
            let pattern: [UInt16] = [0b0110, 0b1001, 0b1000, 0b1001, 0b0110,
                                     0b0000, 0b1111, 0b0101, 0b0101]

            for column in 0..<columns {
                for row in 0..<rows {
                    let isOn = pattern[column] & (1 << (rows - 1 - row)) != 0
                    (isOn ? self.on : self.off).setFill()
                    let box = NSRect(x: originX + CGFloat(column) * pitch + (pitch - dot) / 2,
                                     y: originY + CGFloat(rows - 1 - row) * pitch + (pitch - dot) / 2,
                                     width: dot, height: dot)
                    NSBezierPath(ovalIn: box).fill()
                }
            }
            return true
        }
    }
}
