#if os(macOS)
import Benchmark
import Foundation
import Dispatch
import SwiftTerm
import VTEBenchWorkloads

private enum SwiftTermBenchmarks {
    static let columns = VTEBenchWorkloads.defaultColumns
    static let rows = VTEBenchWorkloads.defaultRows
    static let reset = [UInt8]("\u{1b}c".utf8)
    static let queue = DispatchQueue(
        label: "SwiftTermBenchmarks",
        qos: .userInteractive,
        attributes: .concurrent)
    static let workloads = try! VTEBenchWorkloads.makeDefault(
        columns: columns,
        rows: rows)
    static let hardeningWorkloads = VTEBenchWorkloads.makeHardening(
        columns: columns,
        rows: rows)
}

private func feed(_ benchmark: Benchmark, workload: VTEBenchWorkload) {
    let options = TerminalOptions(
        cols: SwiftTermBenchmarks.columns,
        rows: SwiftTermBenchmarks.rows,
        maximumOscBytes: workload.maximumOscBytes ?? TerminalOptions.default.maximumOscBytes)
    let headlessTerminal = HeadlessTerminal(queue: SwiftTermBenchmarks.queue, options: options) { _ in }
    let terminal = headlessTerminal.terminal!
    terminal.resize(cols: SwiftTermBenchmarks.columns, rows: SwiftTermBenchmarks.rows)
    terminal.feed(byteArray: SwiftTermBenchmarks.reset)
    if !workload.setup.isEmpty {
        terminal.feed(byteArray: workload.setup)
    }
    if workload.inputChunkSize == nil {
        // Keep the default vtebench timing loop unchanged. A loop over one
        // synthetic chunk is measurable in the fastest cases.
        let sample = workload.sample()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            terminal.feed(byteArray: sample)
        }
        benchmark.stopMeasurement()
    } else {
        let sampleChunks = workload.sampleChunks()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for chunk in sampleChunks {
                terminal.feed(byteArray: chunk)
            }
        }
        benchmark.stopMeasurement()
    }
}

/// A deterministic RGBA payload. Content does not matter to the snapshot cost,
/// only its size, but a varying pattern keeps a compressor from flattering it.
private func syntheticRGBA(width: Int, height: Int) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: x))
            bytes.append(UInt8(truncatingIfNeeded: y))
            bytes.append(UInt8(truncatingIfNeeded: x &* y))
            bytes.append(255)
        }
    }
    return bytes
}

/// Measures `kittyGraphicsRenderSnapshot()`, which a renderer calls once per
/// frame through `TerminalSnapshot`.
///
/// This is the only benchmark in the repository that puts an image on screen.
/// The vtebench workloads never do, so they cannot see per-image snapshot cost
/// at all — which is exactly how a full pixel copy per frame went unnoticed.
/// Run the two cases together: `kitty_snapshot_empty` is the fixed overhead and
/// `kitty_snapshot_3mb` adds one 1024x768 image, so the difference is what one
/// live image costs per frame.
private func snapshot(_ benchmark: Benchmark, imageSize: (width: Int, height: Int)?) {
    let headlessTerminal = HeadlessTerminal(queue: SwiftTermBenchmarks.queue) { _ in }
    let terminal = headlessTerminal.terminal!
    terminal.resize(cols: SwiftTermBenchmarks.columns, rows: SwiftTermBenchmarks.rows)
    terminal.feed(byteArray: SwiftTermBenchmarks.reset)

    if let imageSize {
        let pixels = syntheticRGBA(width: imageSize.width, height: imageSize.height)
        let encoded = Data(pixels).base64EncodedString()
        // a=T transmits and displays, so the image carries a placement and the
        // snapshot has to build both the image table and the placement list.
        let control = "a=T,f=32,s=\(imageSize.width),v=\(imageSize.height),i=1,C=1"
        terminal.feed(byteArray: [UInt8]("\u{1b}_G\(control);\(encoded)\u{1b}\\".utf8))
        precondition(terminal.kittyGraphicsRenderSnapshot().imagesById[1] != nil,
                     "the image did not reach the snapshot; the benchmark would measure nothing")
    }

    benchmark.startMeasurement()
    for _ in benchmark.scaledIterations {
        blackHole(terminal.kittyGraphicsRenderSnapshot())
    }
    benchmark.stopMeasurement()
}

