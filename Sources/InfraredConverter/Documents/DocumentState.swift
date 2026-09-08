import Foundation
import Observation

/// Minimal workspace state. Retains the file the user selected via
/// "Open RAW…" so it can later be handed to the RAW decoder.
///
/// This is not `ImageDocument` yet — no decoding, metadata, or
/// adjustments are represented here.
@Observable
final class DocumentState {
    private(set) var selectedFileURL: URL?

    func select(_ url: URL) {
        selectedFileURL = url
    }
}
