import Testing
import Foundation
@testable import InfraredConverter

/// What the channel-mix stage refuses.
///
/// `WorkingColorRGBImage` is publicly constructible on purpose — it is a data
/// representation, not a provenance claim — so a hand-built image can carry
/// anything, and the processing boundary has to defend itself. Every path
/// defends it: the identity path, the red/blue permutation and the general
/// matrix all report the coordinate and channel of the first value they cannot
/// use, rather than clamping it or letting it through.
///
/// This is the other half of the bit-preservation claim `IRChannelMixerTests`
/// makes. Identity and the permutation preserve the bit pattern of every value
/// the stage **accepts**; the values it does not accept — NaN and infinity —
/// are refused here, on those same two paths. Neither statement is true
/// without the other.
@Suite("IRChannelMixer errors")
struct IRChannelMixerErrorTests {

    static func image(width: Int, height: Int, values: [Float]) -> WorkingColorRGBImage {
        IRChannelMixerTests.image(width: width, height: height, values: values)
    }

    /// A 2×2 image whose pixel at `(row, column)` has `value` in `channel` and
    /// ordinary numbers everywhere else.
    static func imagePoisoned(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        with value: Float
    ) -> WorkingColorRGBImage {
        var values = (0..<12).map { Float($0) * 0.25 }
        values[(row * 2 + column) * 3 + channel.storageOffset] = value
        return image(width: 2, height: 2, values: values)
    }

    /// Every mix whose execution path differs: no arithmetic, permutation, and
    /// nine multiplications.
    static func allPaths() throws -> [IRChannelMix] {
        [
            .identity,
            .redBlueSwap,
            .explicit(matrix: try IRChannelMixerTests.asymmetricMatrix()),
        ]
    }

    // MARK: - Non-finite input

