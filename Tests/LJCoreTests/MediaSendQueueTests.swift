import Testing
import Foundation
@testable import LJCore

/// Manual clock: scheduled callbacks run only when the test fires them; sends complete only when the test says so.
@MainActor final class FakeMedia {
    var timers: [(delay: TimeInterval, fire: @MainActor @Sendable () -> Void)] = []
    var sent: [MediaCommand] = []
    var pendingDone: [@MainActor @Sendable () -> Void] = []
    lazy var queue = MediaSendQueue(
        window: 0.25, sendTimeout: 3,
        schedule: { [unowned self] d, f in timers.append((d, f)) },
        send: { [unowned self] c, done in sent.append(c); pendingDone.append(done) })

    func fireTimers() { let t = timers; timers = []; for x in t { x.fire() } }
    func fireTimersOfDelay(_ d: TimeInterval) {
        let t = timers.filter { $0.delay == d }
        timers.removeAll { $0.delay == d }
        for x in t { x.fire() }
    }
    func complete() { let d = pendingDone.removeFirst(); d() }
}

@MainActor @Suite struct MediaSendQueueTests {
    @Test func rapidSeeksCollapseToLastTarget() {
        let m = FakeMedia()
        for x in [10.0, 15, 20, 25, 30] { m.queue.enqueue(.seek(x)) } // 5 knob ticks within 100 ms
        #expect(m.sent.isEmpty)                    // held for the 250 ms window
        #expect(m.timers.count == 1)
        #expect(m.timers.first?.delay == 0.25)
        m.fireTimers()
        #expect(m.sent == [.seek(30)])             // one send, last target
        m.complete()
        #expect(m.sent == [.seek(30)])
    }

    @Test func sendsAreSerialized() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)
        m.queue.enqueue(.next)
        #expect(m.sent == [.toggle])               // second waits for the first to finish
        m.complete()
        #expect(m.sent == [.toggle, .next])
        m.complete()
        m.queue.enqueue(.prev)                     // idle again → immediate
        #expect(m.sent == [.toggle, .next, .prev])
    }

    @Test func seeksWaitingBehindAnInFlightSendCoalesce() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)                   // in flight
        m.queue.enqueue(.seek(5)); m.fireTimersOfDelay(0.25)  // window 1 closes → queued behind toggle
        m.queue.enqueue(.seek(9)); m.fireTimersOfDelay(0.25)  // window 2 closes → replaces the queued seek
        #expect(m.sent == [.toggle])
        m.complete()
        #expect(m.sent == [.toggle, .seek(9)])
        m.complete()
        #expect(m.pendingDone.isEmpty)
    }

    @Test func trackChangeDropsPendingSeek() {
        let m = FakeMedia()
        m.queue.enqueue(.seek(50))
        m.queue.enqueue(.next)                     // a seek aimed at the old track must not land on the new one
        #expect(m.sent == [.next])
        m.fireTimers()
        m.complete()
        #expect(m.sent == [.next])
        m.queue.enqueue(.seek(3))                  // a new window still works
        m.fireTimers()
        #expect(m.sent == [.next, .seek(3)])
    }

    @Test func doneCalledTwiceIsHarmless() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)
        let done = m.pendingDone[0]
        m.queue.enqueue(.next)
        done(); done()
        #expect(m.sent == [.toggle, .next])
        m.queue.enqueue(.prev)
        #expect(m.sent == [.toggle, .next])        // .next still in flight
    }

    @Test func hungSendTimesOut() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)                   // never completes
        m.queue.enqueue(.next)
        #expect(m.sent == [.toggle])
        #expect(m.timers.map(\.delay) == [3])     // the send timeout
        m.fireTimers()
        #expect(m.sent == [.toggle, .next])        // queue moves on
        m.pendingDone[0]()                         // the hung send finally ends: ignored
        m.queue.enqueue(.prev)
        #expect(m.sent == [.toggle, .next])        // .next still in flight
    }

    @Test func timeoutOfFinishedSendIsIgnored() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)
        m.complete()
        m.queue.enqueue(.next)                     // in flight
        m.fireTimers()                             // fires toggle's (stale) timeout and next's: next times out
        m.queue.enqueue(.prev)
        #expect(m.sent == [.toggle, .next, .prev])
        m.timers = []
        m.queue.enqueue(.toggle)                   // prev in flight
        m.complete()                               // completes .next: stale id, ignored
        #expect(m.sent == [.toggle, .next, .prev])
    }

    @Test func cancelAllStopsEverything() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)                   // in flight
        m.queue.enqueue(.next)                     // queued
        m.queue.enqueue(.seek(10))                 // window open
        m.queue.cancelAll()
        m.fireTimers()                             // window close + timeout: no-ops
        m.complete()                               // late done of the toggle: no-op
        #expect(m.sent == [.toggle])
        m.queue.enqueue(.prev)                     // usable again afterwards
        #expect(m.sent == [.toggle, .prev])
    }

    @Test func newerSeekIsQueuedLastFIFO() {
        let m = FakeMedia()
        m.queue.enqueue(.toggle)                   // in flight
        m.queue.enqueue(.seek(5)); m.fireTimersOfDelay(0.25)
        m.queue.enqueue(.toggle)
        m.queue.enqueue(.seek(9)); m.fireTimersOfDelay(0.25)
        m.complete(); m.complete()
        #expect(m.sent == [.toggle, .toggle, .seek(9)])
    }
}
