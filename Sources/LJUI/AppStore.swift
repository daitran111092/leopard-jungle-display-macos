import Foundation
import LJCore

/// Single source of truth for the UI. Mutate only through `update`; observers fire only when the
/// state actually changed (Equatable), so redundant source callbacks never cost a frame.
/// Several observers may watch the store (the frame loop marks itself dirty, the menu bar refreshes).
@MainActor
public final class AppStore {
    public struct ObserverToken: Hashable, Sendable { fileprivate let id: Int }

    public private(set) var state: UiState
    private var observers: [(id: Int, fire: () -> Void)] = []
    private var nextID = 0

    public init(_ state: UiState = UiState()) { self.state = state }

    /// Calls `f` after every real state change, in registration order.
    @discardableResult
    public func observe(_ f: @escaping () -> Void) -> ObserverToken {
        nextID += 1
        observers.append((nextID, f))
        return ObserverToken(id: nextID)
    }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeAll { $0.id == token.id }
    }

    public func update(_ f: (inout UiState) -> Void) {
        var s = state
        f(&s)
        guard s != state else { return }
        state = s
        for o in observers { o.fire() }
    }
}
