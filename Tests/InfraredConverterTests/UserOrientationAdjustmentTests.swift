import Testing
import Foundation
@testable import InfraredConverter

/// The user-owned orientation adjustment: its canonical states, the operations
/// a UI performs on it, and its serialised form.
@Suite("UserOrientationAdjustment")
struct UserOrientationAdjustmentTests {

    // MARK: - Canonical states

    @Test("There are exactly eight canonical states, all distinct")
    func thereAreEightStates() {
        #expect(UserOrientationAdjustment.allCases.count == 8)
        #expect(Set(UserOrientationAdjustment.allCases.map(\.persistedToken)).count == 8)
        #expect(Set(UserOrientationAdjustment.allCases.map(\.transform.exifOrientation)).count == 8)
    }

    @Test("The named states are the orientations they claim to be")
    func theNamedStatesAreCorrect() {
        #expect(UserOrientationAdjustment.identity.transform == .upright)
        #expect(UserOrientationAdjustment.quarterTurnRight.transform == .rotated90Clockwise)
        #expect(UserOrientationAdjustment.quarterTurnLeft.transform == .rotated270Clockwise)
        #expect(UserOrientationAdjustment.halfTurn.transform == .rotated180)
        #expect(UserOrientationAdjustment.horizontalFlip.transform == .mirroredHorizontally)
        #expect(UserOrientationAdjustment.verticalFlip.transform == .mirroredVertically)
        #expect(UserOrientationAdjustment.diagonalFlip.transform == .transposed)
        #expect(UserOrientationAdjustment.antiDiagonalFlip.transform == .transverse)

        #expect(UserOrientationAdjustment.identity.isIdentity)
        #expect(!UserOrientationAdjustment.quarterTurnRight.isIdentity)
        #expect(UserOrientationAdjustment.quarterTurnRight.swapsDimensions)
        #expect(!UserOrientationAdjustment.halfTurn.swapsDimensions)
        #expect(UserOrientationAdjustment.horizontalFlip.isMirrored)
        #expect(!UserOrientationAdjustment.halfTurn.isMirrored)
    }

    // MARK: - A state, not a history

    /// The property the persisted model depends on: pressing a button repeatedly
    /// accumulates into one canonical state, never into a list of commands.
    @Test("Four rotate-rights persist as the identity, not as four commands")
    func repeatedRotationsCanonicalise() {
        var adjustment = UserOrientationAdjustment.identity
        var seen: [UserOrientationAdjustment] = []
        for _ in 0..<4 {
            adjustment = adjustment.rotatedRight()
            seen.append(adjustment)
        }

        #expect(seen[0] == .quarterTurnRight)
        #expect(seen[1] == .halfTurn)
        #expect(seen[2] == .quarterTurnLeft)
        #expect(seen[3] == .identity)
        #expect(adjustment == .identity)
        #expect(adjustment.persistedToken == "none")
    }

    @Test("Rotate left is the inverse of rotate right")
    func rotationsUndoEachOther() {
        for start in UserOrientationAdjustment.allCases {
            #expect(start.rotatedRight().rotatedLeft() == start)
            #expect(start.rotatedLeft().rotatedRight() == start)
            #expect(start.rotatedHalfTurn().rotatedHalfTurn() == start)
        }
    }

    @Test("Each flip applied twice returns to where it started")
    func flipsAreInvolutions() {
        for start in UserOrientationAdjustment.allCases {
            #expect(start.flippedHorizontally().flippedHorizontally() == start)
            #expect(start.flippedVertically().flippedVertically() == start)
        }
    }

    @Test("Every adjustment composed with its inverse is the identity")
    func inversesCancel() {
        for adjustment in UserOrientationAdjustment.allCases {
            #expect(adjustment.applying(adjustment.inverse) == .identity)
            #expect(adjustment.inverse.applying(adjustment) == .identity)
        }
    }

