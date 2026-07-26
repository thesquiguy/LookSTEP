import Foundation

nonisolated enum StepPreviewBackgroundPreference {
    static let alwaysWhiteKey = "LookSTEP.previewBackgroundAlwaysWhite"
    static let defaultAlwaysWhite = true

    static var sharedDefaults: UserDefaults {
        if let appGroupIdentifier = StepCacheLocation.configuredAppGroupIdentifier,
           let defaults = UserDefaults(suiteName: appGroupIdentifier) {
            return defaults
        }
        return .standard
    }

    static func isAlwaysWhite(storedValue: Any?) -> Bool {
        (storedValue as? Bool) ?? defaultAlwaysWhite
    }
}
