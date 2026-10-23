//
//  MetalSmoothScrollTests.swift
//  SwiftTermTests
//
//  Smooth scrolling, as the Metal renderer draws it: part way between rows the
//  whole frame is the rows drawn that much lower, the row above showing at the
//  top; and once the view scrolls by other means, the rows are back in place.
//

#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct MetalSmoothScrollTests {
    typealias Harness = MetalRowCacheTests.Harness

    /// One row of drawable pixels.
    private func row(_ frame: MetalRowCacheTests.DrawnFrame, _ y: Int, width: Int) -> ArraySlice<UInt8> {
        frame.pixels[(y * width * 4)..<((y + 1) * width * 4)]
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable))
    func partWayBetweenRowsEverythingIsDrawnLower() async throws {
        let harness = try #require(Harness(cols: 40, rows: 10, scrollback: 200))
        let view = harness.view
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        // Lines that differ from row to row, so a shifted frame can't match by chance.
        for i in 0..<60 { view.feed(text: "line \(i) " + String(repeating: "#", count: i % 30) + "\r\n") }
        view.scrollTo(row: 20)
        let plain = try #require(await harness.frame())

        let scale: CGFloat = 2
        let offset: CGFloat = 8
        view.smoothScrollState = SmoothScrollState(yDisp: 20, offset: offset)
        let lower = try #require(await harness.frame())
        let width = Int(harness.target.renderDrawableSize.width)
        let height = Int(harness.target.renderDrawableSize.height)
        let shift = Int(offset * scale)
        // Every row of the screen, a whole number of pixels lower.
        for y in 0..<(height - shift) {
            #expect(row(lower, y + shift, width: width) == row(plain, y, width: width), "pixel row \(y)")
            if row(lower, y + shift, width: width) != row(plain, y, width: width) { break }
        }
        // The row above shows at the top: its white text, where the plain frame has
        // only the background above its first row.
        let top = stride(from: 0, to: shift * width * 4, by: 4)
        #expect(top.contains { lower.pixels[$0] > 60 || lower.pixels[$0 + 1] > 60 })

        // Scrolled by other means, the offset no longer applies.
        view.scrollTo(row: 25)
        view.scrollTo(row: 20)
        view.smoothScrollState = SmoothScrollState(yDisp: 19, offset: offset)
        let back = try #require(await harness.frame())
        #expect(back.pixels == plain.pixels)
    }
}
#endif
