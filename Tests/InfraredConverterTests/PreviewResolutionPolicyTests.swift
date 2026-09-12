import Testing
import Foundation
@testable import InfraredConverter

/// The size decision, on its own.
///
/// Pure arithmetic over two integers and a limit: no image, no buffer, no
/// SwiftUI, nothing that needs a running application. That is the point of
/// having the policy as a value type — the rule can be stated once and checked
/// exhaustively.
@Suite("Preview resolution policy")
struct PreviewResolutionPolicyTests {

    static let limit = PreviewResolutionPolicy(maximumLongestEdge: 2048)

    // MARK: - Below the limit

    @Test("An image already within the limit is unchanged")
    func smallImageIsUnchanged() {
        let size = Self.limit.reducedSize(width: 800, height: 600)
        #expect(size?.width == 800)
        #expect(size?.height == 600)
    }

    @Test("An image exactly at the limit is unchanged")
    func imageExactlyAtTheLimitIsUnchanged() {
        let size = Self.limit.reducedSize(width: 2048, height: 1000)
        #expect(size?.width == 2048)
        #expect(size?.height == 1000)
    }

    @Test("A one-pixel image is unchanged, and is never zero-sized")
    func onePixelImageSurvives() {
        let size = Self.limit.reducedSize(width: 1, height: 1)
        #expect(size?.width == 1)
        #expect(size?.height == 1)
    }

    /// The rule is "never enlarge", not "always resize". A 64-pixel thumbnail
    /// must not become a 2048-pixel one made of invented detail.
    @Test("A tiny image is never enlarged to the limit")
    func tinyImageIsNeverEnlarged() {
        for policy in [PreviewResolutionPolicy(maximumLongestEdge: 2048),
                       PreviewResolutionPolicy(maximumLongestEdge: 16)] {
            let size = policy.reducedSize(width: 4, height: 3)
            #expect(size?.width == 4)
            #expect(size?.height == 3)
        }
    }

    // MARK: - Above the limit

    @Test("A landscape image larger than the limit has its width capped")
    func landscapeIsCapped() {
        let size = Self.limit.reducedSize(width: 4056, height: 3040)
        #expect(size?.width == 2048)
        #expect(size?.height == 1535)
        #expect(max(size!.width, size!.height) == 2048)
    }

    @Test("A portrait image larger than the limit has its height capped")
    func portraitIsCapped() {
        let size = Self.limit.reducedSize(width: 3040, height: 4056)
        #expect(size?.width == 1535)
        #expect(size?.height == 2048)
        #expect(max(size!.width, size!.height) == 2048)
    }

    @Test("A square image larger than the limit becomes the limit on both edges")
    func squareIsCapped() {
        let size = Self.limit.reducedSize(width: 5000, height: 5000)
        #expect(size?.width == 2048)
        #expect(size?.height == 2048)
    }

    /// The exact equality is the claim. A policy that scaled both edges and
    /// rounded each independently would land at 2047 or 2049 for some inputs.
    @Test("The longest edge equals the limit exactly, for every shape")
    func longestEdgeIsExactlyTheLimit() {
        let policy = PreviewResolutionPolicy(maximumLongestEdge: 300)
        for width in stride(from: 301, through: 1200, by: 37) {
            for height in stride(from: 1, through: 1200, by: 53) {
                guard let size = policy.reducedSize(width: width, height: height) else {
                    Issue.record("No size for \(width)x\(height)")
                    continue
                }
                if max(width, height) > 300 {
                    #expect(max(size.width, size.height) == 300)
                }
                #expect(size.width >= 1)
                #expect(size.height >= 1)
                #expect(size.width <= width)
                #expect(size.height <= height)
            }
        }
    }

    @Test("The aspect ratio is preserved to within one pixel of rounding")
    func aspectRatioIsPreserved() {
        let policy = PreviewResolutionPolicy(maximumLongestEdge: 512)
        for (width, height) in [(4056, 3040), (3040, 4056), (6000, 4000), (1919, 1081)] {
            let size = try! #require(policy.reducedSize(width: width, height: height))
            let sourceRatio = Double(width) / Double(height)
            let previewRatio = Double(size.width) / Double(size.height)
            // One pixel of rounding on the shorter edge is the whole error
            // budget; it shows up as a ratio difference of at most
            // 1 / shorterEdge.
            #expect(abs(previewRatio - sourceRatio) < sourceRatio / Double(min(size.width, size.height)))
        }
    }

    // MARK: - Awkward shapes

