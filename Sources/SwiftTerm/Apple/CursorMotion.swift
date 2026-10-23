//
//  CursorMotion.swift
//
//  How the Metal renderer moves the cursor from one cell to the next
//  (`TerminalView.cursorMotion`), and the solver that animates it.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics

/// How the cursor travels when it moves to another cell, rather than jumping
/// there. Set ``TerminalView/cursorMotion`` to opt in; the Metal renderer
/// draws it, and the Core Graphics renderer keeps a cursor that jumps.
///
/// Each corner of the cursor eases into its new place on its own clock. The
/// corners that lead the way take ``duration``; the ones at the back take up
/// to `duration * (1 + stretch)`, so with a ``stretch`` above zero the cursor
/// draws out along its path and gathers up again as it lands, and with zero it
/// glides as a solid block.
public struct CursorMotion: Sendable, Equatable {
    /// Seconds the leading edge takes to reach the new cell.
    public var duration: TimeInterval
    /// How much longer than ``duration`` the trailing edge takes, as a
    /// fraction of it. Zero glides; one stretches to twice the length of time.
    public var stretch: Double
    /// Only moves that follow the user's own input animate, within
    /// ``inputWindow`` of it. Output that moves the cursor on its own, a
    /// program printing a log for instance, leaves it jumping, as it would
    /// otherwise chase every line.
    public var followsInputOnly: Bool
    /// How long after input a move still counts as following it.
    public var inputWindow: TimeInterval

    public init(duration: TimeInterval = 0.09, stretch: Double = 1.2,
                followsInputOnly: Bool = true, inputWindow: TimeInterval = 0.5) {
        self.duration = max(0, duration)
        self.stretch = max(0, stretch)
        self.followsInputOnly = followsInputOnly
        self.inputWindow = max(0, inputWindow)
    }

    /// The cursor glides as a solid block.
    public static let glide = CursorMotion(duration: 0.1, stretch: 0)
    /// The cursor draws out along its path and gathers up as it lands.
    public static let smear = CursorMotion()
}

/// Animates the cursor's four corners toward the rect the terminal puts it in.
/// Render-thread state; pure, so tests drive it with their own clock.
struct CursorMotionSolver {
    /// The rect's corners, in order: (minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY).
    typealias Corners = (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)

    private struct Corner {
        var from: SIMD2<Float>
        var to: SIMD2<Float>
        var start: Double
        var duration: Double

        func position(at time: Double) -> SIMD2<Float> {
            guard duration > 0 else { return to }
            let t = min(1, max(0, (time - start) / duration))
            let eased = Float(1 - pow(1 - t, 3))
            return from + (to - from) * eased
        }

        func done(at time: Double) -> Bool { time - start >= duration }
    }

    private var corners: [Corner] = []
    private var target: CGRect?
    /// What the rect is measured against: the cell and view sizes. A change
    /// moves every cursor at once, so the cursor jumps instead.
    private var geometry: SIMD4<Float>?

    /// Forgets where the cursor was, so its next place is jumped to.
    mutating func reset() {
        corners = []
        target = nil
        geometry = nil
    }

    /// Where to draw the cursor at `time`, given it belongs at `rect`: its
    /// corners while it is on its way, nil once it has arrived (draw `rect`).
    /// With `animate` false a move jumps.
    mutating func update(rect: CGRect, geometry: SIMD4<Float>, motion: CursorMotion,
                         animate: Bool, time: Double) -> Corners? {
        if rect != target {
            let jump = !animate || target == nil || geometry != self.geometry || corners.count != 4
            let goal = Self.corners(of: rect)
            if jump {
                corners = goal.map { Corner(from: $0, to: $0, start: time, duration: 0) }
            } else {
                let now = corners.map { $0.position(at: time) }
                let centre = SIMD2<Float>(Float(rect.midX), Float(rect.midY))
                let was = now.reduce(SIMD2<Float>(0, 0), +) / 4
                let way = centre - was
                let length = (way * way).sum().squareRoot()
                corners = zip(now, goal).map { at, to in
                    // 1 for a corner leading the way, 0 for one at the back.
                    var lead: Float = 0.5
                    if length > 0.001 {
                        let out = to - centre
                        let outLength = (out * out).sum().squareRoot()
                        if outLength > 0.001 { lead = ((out / outLength * way / length).sum() + 1) / 2 }
                    }
                    let duration = motion.duration * (1 + motion.stretch * Double(1 - lead))
                    return Corner(from: at, to: to, start: time, duration: duration)
                }
            }
            target = rect
            self.geometry = geometry
        }
        guard corners.count == 4, corners.contains(where: { !$0.done(at: time) }) else { return nil }
        let at = corners.map { $0.position(at: time) }
        return (at[0], at[1], at[2], at[3])
    }

    static func corners(of rect: CGRect) -> [SIMD2<Float>] {
        [SIMD2(Float(rect.minX), Float(rect.minY)), SIMD2(Float(rect.maxX), Float(rect.minY)),
         SIMD2(Float(rect.maxX), Float(rect.maxY)), SIMD2(Float(rect.minX), Float(rect.maxY))]
    }
}
#endif
