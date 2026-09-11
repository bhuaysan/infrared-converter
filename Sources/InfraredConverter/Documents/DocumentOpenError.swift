import Foundation

/// Why one of the workspace's two RAW paths refused a file.
///
/// Kept as a value rather than as a bare `Error` because the two paths'
/// refusals are carried and reported together: the owned pipeline's stages
/// throw several error types, the decoder throws one, and both have to survive
/// into the same sentence without either being flattened into "failed".
public struct RAWPathFailure: Error, Equatable {
    /// The refusal as a decoder error, when the decoder was the stage that
    /// refused. `nil` when a later stage did — a normalisation, a demosaic, a
    /// colour conversion, an orientation.
    public let decoding: RAWDecodingError?

    /// What the refusal says, for a reader.
    public let message: String

    public init(_ error: Error) {
        self.decoding = error as? RAWDecodingError
        self.message = error.localizedDescription
    }
}

/// Why the workspace could not open a file at all.
///
/// Reached only when **both** paths refused it. Either path succeeding alone
/// leaves the file open, which is the point of the type existing:
///
/// ```text
/// owned ok   / legacy ok    → workspace image + diagnostic reference
/// owned ok   / legacy fails → workspace image, reference reported missing
/// owned fails/ legacy ok    → the owned failure, reported; never a fallback
/// owned fails/ legacy fails → this error
/// ```
///
/// The application-owned pipeline is the workspace image. The LibRaw
/// processed-RGB decode is a diagnostic reference beside it. Neither is a gate
/// on the other, and neither ever stands in for the other.
public struct DocumentOpenError: Error, Equatable, LocalizedError {
    public let url: URL

    /// The application-owned pipeline's refusal. The one that matters: it is
    /// the image the workspace would have shown.
    public let owned: RAWPathFailure

    /// The legacy diagnostic decode's refusal, kept because a difference
    /// between the two is itself the diagnosis. Two identical messages say the
    /// file is unreadable; two different ones say which stage disagreed.
    public let legacy: RAWPathFailure

    public init(url: URL, owned: RAWPathFailure, legacy: RAWPathFailure) {
        self.url = url
        self.owned = owned
        self.legacy = legacy
    }

    public var errorDescription: String? {
        "\(url.lastPathComponent) could not be opened."
    }

    public var failureReason: String? {
        """
        The image pipeline refused it: \(owned.message) \
        The LibRaw diagnostic decode refused it too: \(legacy.message)
        """
    }
}
