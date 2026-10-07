import Foundation

/// One `threads.modify` payload. Producers order arrays deterministically and keep add ∩ remove = ∅.
public struct LabelChange: Sendable, Equatable, Hashable {
    public var add: [String]
    public var remove: [String]

    public init(add: [String] = [], remove: [String] = []) {
        self.add = add
        self.remove = remove
    }

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }

    /// Reverts `self` on a thread whose labels were `before`:
    /// add = remove ∩ before (in remove order); remove = add − before (in add order).
    public func inverse(before: Set<String>) -> LabelChange {
        LabelChange(add: remove.filter { before.contains($0) }, remove: add.filter { !before.contains($0) })
    }
}