    /// The two states no single control reaches are still reachable, so the
    /// model has no corner a user can be stranded in or locked out of.
    @Test("Combining controls reaches the two diagonal states")
    func theDiagonalStatesAreReachable() {
        #expect(UserOrientationAdjustment.horizontalFlip.rotatedRight() == .antiDiagonalFlip)
        #expect(UserOrientationAdjustment.horizontalFlip.rotatedLeft() == .diagonalFlip)
        #expect(UserOrientationAdjustment.verticalFlip.rotatedRight() == .diagonalFlip)
        #expect(UserOrientationAdjustment.diagonalFlip != .antiDiagonalFlip)
    }

    /// Reset is the identity adjustment, full stop. It is not "make upright",
    /// and the difference only shows on a file that records a rotation — which
    /// `EffectiveImageOrientationTests` covers.
    @Test("Reset is the identity adjustment")
    func resetIsIdentity() {
        #expect(UserOrientationAdjustment.reset == .identity)
        #expect(UserOrientationAdjustment.reset.transform == .upright)
        #expect(UserOrientationAdjustment.reset.isIdentity)
    }

    // MARK: - Serialisation

    @Test("Every state round-trips through JSON unchanged")
    func everyStateRoundTrips() throws {
        for adjustment in UserOrientationAdjustment.allCases {
            let data = try JSONEncoder().encode(adjustment)
            let decoded = try JSONDecoder().decode(UserOrientationAdjustment.self, from: data)
            #expect(decoded == adjustment, "\(adjustment.persistedToken)")
            #expect(decoded.transform == adjustment.transform)
        }
    }

    /// The tokens are a wire format, so they are pinned here. A change to any
    /// of them breaks every persisted adjustment and needs a schema version.
    @Test("The persisted tokens are the documented, stable strings")
    func theTokensAreStable() throws {
        let expected: [(UserOrientationAdjustment, String)] = [
            (.identity, "none"),
            (.quarterTurnRight, "rotate90Clockwise"),
            (.halfTurn, "rotate180"),
            (.quarterTurnLeft, "rotate270Clockwise"),
            (.horizontalFlip, "flipHorizontal"),
            (.verticalFlip, "flipVertical"),
            (.diagonalFlip, "transposeMainDiagonal"),
            (.antiDiagonalFlip, "transposeAntiDiagonal"),
        ]
        for (adjustment, token) in expected {
            #expect(adjustment.persistedToken == token)
            #expect(UserOrientationAdjustment(persistedToken: token) == adjustment)
            let encoded = try JSONEncoder().encode(adjustment)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(token)\"")
        }
    }

    /// Nothing persisted is a case index, an `allCases` position, a LibRaw
    /// `flip` bitfield or an EXIF code — all four of which would either break
    /// on a declaration-order change or tie saved edits to a decoder.
    @Test("The persisted form is semantic, never a number")
    func theFormIsNotANumber() throws {
        for adjustment in UserOrientationAdjustment.allCases {
            let text = String(
                decoding: try JSONEncoder().encode(adjustment), as: UTF8.self
            )
            #expect(Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) == nil)
        }
    }

    // MARK: - Malformed persisted values

    /// The stated policy: an unreadable token is an error, never silently the
    /// identity. Substituting identity would discard a user's rotation and
    /// present the result as their own decision.
    @Test(
        "An unknown token is refused, not read as no correction",
        arguments: ["", "rotate90", "ROTATE90CLOCKWISE", "upright", "flipDiagonal", "7", "1"]
    )
    func anUnknownTokenIsRefused(token: String) throws {
        #expect(UserOrientationAdjustment(persistedToken: token) == nil)

        let json = Data("\"\(token)\"".utf8)
        #expect(throws: ImageAdjustmentError.unknownOrientationAdjustment(token: token)) {
            try JSONDecoder().decode(UserOrientationAdjustment.self, from: json)
        }
    }

    @Test("The refusal names the token it could not read")
    func theRefusalIsInformative() {
        let error = ImageAdjustmentError.unknownOrientationAdjustment(token: "rotateSideways")
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.failureReason?.contains("rotateSideways") == true)
        // And it says why it did not guess.
        #expect(error.failureReason?.contains("no correction") == true)
    }

    @Test("A token of the wrong JSON type is refused")
    func aNonStringTokenIsRefused() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UserOrientationAdjustment.self, from: Data("6".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UserOrientationAdjustment.self, from: Data("null".utf8))
        }
    }
}
