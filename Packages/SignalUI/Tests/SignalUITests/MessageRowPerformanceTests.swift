// PERF_PROBE=1 [PERF_RUNS=n]: the cost of laying out a timeline row (40 messages in one hosting
// view, minus the hosting view's own cost). Off by default; for profiling scroll performance:
// swift test -c release -Xswiftc -enable-testing --filter MessageRowPerformanceTests

import AppKit
import SwiftUI
import Testing
import SignalUI

@MainActor @Suite struct MessageRowPerformanceTests {
    func column(_ count: Int, seed: Int) -> some View {
        let texts = ["ok", "Hey, are we still on for dinner tonight? I was thinking about that new place downtown.",
                     String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 4)]
        return VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                var p = MessageProps(id: "m\(seed)-\(i)", direction: i % 2 == 0 ? .incoming : .outgoing,
                                     author: MessageProps.Author(id: "a\(i % 3)", title: "Alice \(i % 3)"),
                                     text: texts[i % 3] + " \(seed)-\(i)", timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 60)))
                let _ = p.conversationType = .group
                TimelineItem(item: .message(p))
            }
        }.frame(width: 700)
    }

    @Test func messageRowCost() throws {
        guard ProcessInfo.processInfo.environment["PERF_PROBE"] != nil else { return }
        let rounds = Int(ProcessInfo.processInfo.environment["PERF_RUNS"] ?? "10") ?? 10
        let clock = ContinuousClock()
        let n = 40
        let empty = clock.measure {
            for r in 0..<rounds {
                let h = NSHostingView(rootView: AnyView(Color.clear.frame(width: 700, height: 10).id(r)))
                h.layoutSubtreeIfNeeded()
                _ = h.fittingSize
            }
        }
        let full = clock.measure {
            for r in 0..<rounds {
                let h = NSHostingView(rootView: AnyView(column(n, seed: r)))
                h.layoutSubtreeIfNeeded()
                _ = h.fittingSize
            }
        }
        print("PERF per row: \((full - empty) / (rounds * n))  (host overhead \(empty / rounds))")
    }
}
