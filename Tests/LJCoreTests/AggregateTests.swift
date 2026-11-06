import Testing
import Foundation
@testable import LJCore

@Suite struct AggregateTests {
    @Test func groupsHelpersUnderApp() {
        let chrome = "/Applications/Google Chrome.app"
        let procs = [
            ProcSample(pid: 1, name: "Google Chrome", appPath: chrome, cpu: 10, rssBytes: 100),
            ProcSample(pid: 2, name: "Google Chrome Helper", appPath: chrome, cpu: 5, rssBytes: 200),
            ProcSample(pid: 3, name: "Google Chrome Helper (Renderer)", appPath: chrome, cpu: 2.5, rssBytes: 300),
        ]
        let s = aggregate(cpu: 20, memUsed: 1_000, memTotal: 2_000, procs: procs)
        #expect(s.topApps == [AppUsage(name: "Google Chrome", cpu: 17.5, rssBytes: 600)])
        #expect(s.cpu == 20)
        #expect(s.memUsedBytes == 1_000)
        #expect(s.memTotalBytes == 2_000)
    }

    @Test func topThreeByRAM() {
        let procs = [
            ProcSample(pid: 1, name: "a", appPath: "/Applications/A.app", cpu: 1, rssBytes: 1),
            ProcSample(pid: 2, name: "b", appPath: "/Applications/B.app", cpu: 40, rssBytes: 2),
            ProcSample(pid: 3, name: "c", appPath: "/Applications/C.app", cpu: 20, rssBytes: 3),
            ProcSample(pid: 4, name: "d", appPath: "/Applications/D.app", cpu: 30, rssBytes: 4),
            ProcSample(pid: 5, name: "e", appPath: "/Applications/E.app", cpu: 5, rssBytes: 5),
        ]
        let s = aggregate(cpu: 50, memUsed: 0, memTotal: 1, procs: procs)
        #expect(s.topApps.map(\.name) == ["E", "D", "C"])
        #expect(aggregate(cpu: 0, memUsed: 0, memTotal: 1, procs: procs, top: 2).topApps.count == 2)
    }

    @Test func nonAppProcessesGroupedByName() {
        let procs = [
            ProcSample(pid: 1, name: "node", cpu: 3, rssBytes: 10),
            ProcSample(pid: 2, name: "node", cpu: 4, rssBytes: 20),
            ProcSample(pid: 3, name: "kernel_task", cpu: 6, rssBytes: 5),
        ]
        let s = aggregate(cpu: 13, memUsed: 0, memTotal: 1, procs: procs)
        #expect(s.topApps == [AppUsage(name: "node", cpu: 7, rssBytes: 30), AppUsage(name: "kernel_task", cpu: 6, rssBytes: 5)])
    }
}
