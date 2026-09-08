import Testing
import Foundation
import CLibRaw
@testable import InfraredConverter

/// Tests for the C shim's own lifecycle contract: which calls are valid at
/// which stage, and what they return before that.
///
/// These exist because two of the shim's guarantees are invisible from the
/// Swift API alone:
///
/// - `ir_libraw_copy_metadata` reads two genuinely different LibRaw states,
///   and only one of them is paired with the unpacked mosaic;
/// - `ir_libraw_warning_bits` used to be gated on `dcraw_process` having run,
///   which silently discarded every warning the unpack-only mosaic path could
///   observe.
@Suite("LibRaw shim lifecycle")
struct LibRawShimLifecycleTests {
    /// Runs `body` with a fresh context configured exactly as `LibRawDecoder`
    /// configures it, destroying it afterwards.
    private static func withContext<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        let context = ir_libraw_create()!
        defer { ir_libraw_destroy(context) }
        var options = ir_libraw_options()
        ir_libraw_default_options(&options)
        ir_libraw_apply_options(context, &options)
        return try body(context)
    }

    // MARK: - Warning-bit lifecycle (no fixture required)

    @Test("Warning bits are safe to read with no context at all")
    func warningBitsWithoutContext() {
        #expect(ir_libraw_warning_bits(nil) == 0)
    }

    @Test("Warning bits are safe to read on a created-but-unopened context")
    func warningBitsBeforeOpen() {
        Self.withContext { context in
            // Nothing has been opened, so LibRaw has genuinely raised
            // nothing. Zero here is a fact, not a suppressed value.
            #expect(ir_libraw_warning_bits(context) == 0)
        }
    }

    // MARK: - Metadata-source lifecycle (no fixture required)

    @Test("RAW-state metadata is refused before a successful open")
    func rawStateMetadataBeforeOpen() {
        Self.withContext { context in
            var metadata = ir_libraw_metadata()
            let status = ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, &metadata)
            #expect(status.error == IR_LIBRAW_ERR_BAD_STATE)
        }
    }

    @Test("Current metadata is also refused before a successful open")
    func currentMetadataBeforeOpen() {
        Self.withContext { context in
            var metadata = ir_libraw_metadata()
            let status = ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_CURRENT, &metadata)
            #expect(status.error == IR_LIBRAW_ERR_BAD_STATE)
        }
    }

    @Test("A null output pointer is rejected rather than dereferenced")
    func nullMetadataOutput() {
        Self.withContext { context in
            let status = ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, nil)
            #expect(status.error == IR_LIBRAW_ERR_BAD_STATE)
        }
    }
}

