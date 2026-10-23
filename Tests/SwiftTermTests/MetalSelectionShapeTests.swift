//
//  MetalSelectionShapeTests.swift
//  SwiftTermTests
//
//  A rounded selection, as the Metal renderer draws it: the pixels at an outer
//  corner go back to the background, and the inside corner where one row's run
//  meets the next is filled in, where a square selection does neither.
//

#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct MetalSelectionShapeTests {
    typealias Harness = MetalRowCacheTests.Harness

    /// The pixel at `point` (drawable pixels, from the top left).
    private func pixel(_ frame: MetalRowCacheTests.DrawnFrame, _ harness: Harness, _ point: CGPoint) -> [UInt8] {
        let width = Int(harness.target.renderDrawableSize.width)
        let x = Int(point.x), y = Int(point.y)
        let i = (y * width + x) * 4
        return Array(frame.pixels[i..<i + 4])
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable))
    func outerCornersRoundAndInsideCornersFill() async throws {
        let harness = try #require(Harness())
        let view = harness.view
        view.nativeBackgroundColor = .black
        view.selectedTextBackgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        view.feed(text: "")
        // Row 1 from column 4 to the end, row 2 whole, row 3 to column 10.
        view.withTerminal { _ in
            view.selection.setSelection(start: Position(col: 4, row: 1), end: Position(col: 10, row: 3))
        }
        let scale: CGFloat = 2
        let cell = CGSize(width: view.cellDimension.width * scale, height: view.cellDimension.height * scale)
        // Just inside the run's top-left corner on row 1.
        let outer = CGPoint(x: 4 * cell.width + 1, y: 1 * cell.height + 1)
        // Just above and left of where row 1's run starts over row 2: empty in a
        // square selection, filled by the fillet in a rounded one.
        let inside = CGPoint(x: 4 * cell.width - 1, y: 2 * cell.height - 1)
        let middle = CGPoint(x: 6.5 * cell.width, y: 1.5 * cell.height)
        // Far from the cursor and the selection.
        let background = CGPoint(x: 30.5 * cell.width, y: 8.5 * cell.height)

        view.selectionCornerRadius = 0
        let square = try #require(await harness.frame())
        let red = pixel(square, harness, middle)
        let black = pixel(square, harness, background)
        #expect(red != black)
        #expect(pixel(square, harness, outer) == red)
        #expect(pixel(square, harness, inside) == black)

        view.selectionCornerRadius = 4
        let rounded = try #require(await harness.frame())
        #expect(pixel(rounded, harness, middle) == red)
        #expect(pixel(rounded, harness, outer) == black)
        #expect(pixel(rounded, harness, inside) == red)
        #expect(rounded.pixels.count == square.pixels.count)
    }
}
#endif
