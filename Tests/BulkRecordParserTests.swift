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

    @Test func parsesOptionalCloneMetadata() throws {
        let cloneID: UInt64 = 0x1234_5678_9ABC_DEF0
        let extendedFlags = UInt64(EF_SHARES_ALL_BLOCKS) | UInt64(EF_IS_SPARSE)
        let record = RecordFixture.record(
            name: [65, 0],
            cloneID: cloneID,
            extendedFlags: extendedFlags
        )

        let entry = try #require(
            parse(record, includeCloneMetadata: true).first
        )
        #expect(entry.cloneID == cloneID)
        #expect(entry.extendedFlags == extendedFlags)

        let missing = try #require(
            parse(
                RecordFixture.record(name: [66, 0]),
                includeCloneMetadata: true
            ).first
        )
        #expect(missing.cloneID == nil)
        #expect(missing.extendedFlags == nil)
    }

    @Test func rejectsUnrequestedAndTruncatedCloneMetadata() {
        let cloneRecord = RecordFixture.record(
            name: [65, 0],
            cloneID: 42,
            extendedFlags: UInt64(EF_SHARES_ALL_BLOCKS)
        )
        expectParseError(
            "bulk record returned unrequested attributes",
            parsing: cloneRecord
        )
        expectParseError(
            "truncated bulk attribute record",
            parsing: RecordFixture.truncatedCloneRecord(),
            includeCloneMetadata: true
        )
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
        recordCount: Int = 1,
        includeCloneMetadata: Bool = false
    ) throws -> [BulkRecordParser.Entry] {
        try BulkRecordParser.parse(
            buffer: bytes.span,
            recordCount: recordCount,
            includeCloneMetadata: includeCloneMetadata
        )
    }

    private func expectParseError(
        _ description: String,
        parsing bytes: [UInt8],
        recordCount: Int = 1,
        includeCloneMetadata: Bool = false
    ) {
        do {
            _ = try parse(
                bytes,
                recordCount: recordCount,
                includeCloneMetadata: includeCloneMetadata
            )
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

    static func record(
        name: [UInt8],
        device: UInt32 = 17,
        cloneID: UInt64? = nil,
        extendedFlags: UInt64? = nil
    ) -> [UInt8] {
        let commonAttributes = UInt32(ATTR_CMN_RETURNED_ATTRS)
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_DEVID)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FILEID)
        var cloneAttributes: UInt32 = 0
        if cloneID != nil { cloneAttributes |= UInt32(ATTR_CMNEXT_CLONEID) }
        if extendedFlags != nil { cloneAttributes |= UInt32(ATTR_CMNEXT_EXT_FLAGS) }

        var bytes: [UInt8] = []
        append(UInt32(0), to: &bytes)
        append(commonAttributes, to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(ATTR_FILE_ALLOCSIZE), to: &bytes)
        append(cloneAttributes, to: &bytes)

        let referenceOffset = bytes.count
        append(Int32(0), to: &bytes)
        append(UInt32(name.count), to: &bytes)
        append(device, to: &bytes)
        append(BulkRecordParser.regularType, to: &bytes)
        append(UInt64(29), to: &bytes)
        append(Int64(4_096), to: &bytes)
        if let cloneID { append(cloneID, to: &bytes) }
        if let extendedFlags { append(extendedFlags, to: &bytes) }

        let dataOffset = Int32(bytes.count - referenceOffset)
        replace(dataOffset, at: referenceOffset, in: &bytes)
        bytes.append(contentsOf: name)
        replace(UInt32(bytes.count), at: 0, in: &bytes)
        return bytes
    }

    static func returnedAttributesRecord(
        commonattr: UInt32,
        forkattr: UInt32 = 0
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        append(UInt32(0), to: &bytes)
        append(commonattr, to: &bytes)
        for _ in 0..<3 {
            append(UInt32(0), to: &bytes)
        }
        append(forkattr, to: &bytes)
        replace(UInt32(bytes.count), at: 0, in: &bytes)
        return bytes
    }

    static func truncatedCloneRecord() -> [UInt8] {
        var bytes = returnedAttributesRecord(
            commonattr: UInt32(ATTR_CMN_RETURNED_ATTRS),
            forkattr: UInt32(ATTR_CMNEXT_CLONEID)
        )
        append(UInt32(42), to: &bytes)
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
