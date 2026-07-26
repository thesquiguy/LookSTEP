import Foundation
import Testing
@testable import LookSTEP

struct StepPresentationTransactionTests {
    @Test
    func cancellationRestoresDisplayedDocumentAndRejectsStaleCompletion() {
        let generation = UUID()
        var transaction = StepPresentationTransaction()

        transaction.begin(generation: generation)

        #expect(transaction.isActive)
        #expect(transaction.cancel() == .restoreDisplayedDocument)
        #expect(!transaction.isActive)
        let acceptedStaleCompletion = transaction.complete(generation: generation)
        #expect(!acceptedStaleCompletion)
        #expect(transaction.cancel() == .none)
    }

    @Test
    func staleCallbackCannotCompleteReplacementPresentation() {
        let firstGeneration = UUID()
        let secondGeneration = UUID()
        var transaction = StepPresentationTransaction()

        transaction.begin(generation: firstGeneration)
        transaction.begin(generation: secondGeneration)

        let acceptedStaleCompletion = transaction.complete(generation: firstGeneration)
        #expect(!acceptedStaleCompletion)
        #expect(transaction.isActive)
        #expect(transaction.generation == secondGeneration)
        let acceptedCurrentCompletion = transaction.complete(generation: secondGeneration)
        #expect(acceptedCurrentCompletion)
        #expect(!transaction.isActive)
    }
}
