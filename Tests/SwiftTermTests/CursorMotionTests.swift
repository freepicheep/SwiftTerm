//
//  CursorMotionTests.swift
//  SwiftTermTests
//
//  A cursor that travels between cells (`TerminalView.cursorMotion`): the
//  solver that eases its corners, and the Metal renderer drawing it.
//

#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
import Testing
@testable import SwiftTerm

@Suite struct CursorMotionSolverTests {
    static let geometry = SIMD4<Float>(16, 32, 640, 320)
    static let a = CGRect(x: 0, y: 0, width: 16, height: 32)
    static let b = CGRect(x: 160, y: 0, width: 16, height: 32)

    @Test func theFirstPlaceIsJumpedTo() {
        var solver = CursorMotionSolver()
        #expect(step(&solver, Self.a, Self.geometry, .smear, true, 0) == nil)
    }

    @Test func aMoveTravelsAndArrives() throws {
        var solver = CursorMotionSolver()
        _ = step(&solver, Self.a, Self.geometry, .smear, true, 0)
        let start = try #require(step(&solver, Self.b, Self.geometry, .smear, true, 1))
        // It sets off from where it was.
        #expect(start.0 == SIMD2(0, 0))
        let mid = try #require(step(&solver, Self.b, Self.geometry, .smear, true, 1.05))
        // The leading (right) edge is ahead of the trailing one, which lags behind: drawn out.
        #expect(mid.1.x > Float(Self.a.maxX) && mid.1.x <= Float(Self.b.maxX))
        #expect(mid.0.x < mid.1.x - 16)
        #expect(mid.0.y == 0 && mid.3.y == 32, "a level move stays level")
        let end = CursorMotion.smear.duration * (1 + CursorMotion.smear.stretch)
        #expect(step(&solver, Self.b, Self.geometry, .smear, true, 1 + end) == nil)
    }

    @Test func aGlideKeepsItsShape() throws {
        var solver = CursorMotionSolver()
        _ = step(&solver, Self.a, Self.geometry, .glide, true, 0)
        _ = step(&solver, Self.b, Self.geometry, .glide, true, 1)
        let mid = try #require(step(&solver, Self.b, Self.geometry, .glide, true, 1.04))
        #expect(abs((mid.1.x - mid.0.x) - 16) < 0.001)
    }

    @Test func aNewPlaceMidwayPicksUpFromWhereItIs() throws {
        var solver = CursorMotionSolver()
        _ = step(&solver, Self.a, Self.geometry, .glide, true, 0)
        _ = step(&solver, Self.b, Self.geometry, .glide, true, 1)
        let mid = try #require(step(&solver, Self.b, Self.geometry, .glide, true, 1.05))
        let c = CGRect(x: 0, y: 64, width: 16, height: 32)
        let turned = try #require(step(&solver, c, Self.geometry, .glide, true, 1.05))
        #expect(turned.0 == mid.0)
    }

    @Test func jumpsWhenToldOrWhenEverythingMoves() {
        var solver = CursorMotionSolver()
        _ = step(&solver, Self.a, Self.geometry, .smear, true, 0)
        #expect(step(&solver, Self.b, Self.geometry, .smear, false, 1) == nil)
        // A new font or view size moves every cell.
        let bigger = SIMD4<Float>(18, 36, 640, 320)
        #expect(step(&solver, Self.a, bigger, .smear, true, 2) == nil)
        solver.reset()
        #expect(step(&solver, Self.b, bigger, .smear, true, 3) == nil)
    }
}

/// One frame of the solver, outside the testing macros, which can't take a mutating call.
func step(_ solver: inout CursorMotionSolver, _ rect: CGRect, _ geometry: SIMD4<Float>, _ motion: CursorMotion,
          _ animate: Bool, _ time: Double) -> CursorMotionSolver.Corners? {
    solver.update(rect: rect, geometry: geometry, motion: motion, animate: animate, time: time)
}
#endif

#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit

@MainActor @Suite struct CursorMotionRenderTests {
    /// A harness whose cursor is drawn solid, as a focused view's is.
    static func harness(_ motion: CursorMotion?) throws -> MetalRowCacheTests.Harness {
        let harness = try #require(MetalRowCacheTests.Harness())
        harness.view.caretViewTracksFocus = false
        harness.view.cursorMotion = motion
        harness.view.feed(text: "\u{1b}[2 q\u{1b}[3;5H")
        return harness
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func aMoveAfterInputTravels() async throws {
        let harness = try Self.harness(.smear)
        _ = try #require(await harness.frame())
        #expect(harness.renderer.lastDrawData?.cursorQuad == nil)

        harness.renderer.noteCursorInput()
        harness.view.feed(text: "\u{1b}[3;40H")
        _ = try #require(await harness.frame())
        let quad = try #require(harness.renderer.lastDrawData?.cursorQuad)
        // On its way: it reaches back toward column 5 rather than sitting in column 40's cell.
        let cell = harness.view.cellDimension.width * 2
        #expect(CGFloat(quad.bounds.minX) < cell * 30)
        // The cell's own cursor isn't drawn while it travels.
        #expect(harness.renderer.lastDrawData?.cursorColorVertices.isEmpty == true)

        try await Task.sleep(for: .milliseconds(400))
        _ = try #require(await harness.frame())
        #expect(harness.renderer.lastDrawData?.cursorQuad == nil)
        #expect(harness.renderer.lastDrawData?.cursorColorVertices.isEmpty == false)
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func outputAloneStillJumps() async throws {
        let harness = try Self.harness(.smear)
        _ = try #require(await harness.frame())
        harness.view.feed(text: "\u{1b}[3;40H")
        _ = try #require(await harness.frame())
        #expect(harness.renderer.lastDrawData?.cursorQuad == nil)
    }

    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func offByDefault() async throws {
        let harness = try Self.harness(nil)
        _ = try #require(await harness.frame())
        harness.renderer.noteCursorInput()
        harness.view.feed(text: "\u{1b}[3;40H")
        _ = try #require(await harness.frame())
        #expect(harness.renderer.lastDrawData?.cursorQuad == nil)
    }
}
#endif
