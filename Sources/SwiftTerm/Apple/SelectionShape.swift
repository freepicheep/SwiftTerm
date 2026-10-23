//
//  SelectionShape.swift
//
//  The shape a rounded selection draws (`TerminalView.selectionCornerRadius`).
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics

/// A selection as a shape rather than as cells: each row's run of selected
/// cells with its outer corners rounded, and where one row's run reaches past
/// the next, the inside corner between them rounded too, the way a text
/// editor draws a selection over several lines.
///
/// Coordinates run down the screen from the top left, in whatever unit the
/// cell size is given in (points or pixels).
struct SelectionShape {
    /// One row's selected columns, `row` counting down from the top.
    struct Run: Equatable {
        var row: Int
        var columns: Range<Int>
    }

    /// A run as a rectangle with its own corner radii.
    struct Piece: Equatable {
        var rect: CGRect
        var topLeft: CGFloat
        var topRight: CGFloat
        var bottomRight: CGFloat
        var bottomLeft: CGFloat
    }

    /// The rounding of an inside corner: a square beside a run, filled but
    /// for the circle of `radius` round `center`.
    struct Fillet: Equatable {
        var square: CGRect
        var center: CGPoint
        var radius: CGFloat
    }

    let runs: [Run]
    let cell: CGSize
    let radius: CGFloat

    /// `runs` in any order; a row with no selected columns has no run.
    init (runs: [Run], cell: CGSize, radius: CGFloat) {
        self.runs = runs.filter { !$0.columns.isEmpty }.sorted { $0.row < $1.row }
        self.cell = cell
        self.radius = max(0, radius)
    }

    private func run (atRow row: Int, after index: Int, step: Int) -> Run? {
        let next = index + step
        guard runs.indices.contains(next), runs[next].row == row else { return nil }
        return runs[next]
    }

    /// The runs and the fillets that, drawn together, make the shape.
    func pieces () -> (pieces: [Piece], fillets: [Fillet]) {
        var pieces: [Piece] = []
        var fillets: [Fillet] = []
        let largest = min(radius, cell.height / 2)
        for (i, run) in runs.enumerated() {
            let above = self.run(atRow: run.row - 1, after: i, step: -1)
            let below = self.run(atRow: run.row + 1, after: i, step: 1)
            let lo = run.columns.lowerBound, hi = run.columns.upperBound
            let x0 = CGFloat(lo) * cell.width, x1 = CGFloat(hi) * cell.width
            let top = CGFloat(run.row) * cell.height, bottom = top + cell.height
            let convex = min(largest, (x1 - x0) / 2)
            var piece = Piece(rect: CGRect(x: x0, y: top, width: x1 - x0, height: cell.height),
                              topLeft: convex, topRight: convex, bottomRight: convex, bottomLeft: convex)

            // Each inside corner belongs to the run beside its empty side, so
            // it's made once.
            func fillet (_ x: CGFloat, _ y: CGFloat, overhang: Int, left: Bool, up: Bool) {
                let r = min(largest, CGFloat(overhang) * cell.width)
                guard r > 0 else { return }
                let square = CGRect(x: left ? x - r : x, y: up ? y : y - r, width: r, height: r)
                let center = CGPoint(x: left ? x - r : x + r, y: up ? y + r : y - r)
                fillets.append(Fillet(square: square, center: center, radius: r))
            }
            if let above, above.columns.contains(lo) {
                piece.topLeft = 0
                if above.columns.lowerBound < lo {
                    fillet(x0, top, overhang: lo - above.columns.lowerBound, left: true, up: true)
                }
            }
            if let above, above.columns.contains(hi - 1) {
                piece.topRight = 0
                if above.columns.upperBound > hi {
                    fillet(x1, top, overhang: above.columns.upperBound - hi, left: false, up: true)
                }
            }
            if let below, below.columns.contains(lo) {
                piece.bottomLeft = 0
                if below.columns.lowerBound < lo {
                    fillet(x0, bottom, overhang: lo - below.columns.lowerBound, left: true, up: false)
                }
            }
            if let below, below.columns.contains(hi - 1) {
                piece.bottomRight = 0
                if below.columns.upperBound > hi {
                    fillet(x1, bottom, overhang: below.columns.upperBound - hi, left: false, up: false)
                }
            }
            pieces.append(piece)
        }
        return (pieces, fillets)
    }

    /// The shape's outline: one closed path round each stack of runs that
    /// overlap the next, with the same corners `pieces()` draws.
    func outline () -> CGPath {
        let path = CGMutablePath()
        var stack: [Run] = []
        func close () {
            guard !stack.isEmpty else { return }
            addOutline(of: stack, to: path)
            stack = []
        }
        for run in runs {
            if let last = stack.last, last.row + 1 == run.row,
               last.columns.overlaps(run.columns) {
                stack.append(run)
            } else {
                close()
                stack = [run]
            }
        }
        close()
        return path
    }

    /// Down the right edges, back up the left, rounding every corner.
    private func addOutline (of stack: [Run], to path: CGMutablePath) {
        var points: [CGPoint] = []
        for run in stack {
            let x = CGFloat(run.columns.upperBound) * cell.width
            points.append(CGPoint(x: x, y: CGFloat(run.row) * cell.height))
            points.append(CGPoint(x: x, y: CGFloat(run.row + 1) * cell.height))
        }
        for run in stack.reversed() {
            let x = CGFloat(run.columns.lowerBound) * cell.width
            points.append(CGPoint(x: x, y: CGFloat(run.row + 1) * cell.height))
            points.append(CGPoint(x: x, y: CGFloat(run.row) * cell.height))
        }
        // Where two rows end at the same column the corner isn't one.
        var corners: [CGPoint] = []
        for (i, p) in points.enumerated() {
            let prev = points[(i + points.count - 1) % points.count]
            let next = points[(i + 1) % points.count]
            if p == prev { continue }
            let straight = (prev.x == p.x && p.x == next.x) || (prev.y == p.y && p.y == next.y)
            if !straight { corners.append(p) }
        }
        guard corners.count >= 3 else { return }
        let largest = min(radius, cell.height / 2)
        func mid (_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func length (_ a: CGPoint, _ b: CGPoint) -> CGFloat { abs(a.x - b.x) + abs(a.y - b.y) }
        path.move(to: mid(corners[corners.count - 1], corners[0]))
        for (i, p) in corners.enumerated() {
            let prev = corners[(i + corners.count - 1) % corners.count]
            let next = corners[(i + 1) % corners.count]
            let r = min(largest, length(prev, p) / 2, length(p, next) / 2)
            path.addArc(tangent1End: p, tangent2End: next, radius: r)
        }
        path.closeSubpath()
    }
}
#endif
#endif
