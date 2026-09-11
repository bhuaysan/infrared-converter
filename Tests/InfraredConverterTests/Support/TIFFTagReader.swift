import Foundation

/// A deliberately minimal TIFF/EXIF directory reader, for asserting what a
/// fixture file **physically contains** rather than what a decoder reports.
///
/// It exists for one question that `LibRawDecoder` cannot answer: is EXIF/TIFF
/// tag 274 present in the file at all? LibRaw maps a present tag whose value is
/// `1` and an absent tag onto the same `flip == 0`, so the only way to tell
/// them apart is to read the bytes.
///
/// It reads IFD0 of a little- or big-endian TIFF-structured file and nothing
/// else: no sub-IFDs, no makernotes, no values stored outside the entry. That
/// is enough for tag 274, which is a `SHORT` of count 1 and therefore always
/// inline. ORF files are TIFF-structured with a magic of `0x4F52` rather than
/// `42`, so the magic is reported rather than checked.
enum TIFFTagReader {

    struct Entry: Equatable {
        /// Byte offset of the 12-byte directory entry within the file.
        let fileOffset: Int
        let tag: UInt16
        /// TIFF field type: `3` is `SHORT`, `4` is `LONG`.
        let type: UInt16
        let count: UInt32
        /// The first value, for the inline `SHORT`/`LONG` cases only.
        let firstValue: UInt32?
    }

    enum ReadFailure: Error {
        case unreadable
        case notTIFFStructured
        case truncated
    }

    /// Every IFD0 entry, in file order, with the header's byte order and magic.
    static func readIFD0(
        at url: URL
    ) throws -> (byteOrder: String, magic: UInt16, firstIFDOffset: Int, entries: [Entry]) {
        let data = try Data(contentsOf: url)
        guard data.count >= 8 else { throw ReadFailure.truncated }

        let littleEndian: Bool
        switch (data[0], data[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw ReadFailure.notTIFFStructured
        }

        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset + 2 <= data.count else { throw ReadFailure.truncated }
            let low = UInt16(data[offset]), high = UInt16(data[offset + 1])
            return littleEndian ? (high << 8) | low : (low << 8) | high
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw ReadFailure.truncated }
            let bytes = (0..<4).map { UInt32(data[offset + $0]) }
            return littleEndian
                ? bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
                : bytes[3] | (bytes[2] << 8) | (bytes[1] << 16) | (bytes[0] << 24)
        }

        let magic = try u16(2)
        let firstIFD = Int(try u32(4))
        let entryCount = Int(try u16(firstIFD))

        let entries: [Entry] = try (0..<entryCount).map { index in
            let offset = firstIFD + 2 + index * 12
            let tag = try u16(offset)
            let type = try u16(offset + 2)
            let count = try u32(offset + 4)
            let inline: UInt32?
            switch type {
            case 3 where count == 1: inline = UInt32(try u16(offset + 8))
            case 4 where count == 1: inline = try u32(offset + 8)
            default: inline = nil
            }
            return Entry(
                fileOffset: offset, tag: tag, type: type, count: count, firstValue: inline
            )
        }

        return (
            byteOrder: littleEndian ? "II" : "MM",
            magic: magic,
            firstIFDOffset: firstIFD,
            entries: entries
        )
    }

    /// EXIF/TIFF tag 274 in IFD0, or `nil` when the tag is physically absent.
    static func orientationEntry(at url: URL) throws -> Entry? {
        try readIFD0(at: url).entries.first { $0.tag == 274 }
    }
}