    @Test("NaN, +infinity and -infinity inputs are refused on every path")
    func nonFiniteInputsAreRefusedEverywhere() throws {
        let mixer = IRChannelMixer()
        let poisons: [Float] = [.nan, .infinity, -.infinity]

        for mix in try Self.allPaths() {
            for poison in poisons {
                let input = Self.imagePoisoned(row: 1, column: 0, channel: .green, with: poison)
                #expect {
                    _ = try mixer.apply(to: input, mix: mix)
                } throws: { error in
                    guard case .nonFiniteChannelMixInput(let row, let column, let channel, _) =
                            error as? IRProcessingError else { return false }
                    return row == 1 && column == 0 && channel == .green
                }
            }
            // The value travels with the error, except for NaN, which no
            // comparison can match — the coordinate above is what identifies
            // it.
            let input = Self.imagePoisoned(row: 0, column: 1, channel: .blue, with: .infinity)
            #expect {
                _ = try mixer.apply(to: input, mix: mix)
            } throws: { error in
                guard case .nonFiniteChannelMixInput(let row, let column, let channel, let value) =
                        error as? IRProcessingError else { return false }
                return row == 0 && column == 1 && channel == .blue && value == .infinity
            }
        }
    }

    @Test("Each channel is reported as itself, not as the first one")
    func theOffendingChannelIsNamed() throws {
        let mixer = IRChannelMixer()
        for channel in RAWLinearRGBChannel.allCases {
            let input = Self.imagePoisoned(row: 1, column: 1, channel: channel, with: .nan)
            #expect {
                _ = try mixer.apply(to: input, mix: .redBlueSwap)
            } throws: { error in
                guard case .nonFiniteChannelMixInput(let row, let column, let reported, _) =
                        error as? IRProcessingError else { return false }
                return row == 1 && column == 1 && reported == channel
            }
        }
    }

    // MARK: - Non-finite results

    /// A finite input and a finite matrix whose `Double` product cannot be
    /// narrowed back to `Float32`.
    @Test("A result that overflows Float32 on narrowing is refused, not clamped")
    func narrowingOverflowIsRefused() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 1, m01: 0, m02: 0,
            m10: 0, m11: 1, m12: 0,
            // 3 × greatestFiniteMagnitude is finite in Double and infinite in
            // Float32, so this fails on the single narrowing.
            m20: 0, m21: 0, m22: 3
        )
        let input = IRChannelMixerTests.pixel(0.5, 0.5, .greatestFiniteMagnitude)

        #expect {
            _ = try IRChannelMixer().apply(to: input, mix: .explicit(matrix: matrix))
        } throws: { error in
            guard case .nonFiniteChannelMixResult(let row, let column, let channel) =
                    error as? IRProcessingError else { return false }
            return row == 0 && column == 0 && channel == .blue
        }
    }

    /// A single `coefficient x input` product leaving `Double`'s range.
    ///
    /// This is the easier half of the accumulation contract: one term is
    /// already infinite before anything is added to it. The harder half — a
    /// sum of terms that are each finite — is the test below.
    @Test("A single Double product that is not finite is refused")
    func doubleProductOverflowIsRefused() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: .greatestFiniteMagnitude, m01: .greatestFiniteMagnitude, m02: 0,
            m10: 0, m11: 1, m12: 0,
            m20: 0, m21: 0, m22: 1
        )
        let input = IRChannelMixerTests.pixel(.greatestFiniteMagnitude, 1, 1)

        #expect {
            _ = try IRChannelMixer().apply(to: input, mix: .explicit(matrix: matrix))
        } throws: { error in
            guard case .nonFiniteChannelMixResult(let row, let column, let channel) =
                    error as? IRProcessingError else { return false }
            return row == 0 && column == 0 && channel == .red
        }
    }

    /// The genuine accumulation overflow: nothing about any single term is out
    /// of range, and only their **sum** leaves `Double`.
    ///
    /// ```text
    /// coefficients   0.75 x Double.greatestFiniteMagnitude   finite
    /// inputs         1                                       finite
    /// each product   0.75 x Double.greatestFiniteMagnitude   finite
    /// their sum      1.5  x Double.greatestFiniteMagnitude   NOT finite
    /// ```
    ///
    /// Two terms of `0.75 x greatestFiniteMagnitude` overflow whichever order
    /// the additions happen in, so this does not depend on the implementation
    /// associating the dot product left to right. It is the case that
    /// distinguishes checking each product from checking the accumulator, and
    /// it is why the accumulator is what the mixer checks.
    @Test("A Double sum of finite products that is not finite is refused")
    func doubleAccumulationOverflowIsRefused() throws {
        let large = 0.75 * Double.greatestFiniteMagnitude
        // Stated rather than assumed: every coefficient and every product here
        // is finite, and only the sum is not.
        #expect(large.isFinite)
        #expect((large + large).isFinite == false)

        let matrix = try RAWColorMatrix3x3(
            m00: 1, m01: 0, m02: 0,
            // Output green takes finite contributions from input red and input
            // green whose sum cannot be represented.
            m10: large, m11: large, m12: 0,
            m20: 0, m21: 0, m22: 1
        )
        let input = IRChannelMixerTests.pixel(1, 1, 0.5)
        #expect((matrix.m10 * 1.0).isFinite)
        #expect((matrix.m11 * 1.0).isFinite)

        #expect {
            _ = try IRChannelMixer().apply(to: input, mix: .explicit(matrix: matrix))
        } throws: { error in
            guard case .nonFiniteChannelMixResult(let row, let column, let channel) =
                    error as? IRProcessingError else { return false }
            return row == 0 && column == 0 && channel == .green
        }
    }

    @Test("A refused image produces no partial result")
    func failureProducesNoImage() throws {
        let input = Self.imagePoisoned(row: 0, column: 0, channel: .red, with: .nan)
        var produced: IRChannelMixedRGBImage?
        do {
            produced = try IRChannelMixer().apply(to: input, mix: .redBlueSwap)
            Issue.record("expected the mixer to refuse a NaN input")
        } catch let error as IRProcessingError {
            guard case .nonFiniteChannelMixInput = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(produced == nil)
    }

    // MARK: - Geometry

    @Test("An image whose buffer does not match its dimensions is refused")
    func inconsistentGeometryIsRefused() throws {
        let mixer = IRChannelMixer()
        // Declares 2×2 (12 values) and holds 9.
        let short = Self.image(width: 2, height: 2, values: [Float](repeating: 0.5, count: 9))
        #expect {
            _ = try mixer.apply(to: short, mix: .identity)
        } throws: { error in
            guard case .invalidGeometry = error as? IRProcessingError else { return false }
            return true
        }

        let empty = Self.image(width: 0, height: 4, values: [])
        #expect {
            _ = try mixer.apply(to: empty, mix: .redBlueSwap)
        } throws: { error in
            guard case .invalidGeometry = error as? IRProcessingError else { return false }
            return true
        }
    }

    // MARK: - Error surface

    @Test("Every case carries a description and a reason")
    func errorsDescribeThemselves() {
        let errors: [IRProcessingError] = [
            .invalidGeometry(reason: "2x2 needs 12 values, buffer holds 9."),
            .channelMixWorkingColorSpaceMismatch(
                image: .extendedLinearSRGB, mix: .extendedLinearSRGB
            ),
            .nonFiniteChannelMixInput(row: 3, column: 4, channel: .green, value: .infinity),
            .nonFiniteChannelMixResult(row: 5, column: 6, channel: .blue),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.failureReason?.isEmpty == false)
        }
        #expect(errors[2].failureReason?.contains("row 3, column 4") == true)
        #expect(errors[3].failureReason?.contains("row 5, column 6") == true)
    }
}
