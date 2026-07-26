import Foundation

nonisolated struct StepPresentationTransaction: Equatable {
    enum CancellationEffect: Equatable {
        case none
        case restoreDisplayedDocument
    }

    private(set) var generation: UUID?

    var isActive: Bool {
        generation != nil
    }

    mutating func begin(generation: UUID) {
        self.generation = generation
    }

    mutating func complete(generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        self.generation = nil
        return true
    }

    mutating func cancel() -> CancellationEffect {
        guard generation != nil else { return .none }
        generation = nil
        return .restoreDisplayedDocument
    }
}
