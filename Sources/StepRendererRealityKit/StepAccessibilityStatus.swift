import SwiftUI

struct StepAccessibilityStatus: Equatable, Sendable {
    enum Kind: String, Sendable {
        case empty
        case loading
        case failure
    }

    let kind: Kind
    let label: String
    let value: String

    var identifier: String {
        "lookstep.status.\(kind.rawValue)"
    }

    static func empty(detail: String) -> Self {
        Self(
            kind: .empty,
            label: "No STEP model open",
            value: detail
        )
    }

    static func loading(phase: String, fileName: String? = nil) -> Self {
        let detail = [phase, fileName]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
        return Self(
            kind: .loading,
            label: "Opening STEP model",
            value: detail
        )
    }

    static func failure(title: String, message: String) -> Self {
        Self(kind: .failure, label: title, value: message)
    }
}

private struct StepAccessibilityStatusModifier: ViewModifier {
    let status: StepAccessibilityStatus

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.label)
            .accessibilityValue(status.value)
            .accessibilityIdentifier(status.identifier)
    }
}

extension View {
    func stepAccessibilityStatus(_ status: StepAccessibilityStatus) -> some View {
        modifier(StepAccessibilityStatusModifier(status: status))
    }
}