    @Test("Odd dimensions give deterministic integer dimensions")
    func oddDimensionsAreDeterministic() {
        let policy = PreviewResolutionPolicy(maximumLongestEdge: 101)
        let first = policy.reducedSize(width: 1003, height: 777)
        let second = policy.reducedSize(width: 1003, height: 777)
        #expect(first?.width == second?.width)
        #expect(first?.height == second?.height)
        #expect(first?.width == 101)
        #expect(first?.height == 78)   // round(777 × 101/1003) = round(78.25)
    }

    /// An extreme strip: the shorter edge scales to less than half a pixel and
    /// must not become zero.
    @Test("A one-pixel-high strip reduces to a one-pixel-high strip")
    func oneDimensionOfOneSurvives() {
        let size = Self.limit.reducedSize(width: 5000, height: 1)
        #expect(size?.width == 2048)
        #expect(size?.height == 1)
    }

    @Test("A one-pixel-wide column reduces to a one-pixel-wide column")
    func oneDimensionOfOneSurvivesInPortrait() {
        let size = Self.limit.reducedSize(width: 1, height: 5000)
        #expect(size?.width == 1)
        #expect(size?.height == 2048)
    }

    @Test("No input ever produces a zero-sized preview")
    func neverZeroSized() {
        let policy = PreviewResolutionPolicy(maximumLongestEdge: 8)
        for width in 1...200 {
            for height in [1, 2, 3, 7, 199, 200] {
                guard let size = policy.reducedSize(width: width, height: height) else {
                    Issue.record("No size for \(width)x\(height)")
                    continue
                }
                #expect(size.width >= 1)
                #expect(size.height >= 1)
            }
        }
    }

    // MARK: - Unusable input

    @Test("Non-positive dimensions have no answer")
    func nonPositiveDimensionsHaveNoAnswer() {
        #expect(Self.limit.reducedSize(width: 0, height: 10) == nil)
        #expect(Self.limit.reducedSize(width: 10, height: 0) == nil)
        #expect(Self.limit.reducedSize(width: -4, height: 10) == nil)
    }

    @Test("A non-positive limit has no answer")
    func nonPositiveLimitHasNoAnswer() {
        let policy = PreviewResolutionPolicy(maximumLongestEdge: 0)
        #expect(policy.reducedSize(width: 100, height: 100) == nil)
    }

    // MARK: - The workspace default

    @Test("The workspace default is the documented 2048")
    func theWorkspaceDefaultIsDocumented() {
        #expect(PreviewResolutionPolicy.workspace.maximumLongestEdge == 2048)
    }

    // MARK: - Orientation cannot change the answer

    /// The size is decided on the unoriented image, and the eight orientations
    /// are exact permutations of whole pixels. They may exchange width and
    /// height but cannot change which is larger, so the limit is still exactly
    /// satisfied after orientation.
    @Test("Every orientation of a capped preview is still within the limit")
    func orientationPreservesTheCap() throws {
        let size = try #require(Self.limit.reducedSize(width: 4056, height: 3040))
        for orientation in RAWImageOrientation.allCases {
            let output = orientation.outputDimensions(
                sourceWidth: size.width, sourceHeight: size.height
            )
            #expect(max(output.width, output.height) == 2048)
            #expect(min(output.width, output.height) == 1535)
        }
    }
}

/// What a `PreviewResolution` record says about itself.
@Suite("Preview resolution record")
struct PreviewResolutionRecordTests {

    static func resolution(
        sourceWidth: Int, sourceHeight: Int, width: Int, height: Int,
        method: PreviewReductionMethod = .areaAverage
    ) -> PreviewResolution {
        PreviewResolution(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            width: width, height: height,
            policy: .workspace, method: method
        )
    }

    @Test("A reduced record reports the reduction, the scales and the factor")
    func reducedRecordDescribesItself() throws {
        let resolution = Self.resolution(
            sourceWidth: 4056, sourceHeight: 3040, width: 2048, height: 1535
        )
        #expect(resolution.isReduced)
        #expect(resolution.sourcePixelCount == 12_330_240)
        #expect(resolution.pixelCount == 3_143_680)
        let factor = try #require(resolution.pixelReductionFactor)
        #expect(abs(factor - 3.9222) < 0.001)
        #expect(abs(resolution.horizontalScale - 0.50493) < 0.0001)
        #expect(abs(resolution.verticalScale - 0.50493) < 0.0001)
    }

    @Test("An unreduced record says so, and its factor is one")
    func unreducedRecordSaysSo() throws {
        let resolution = Self.resolution(
            sourceWidth: 8, sourceHeight: 6, width: 8, height: 6, method: .unreduced
        )
        #expect(!resolution.isReduced)
        #expect(resolution.method == .unreduced)
        #expect(try #require(resolution.pixelReductionFactor) == 1)
        #expect(resolution.horizontalScale == 1)
        #expect(resolution.verticalScale == 1)
    }
}
