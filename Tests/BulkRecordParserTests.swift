import Darwin
import System
import Testing
@testable import Sizes

struct BulkRecordParserTests {
    @Test func parsesConsecutiveUnalignedRecords() throws {
        let first = RecordFixture.record(name: [65, 66, 0], device: 7)
        let second = RecordFixture.record(name: [67, 0], device: 11)
        #expect(!first.count.isMultiple(of: MemoryLayout<UInt32>.alignment))

        let entries = try parse(first + second, recordCount: 2)
        #expect(entries.count == 2)
        #expect(entries[0].component == FilePath.Component(platformString: [65, 66, 0]))
        #expect(entries[0].device == 7)
        #expect(entries[1].component == FilePath.Component(platformString: [67, 0]))
        #expect(entries[1].device == 11)
        #expect(entries[1].objectType == BulkRecordParser.regularType)
        #expect(entries[1].fileID == 29)
        #expect(entries[1].allocationSize == 4_096)
    }

    @Test func preservesInvalidUTF8FilenameBytes() throws {
        let entries = try parse(RecordFixture.record(name: [0xFF, 0]))
        let expected = FilePath.Component(
            platformString: [CChar(bitPattern: 0xFF), 0]
        )
        #expect(entries.first?.component == expected)
    }

    @Test func rejectsMalformedRecordHeaders() {
        expectParseError(
            "negative bulk record count",
            parsing: [],
            recordCount: -1
        )
        expectParseError(
            "truncated bulk attribute record",
            parsing: [0, 0, 0]
        )

        var oversized = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size)
        RecordFixture.replace(UInt32(128), at: 0, in: &oversized)
        expectParseError("invalid bulk record length", parsing: oversized)
    }

    @Test func rejectsInvalidReturnedAttributes() {
        let missingMask = RecordFixture.returnedAttributesRecord(commonattr: 0)
        expectParseError(
            "bulk record omitted its returned-attribute mask",
            parsing: missingMask
        )

        let unrequested = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_SCRIPT)
        let unrequestedRecord = RecordFixture.returnedAttributesRecord(commonattr: unrequested)
        expectParseError(
            "bulk record returned unrequested attributes",
            parsing: unrequestedRecord
        )
    }

    @Test func rejectsInvalidNameReferences() {
        var outOfBounds = RecordFixture.record(name: [65, 0])
        RecordFixture.replace(Int32.max, at: RecordFixture.referenceOffset, in: &outOfBounds)
        expectParseError(
            "out-of-bounds name attribute reference",
            parsing: outOfBounds
        )

        expectParseError(
            "out-of-bounds name attribute reference",
            parsing: RecordFixture.record(name: [65])
        )
        expectParseError(
            "name attribute contains an embedded null byte",
            parsing: RecordFixture.record(name: [65, 0, 66, 0])
        )
    }

    private func parse(
        _ bytes: [UInt8],
        recordCount: Int = 1
    ) throws -> [BulkRecordParser.Entry] {
        try BulkRecordParser.parse(buffer: bytes.span, recordCount: recordCount)
    }

    private func expectParseError(
        _ description: String,
        parsing bytes: [UInt8],
        recordCount: Int = 1
    ) {
        do {
            _ = try parse(bytes, recordCount: recordCount)
            Issue.record("Expected parsing to fail with: \(description)")
        } catch let error as BulkRecordParser.ParseError {
            #expect(error.description == description)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private enum RecordFixture {
    static let referenceOffset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size

    static func record(name: [UInt8], device: UInt32 = 17) -> [UInt8] {
        let commonAttributes = UInt32(ATTR_CMN_RETURNED_ATTRS)
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_DEVID)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FILEID)
        var bytes: [UInt8] = []
        append(UInt32(0), to: &bytes)
        append(commonAttributes, to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(ATTR_FILE_ALLOCSIZE), to: &bytes)
        append(UInt32(0), to: &bytes)

        let referenceOffset = bytes.count
        append(Int32(0), to: &bytes)
        append(UInt32(name.count), to: &bytes)
        append(device, to: &bytes)
        append(BulkRecordParser.regularType, to: &bytes)
        append(UInt64(29), to: &bytes)
        append(Int64(4_096), to: &bytes)

        let dataOffset = Int32(bytes.count - referenceOffset)
        replace(dataOffset, at: referenceOffset, in: &bytes)
        bytes.append(contentsOf: name)
        replace(UInt32(bytes.count), at: 0, in: &bytes)
        return bytes
    }

    static func returnedAttributesRecord(commonattr: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        append(UInt32(0), to: &bytes)
        append(commonattr, to: &bytes)
        for _ in 0..<4 {
            append(UInt32(0), to: &bytes)
        }
        replace(UInt32(bytes.count), at: 0, in: &bytes)
        return bytes
    }

    static func replace<T>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
        withUnsafeBytes(of: value) { valueBytes in
            bytes.replaceSubrange(
                offset..<(offset + valueBytes.count),
                with: valueBytes
            )
        }
    }

    private static func append<T>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }
}