/// Ten thousand lines of styled shell-like output for the history benchmarks:
/// a colored word, then plain text, 20 to 79 columns wide.
private let historyOutput: [UInt8] = {
    let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit"]
    var text = ""
    for i in 0..<10_000 {
        var line = "\u{1b}[3\(i % 8)m\(words[i % words.count])\u{1b}[0m "
        var visible = words[i % words.count].count + 1
        let width = 20 + (i * 37) % 60
        var j = i
        while visible < width {
            let word = words[j % words.count]
            line += word + " "
            visible += word.count + 1
            j += 3
        }
        text += line + "\r\n"
    }
    return Array(text.utf8)
}()

/// A terminal whose 10,000 lines of scrollback hold `historyOutput`. Keep
/// the returned host alive for as long as the terminal is used.
private func historyTerminal() -> (host: HeadlessTerminal, terminal: Terminal) {
    let options = TerminalOptions(cols: SwiftTermBenchmarks.columns, rows: SwiftTermBenchmarks.rows,
                                  scrollback: 10_000)
    let host = HeadlessTerminal(queue: SwiftTermBenchmarks.queue, options: options) { _ in }
    let terminal = host.terminal!
    terminal.feed(byteArray: historyOutput)
    return (host, terminal)
}

/// The cold history benchmarks. Compaction runs when the terminal is idle, so
/// these measure the idle-time work and what reading or overwriting cold rows
/// costs, not the parse path (the vtebench cases cover that).
///
/// - `history_compaction`: moving 10,000 rows into cold history and back.
/// - `history_cold_read`: reading every cold row without restoring it, as
///   search, selection and serialization do.
/// - `history_scroll_over_cold` and `history_scroll_over_warm`: 10,000 new
///   lines scrolling through a full scrollback. The cold case compacts first,
///   so each of its iterations also includes the compacting half of
///   `history_compaction`; beyond that, the difference is what recycling
///   every cold row costs during a burst of output right after compaction.
private func registerHistoryBenchmarks() {
    Benchmark(
        "history_compaction",
        configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
    ) { benchmark in
        let (host, terminal) = historyTerminal()
        defer { withExtendedLifetime(host) {} }
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            terminal.compactHistory(.full)
            terminal.restoreHistory()
        }
        benchmark.stopMeasurement()
    }

    Benchmark(
        "history_cold_read",
        configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
    ) { benchmark in
        let (host, terminal) = historyTerminal()
        defer { withExtendedLifetime(host) {} }
        terminal.compactHistory(.full)
        precondition(terminal.historyStorage.coldRows > 9_900)
        let buffer = terminal.buffer
        let first = buffer.totalLinesTrimmed
        let rows = terminal.historyStorage.coldRows + terminal.historyStorage.residentRows
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for row in first..<(first + rows) {
                blackHole(buffer.readScrollInvariantLine(row: row))
            }
        }
        benchmark.stopMeasurement()
    }

    for cold in [true, false] {
        Benchmark(
            cold ? "history_scroll_over_cold" : "history_scroll_over_warm",
            configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
        ) { benchmark in
            let (host, terminal) = historyTerminal()
        defer { withExtendedLifetime(host) {} }
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                if cold {
                    terminal.compactHistory(.full)
                }
                terminal.feed(byteArray: historyOutput)
            }
            benchmark.stopMeasurement()
        }
    }
}

let benchmarks: @Sendable () -> Void = {
    registerHistoryBenchmarks()

    for workload in SwiftTermBenchmarks.workloads {
        Benchmark(
            workload.name,
            configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
        ) { benchmark in
            feed(benchmark, workload: workload)
        }
    }

    if ProcessInfo.processInfo.environment["SWIFTTERM_HARDENING_BENCHMARKS"] == "1" {
        for workload in SwiftTermBenchmarks.hardeningWorkloads {
            Benchmark(
                workload.name,
                configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
            ) { benchmark in
                feed(benchmark, workload: workload)
            }
        }
    }

    Benchmark(
        "kitty_snapshot_empty",
        configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
    ) { benchmark in
        snapshot(benchmark, imageSize: nil)
    }

    Benchmark(
        "kitty_snapshot_3mb",
        configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
    ) { benchmark in
        snapshot(benchmark, imageSize: (width: 1024, height: 768))
    }
}
#else
let benchmarks: @Sendable () -> Void = { }
#endif
