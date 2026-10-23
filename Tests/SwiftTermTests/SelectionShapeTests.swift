#if os(macOS)
import CoreGraphics
import Testing
@testable import SwiftTerm

/// The rounded shape a selection draws: outer corners rounded, inside corners
/// filleted once, and an outline that follows the same corners.
struct SelectionShapeTests {
    let cell = CGSize(width: 10, height: 20)

    @Test func twoRowsThatOverlapRoundTheirOuterCornersAndFilletTheInsideOnes() {
        // Row 0 from column 3 to the end, row 1 from the start to column 6.
        let shape = SelectionShape(runs: [.init(row: 0, columns: 3..<8), .init(row: 1, columns: 0..<6)],
                                   cell: cell, radius: 4)
        let (pieces, fillets) = shape.pieces()
        #expect(pieces.count == 2)
        // The first row's top corners and bottom right are outer corners.
        #expect(pieces[0].topLeft == 4 && pieces[0].topRight == 4 && pieces[0].bottomRight == 4)
        // Its bottom left sits on the second row, which reaches further left.
        #expect(pieces[0].bottomLeft == 0)
        #expect(pieces[1].topLeft == 4 && pieces[1].bottomLeft == 4 && pieces[1].bottomRight == 4)
        #expect(pieces[1].topRight == 0)
        // One fillet each side, in the empty corners where the rows meet.
        #expect(fillets.count == 2)
        #expect(fillets.contains { $0.square == CGRect(x: 26, y: 16, width: 4, height: 4) && $0.center == CGPoint(x: 26, y: 16) })
        #expect(fillets.contains { $0.square == CGRect(x: 60, y: 20, width: 4, height: 4) && $0.center == CGPoint(x: 64, y: 24) })
        let box = shape.outline().boundingBoxOfPath
        #expect(abs(box.minX) < 0.001 && abs(box.minY) < 0.001 && abs(box.width - 80) < 0.001 && abs(box.height - 40) < 0.001, "\(box)")
    }

    @Test func aBlockIsOneRoundedRectangle() {
        let shape = SelectionShape(runs: (0..<3).map { .init(row: $0, columns: 2..<5) }, cell: cell, radius: 6)
        let (pieces, fillets) = shape.pieces()
        #expect(fillets.isEmpty)
        #expect(pieces[0].topLeft == 6 && pieces[0].topRight == 6 && pieces[0].bottomLeft == 0)
        #expect(pieces[1].topLeft == 0 && pieces[1].bottomRight == 0)
        #expect(pieces[2].bottomLeft == 6 && pieces[2].bottomRight == 6 && pieces[2].topRight == 0)
        let outline = shape.outline()
        #expect(outline.boundingBoxOfPath == CGRect(x: 20, y: 0, width: 30, height: 60))
        #expect(outline.contains(CGPoint(x: 35, y: 30)))
        // Rounded: the very corner is outside.
        #expect(!outline.contains(CGPoint(x: 20.5, y: 0.5)))
    }

    @Test func rowsThatOnlyTouchAtACornerAreApart() {
        let shape = SelectionShape(runs: [.init(row: 0, columns: 5..<8), .init(row: 1, columns: 0..<5)],
                                   cell: cell, radius: 4)
        let (pieces, fillets) = shape.pieces()
        #expect(fillets.isEmpty)
        #expect(pieces.allSatisfy { $0.topLeft == 4 && $0.topRight == 4 && $0.bottomLeft == 4 && $0.bottomRight == 4 })
        // Two closed outlines, one round each.
        var subpaths = 0
        shape.outline().applyWithBlock { if $0.pointee.type == .moveToPoint { subpaths += 1 } }
        #expect(subpaths == 2)
    }

    @Test func aRadiusLargerThanACellIsHeldToIt() {
        let shape = SelectionShape(runs: [.init(row: 0, columns: 0..<1)], cell: cell, radius: 50)
        let piece = shape.pieces().pieces[0]
        #expect(piece.topLeft == 5)
    }
}
#endif
