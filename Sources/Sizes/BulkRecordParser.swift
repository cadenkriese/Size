import Darwin
import System

struct BulkRecordParser {
    static let regularType: UInt32 = 1
    static let directoryType: UInt32 = 2

    private static let errorAttribute: UInt32 = 0x2000_0000
    private static let commonAttributes = UInt32(ATTR_CMN_RETURNED_ATTRS)
        | UInt32(ATTR_CMN_NAME)
        | UInt32(ATTR_CMN_DEVID)
        | UInt32(ATTR_CMN_OBJTYPE)
        | UInt32(ATTR_CMN_FILEID)
        | errorAttribute
    private static let fileAttributes = UInt32(ATTR_FILE_ALLOCSIZE)

    static var attributeList: attrlist {
        attrlist(
            bitmapcount: UInt16(ATTR_BIT_MAP_COUNT),
            reserved: 0,
            commonattr: commonAttributes,
            volattr: 0,
            dirattr: 0,
            fileattr: fileAttributes,
            forkattr: 0
        )
    }

    struct Entry: Sendable {
        let component: FilePath.Component?
        let device: UInt64?
        let objectType: UInt32?
        let fileID: UInt64?
        let errorCode: Int32?
        let allocationSize: Int64?
    }

    struct ParseError: Error, CustomStringConvertible, Equatable, Sendable {
        let description: String
    }

    static func parse(buffer: UnsafeRawBufferPointer, recordCount: Int) throws -> [Entry] {
        guard recordCount >= 0 else {
            throw ParseError(description: "negative bulk record count")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(recordCount)
        var offset = 0
        for _ in 0..<recordCount {
            var reader = try RecordReader(buffer: buffer, start: offset)
            entries.append(try parseRecord(from: &reader))
            offset = reader.end
        }
        return entries
    }

    private static func parseRecord(from reader: inout RecordReader) throws -> Entry {
        let returned: attribute_set_t = try reader.read()
        try validate(returned)

        let component = try reader.readComponent(
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_NAME) != 0
        )
        let rawDevice: UInt32? = try reader.read(
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0
        )
        let objectType: UInt32? = try reader.read(
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0
        )
        let fileID: UInt64? = try reader.read(
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0
        )
        let errorCode: Int32? = try reader.read(
            ifPresent: returned.commonattr & errorAttribute != 0
        )
        let allocationSize: Int64? = try reader.read(
            ifPresent: returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0
        )

        return Entry(
            component: component,
            device: rawDevice.map(UInt64.init),
            objectType: objectType,
            fileID: fileID,
            errorCode: errorCode,
            allocationSize: allocationSize
        )
    }

    private static func validate(_ returned: attribute_set_t) throws {
        guard returned.commonattr & UInt32(ATTR_CMN_RETURNED_ATTRS) != 0 else {
            throw ParseError(description: "bulk record omitted its returned-attribute mask")
        }
        guard returned.commonattr & ~commonAttributes == 0,
              returned.volattr == 0,
              returned.dirattr == 0,
              returned.fileattr & ~fileAttributes == 0,
              returned.forkattr == 0 else {
            throw ParseError(description: "bulk record returned unrequested attributes")
        }
    }
}

private struct RecordReader {
    let buffer: UnsafeRawBufferPointer
    let start: Int
    let end: Int
    private(set) var offset: Int

    init(buffer: UnsafeRawBufferPointer, start: Int) throws {
        let headerSize = MemoryLayout<UInt32>.size
        guard start >= 0, start <= buffer.count, headerSize <= buffer.count - start else {
            throw BulkRecordParser.ParseError(description: "truncated bulk attribute record")
        }

        let length = buffer.loadUnaligned(fromByteOffset: start, as: UInt32.self)
        guard let recordLength = Int(exactly: length),
              recordLength >= headerSize,
              recordLength <= buffer.count - start else {
            throw BulkRecordParser.ParseError(description: "invalid bulk record length")
        }

        self.buffer = buffer
        self.start = start
        end = start + recordLength
        offset = start + headerSize
    }

    mutating func read<T>() throws -> T {
        let size = MemoryLayout<T>.size
        guard offset <= end, size <= end - offset else {
            throw BulkRecordParser.ParseError(description: "truncated bulk attribute record")
        }
        defer { offset += size }
        return buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
    }

    mutating func read<T>(ifPresent: Bool) throws -> T? {
        guard ifPresent else { return nil }
        let value: T = try read()
        return value
    }

    mutating func readComponent(
        ifPresent: Bool
    ) throws -> FilePath.Component? {
        guard ifPresent else { return nil }
        let referenceOffset = offset
        let reference: attrreference_t = try read()
        return try component(from: reference, relativeTo: referenceOffset)
    }

    private func component(
        from reference: attrreference_t,
        relativeTo referenceOffset: Int
    ) throws -> FilePath.Component {
        guard reference.attr_dataoffset >= 0,
              let dataOffset = Int(exactly: reference.attr_dataoffset),
              let dataLength = Int(exactly: reference.attr_length) else {
            throw BulkRecordParser.ParseError(description: "invalid name attribute reference")
        }

        let (nameStart, startOverflow) = referenceOffset.addingReportingOverflow(dataOffset)
        let (nameEnd, endOverflow) = nameStart.addingReportingOverflow(dataLength)
        guard !startOverflow, !endOverflow,
              dataLength > 0,
              nameStart >= start,
              nameEnd <= end,
              buffer[nameEnd - 1] == 0 else {
            throw BulkRecordParser.ParseError(description: "out-of-bounds name attribute reference")
        }
        guard !buffer[nameStart..<(nameEnd - 1)].contains(0) else {
            throw BulkRecordParser.ParseError(description: "name attribute contains an embedded null byte")
        }

        var platformName = buffer[nameStart..<nameEnd].map(CChar.init(bitPattern:))
        let component = platformName.withUnsafeMutableBufferPointer { pointer -> FilePath.Component? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return FilePath.Component(platformString: baseAddress)
        }
        guard let component else {
            throw BulkRecordParser.ParseError(description: "invalid file name component")
        }
        return component
    }
}
