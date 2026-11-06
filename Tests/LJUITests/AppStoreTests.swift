import Testing
import LJCore
@testable import LJUI

@MainActor
@Suite struct AppStoreTests {
    @Test func observerFiresOnlyOnRealChange() {
        let store = AppStore()
        var calls = 0
        store.observe { calls += 1 }
        store.update { $0.page = .music } // unchanged
        #expect(calls == 0)
        store.update { $0.page = .ai }
        #expect(calls == 1)
        #expect(store.state.page == .ai)
        store.update { $0.page = .ai }
        #expect(calls == 1)
    }

    @Test func everyObserverSeesEachChange() {
        let store = AppStore()
        var a = 0, b = 0
        store.observe { a += 1 }
        store.observe { b += 1 }
        store.update { $0.page = .ai }
        #expect(a == 1 && b == 1)
    }

    @Test func unchangedStateNotifiesNobody() {
        let store = AppStore()
        var n = 0
        store.observe { n += 1 }
        store.update { $0.page = .music }
        #expect(n == 0)
    }

    @Test func removedObserverStopsFiring() {
        let store = AppStore()
        var a = 0, b = 0
        let ta = store.observe { a += 1 }
        store.observe { b += 1 }
        store.removeObserver(ta)
        store.update { $0.theme = .jinxBlue }
        #expect(a == 0 && b == 1)
    }

    @Test func frameLoopAndAnotherObserverCoexist() {
        let store = AppStore()
        var menu = 0
        store.observe { menu += 1 }
        let loop = FrameLoop(store: store, push: { _ in }, isConnected: { false })
        store.update { $0.page = .notifications }
        #expect(menu == 1)
        #expect(loop.fps == 0)
    }
}
