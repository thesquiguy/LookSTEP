import SwiftUI

struct LookSTEPSettingsView: View {
    @AppStorage(
        StepPreviewBackgroundPreference.alwaysWhiteKey,
        store: StepPreviewBackgroundPreference.sharedDefaults
    )
    private var alwaysUseWhitePreviewBackground =
        StepPreviewBackgroundPreference.defaultAlwaysWhite

    var body: some View {
        Form {
            Toggle(
                "Always use a white preview background",
                isOn: $alwaysUseWhitePreviewBackground
            )
            Text("Turn this off to follow your Mac’s Light or Dark appearance.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .scenePadding()
    }
}
