import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var documentState = DocumentState()

    private static let rawFileExtensions = [
        "orf", "arw", "nef", "nrw", "cr2", "cr3", "raf", "rw2"
    ]

    var body: some View {
        VStack(spacing: 16) {
            if let url = documentState.selectedFileURL {
                VStack(spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No RAW file selected")
                    .foregroundStyle(.secondary)
            }

            Button("Open RAW…", action: openRAW)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }

    private func openRAW() {
        let panel = NSOpenPanel()
        panel.title = "Open RAW File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.rawFileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, let url = panel.url {
            documentState.select(url)
        }
    }
}
