import AppKit
import SwiftUI

@main
struct LookSTEPApp: App {
    static let contentTypeDiagnosticsWindowID = "LookSTEP.diagnostics.contentType"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 500)
        }
        .defaultSize(width: 1_080, height: 760)
        .commands {
            LookSTEPCommands()
        }

        Window("STEP Content Type", id: Self.contentTypeDiagnosticsWindowID) {
            StepContentTypeDiagnosticsView()
                .frame(minWidth: 560, minHeight: 460)
        }
        .defaultSize(width: 680, height: 720)

        Settings {
            LookSTEPSettingsView()
        }
    }
}

private struct LookSTEPCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Diagnostics") {
            Button("STEP Content Type…") {
                openWindow(id: LookSTEPApp.contentTypeDiagnosticsWindowID)
            }
            .help("Show the content type macOS resolves a file to, and whether the preview extension claims it")
        }

        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                NotificationCenter.default.post(name: StepViewerCommand.open, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                let urls = NSDocumentController.shared.recentDocumentURLs
                if urls.isEmpty {
                    Text("No Recent Models")
                } else {
                    ForEach(urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            NotificationCenter.default.post(
                                name: StepViewerCommand.openURL,
                                object: url
                            )
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                    }
                }
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Fit Model") {
                NotificationCenter.default.post(name: StepViewerCommand.fit, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