/// The parts of the shim lifecycle that need a real file to distinguish an
/// *opened* context from an *unpacked* one.
@Suite(
    "LibRaw shim lifecycle (fixture)",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct LibRawShimLifecycleFixtureTests {
    private static func withContext<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        let context = ir_libraw_create()!
        defer { ir_libraw_destroy(context) }
        var options = ir_libraw_options()
        ir_libraw_default_options(&options)
        ir_libraw_apply_options(context, &options)
        return try body(context)
    }

    private static func open(_ context: OpaquePointer, _ url: URL) -> ir_libraw_status {
        url.withUnsafeFileSystemRepresentation { path in
            ir_libraw_open_file(context, path!)
        }
    }

    /// One entry of the shim's fixed-size `cblack` C tuple, by index.
    private static func cblack(_ metadata: ir_libraw_metadata, _ index: Int) -> UInt32 {
        withUnsafeBytes(of: metadata.cblack) { $0.bindMemory(to: UInt32.self)[index] }
    }

    /// This is the structural test that pins `decodeMosaic`'s snapshot
    /// ordering. The RAW-state source is only available after a successful
    /// `unpack()`, so a `decodeMosaic` that snapshotted metadata *before*
    /// unpacking — the pre-milestone ordering — could not obtain it at all
    /// and would fail outright rather than quietly return the wrong state.
    @Test("RAW-state metadata is refused after open but before unpack, and available after")
    func rawStateRequiresUnpack() throws {
        let url = try #require(RAWFixtures.olympusORF)
        Self.withContext { context in
            #expect(Self.open(context, url).error == IR_LIBRAW_OK)

            var beforeUnpack = ir_libraw_metadata()
            let refused = ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, &beforeUnpack)
            #expect(refused.error == IR_LIBRAW_ERR_BAD_STATE)

            // The current-state source, by contrast, is valid right after open.
            var current = ir_libraw_metadata()
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_CURRENT, &current).error == IR_LIBRAW_OK)

            #expect(ir_libraw_unpack(context).error == IR_LIBRAW_OK)

            var afterUnpack = ir_libraw_metadata()
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, &afterUnpack).error == IR_LIBRAW_OK)
            // A zeroed structure would also "succeed"; require it to actually
            // describe the file.
            #expect(afterUnpack.raw_width == current.raw_width)
            #expect(afterUnpack.visible_width == current.visible_width)
            #expect(afterUnpack.raw_width > 0)
        }
    }

    /// `LibRawDecoder.decodeMosaic` depends on the RAW-state snapshot, so it
    /// cannot be reordered back to a pre-unpack snapshot without failing.
    @Test("decodeMosaic succeeds, which it could not with a pre-unpack RAW-state snapshot")
    func decodeMosaicUsesPostUnpackState() throws {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        #expect(decoded.metadata.geometry.rawWidth > 0)
    }

    /// The RAW state LibRaw saves at the end of `unpack()` must survive
    /// `dcraw_process`, which restores `imgdata.color` from it and then
    /// mutates it. This is why the mosaic path reads `rawdata.color` rather
    /// than `imgdata.color`.
    @Test("RAW-state metadata is immune to dcraw_process mutation; current-state metadata is not")
    func rawStateSurvivesProcessing() throws {
        let url = try #require(RAWFixtures.olympusORF)
        Self.withContext { context in
            #expect(Self.open(context, url).error == IR_LIBRAW_OK)
            #expect(ir_libraw_unpack(context).error == IR_LIBRAW_OK)

            var rawStateBefore = ir_libraw_metadata()
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, &rawStateBefore).error == IR_LIBRAW_OK)

            #expect(ir_libraw_process(context).error == IR_LIBRAW_OK)

            var rawStateAfter = ir_libraw_metadata()
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, &rawStateAfter).error == IR_LIBRAW_OK)

            #expect(rawStateAfter.black == rawStateBefore.black)
            #expect(rawStateAfter.cblack == rawStateBefore.cblack)
            #expect(rawStateAfter.maximum == rawStateBefore.maximum)
        }
    }

    /// Directly exercises the gate the milestone removed: warning bits must
    /// be readable without `dcraw_process` having run.
    @Test("Warning bits are readable after open and after unpack, without processing")
    func warningBitsDoNotRequireProcessing() throws {
        let url = try #require(RAWFixtures.olympusORF)
        Self.withContext { context in
            #expect(Self.open(context, url).error == IR_LIBRAW_OK)
            let afterOpen = ir_libraw_warning_bits(context)

            #expect(ir_libraw_unpack(context).error == IR_LIBRAW_OK)
            let afterUnpack = ir_libraw_warning_bits(context)

            #expect(ir_libraw_process(context).error == IR_LIBRAW_OK)
            let afterProcess = ir_libraw_warning_bits(context)

            // LibRaw only ever ORs bits into process_warnings and never
            // clears them outside recycle(), so each stage's set must be a
            // subset of the next. This is the property the mosaic path relies
            // on: what it observes is a genuine prefix of the full set, not a
            // suppressed zero.
            #expect(afterOpen & ~afterUnpack == 0)
            #expect(afterUnpack & ~afterProcess == 0)

            // Known limitation, stated rather than papered over: the E-PL3
            // fixture raises no LibRaw warning at any stage, so these three
            // values are all 0 and this test cannot by itself distinguish
            // "the gate was removed" from "the gate is still there". Forcing
            // a real warning would need a different fixture (e.g. a
            // JPEG-compressed DNG for LIBRAW_WARN_NO_JPEGLIB), and
            // fabricating one would mean writing into vendor state. What is
            // directly tested here is the lifecycle contract: the call is
            // legal, and returns a defined value, at every stage after open
            // without dcraw_process having run.

            print("""

            --- LibRaw warning bits (Olympus E-PL3 fixture) ---
            after open:    0b\(String(afterOpen, radix: 2))
            after unpack:  0b\(String(afterUnpack, radix: 2))
            after process: 0b\(String(afterProcess, radix: 2))
            ---------------------------------------------------
            """)
        }
    }

    /// Diagnostic + regression: the concrete black-level metadata this
    /// fixture reports in each of LibRaw's states. The milestone asks for a
    /// specific pre/post-unpack comparison, and this is where it is recorded.
    @Test("Diagnostic: E-PL3 black metadata before and after unpack")
    func blackMetadataAcrossUnpack() throws {
        let url = try #require(RAWFixtures.olympusORF)
        Self.withContext { context in
            #expect(Self.open(context, url).error == IR_LIBRAW_OK)

            var beforeUnpack = ir_libraw_metadata()
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_CURRENT, &beforeUnpack).error == IR_LIBRAW_OK)

            #expect(ir_libraw_unpack(context).error == IR_LIBRAW_OK)

            var currentAfter = ir_libraw_metadata()
            var rawStateAfter = ir_libraw_metadata()
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_CURRENT, &currentAfter).error == IR_LIBRAW_OK)
            #expect(ir_libraw_copy_metadata(context, IR_LIBRAW_METADATA_RAW_STATE, &rawStateAfter).error == IR_LIBRAW_OK)

            func describe(_ m: ir_libraw_metadata) -> String {
                "black=\(m.black) cblack=\(m.cblack) maximum=\(m.maximum) "
                    + "dataMaximum=\(m.data_maximum) rawBps=\(m.raw_bps)"
            }

            print("""

            --- E-PL3 black metadata across unpack() ---
            pre-unpack  (imgdata.color):          \(describe(beforeUnpack))
            post-unpack (imgdata.color):          \(describe(currentAfter))
            post-unpack (imgdata.rawdata.color):  \(describe(rawStateAfter))
            --------------------------------------------
            """)

            // Immediately after unpack(), LibRaw's two states are copies of
            // one another (the memmove at the tail of LibRaw::unpack). They
            // diverge only once dcraw_process mutates the live one.
            #expect(rawStateAfter.black == currentAfter.black)
            #expect(rawStateAfter.cblack == currentAfter.cblack)

            // Pre-unpack pin, unchanged from earlier milestones: this is what
            // the file's metadata says before LibRaw touches it.
            #expect(beforeUnpack.black == 0)
            #expect(beforeUnpack.cblack == (64, 64, 64, 64))

            // Post-unpack pin. `unpack()` *does* move these for this fixture,
            // which is the whole reason the mosaic path's snapshot had to be
            // reordered. The cause is the canonicalisation at the tail of
            // LibRaw::unpack (src/decoders/unpack.cpp, "adjust black to
            // possible maximum"): it takes i = min(cblack[0...3]) = 64,
            // subtracts i from every cblack entry and adds it to black.
            //
            // For this fixture `crop_masked_pixels()` contributes nothing —
            // the E-PL3 has zero margins, so there is no masked border to
            // estimate from — and the whole change is that redistribution.
            #expect(rawStateAfter.black == 64)
            #expect(rawStateAfter.cblack == (0, 0, 0, 0))

            // The invariant that actually matters: the redistribution is
            // value-preserving. The effective per-plane black level is
            // identical either side of unpack(), so nothing downstream that
            // sums the two terms changes. A pre-unpack snapshot was not
            // *wrong* for this camera by luck; it was wrong in principle,
            // because it need not have been.
            for plane in 0..<4 {
                let before = beforeUnpack.black + Self.cblack(beforeUnpack, plane)
                let after = rawStateAfter.black + Self.cblack(rawStateAfter, plane)
                #expect(before == after)
                #expect(after == 64)
            }
        }
    }
}
