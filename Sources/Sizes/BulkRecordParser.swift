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

    static func parse(buffer: borrowing Span<UInt8>, recordCount: Int) throws -> [Entry] {
        guard recordCount >= 0 else {
            throw ParseError(description: "negative bulk record count")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(recordCount)
        var offset = 0
        for _ in 0..<recordCount {
            var reader = try RecordReader(buffer: buffer, start: offset)
            entries.append(try parseRecord(from: &reader, buffer: buffer))
            offset = reader.end
        }
        return entries
    }

    private static func parseRecord(
        from reader: inout RecordReader,
        buffer: borrowing Span<UInt8>
    ) throws -> Entry {
        let returned = try reader.readReturnedAttributes(from: buffer)
        try validate(returned)

        let component = try reader.readComponent(
            from: buffer,
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_NAME) != 0
        )
        let rawDevice: UInt32? = try reader.read(
            from: buffer,
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0
        )
        let objectType: UInt32? = try reader.read(
            from: buffer,
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0
        )
        let fileID: UInt64? = try reader.read(
            from: buffer,
            ifPresent: returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0
        )
        let errorCode: Int32? = try reader.read(
            from: buffer,
            ifPresent: returned.commonattr & errorAttribute != 0
        )
        let allocationSize: Int64? = try reader.read(
            from: buffer,
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

    private static func validate(_ returned: ReturnedAttributes) throws {
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

private struct ReturnedAttributes {
    let commonattr: UInt32
    let volattr: UInt32
    let dirattr: UInt32
    let fileattr: UInt32
    let forkattr: UInt32
}

private struct AttributeReference {
    let dataOffset: Int32
    let length: UInt32
}

private struct RecordReader {
    let start: Int
    let end: Int
    private(set) var offset: Int

    init(buffer: borrowing Span<UInt8>, start: Int) throws {
        let headerSize = MemoryLayout<UInt32>.size
        guard start >= 0, start <= buffer.count, headerSize <= buffer.count - start else {
            throw BulkRecordParser.ParseError(description: "truncated bulk attribute record")
        }

        let length = buffer.bytes.load(fromByteOffset: start, as: UInt32.self)
        guard let recordLength = Int(exactly: length),
              recordLength >= headerSize,
              recordLength <= buffer.count - start else {
            throw BulkRecordParser.ParseError(description: "invalid bulk record length")
        }

        self.start = start
        end = start + recordLength
        offset = start + headerSize
    }

    mutating func read<T: ConvertibleFromBytes>(
        from buffer: borrowing Span<UInt8>
    ) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset <= end, size <= end - offset else {
            throw BulkRecordParser.ParseError(description: "truncated bulk attribute record")
        }
        defer { offset += size }
        return buffer.bytes.load(fromByteOffset: offset, as: T.self)
    }

    mutating func read<T: ConvertibleFromBytes>(
        from buffer: borrowing Span<UInt8>,
        ifPresent: Bool
    ) throws -> T? {
        guard ifPresent else { return nil }
        let value: T = try read(from: buffer)
        return value
    }

    mutating func readReturnedAttributes(
        from buffer: borrowing Span<UInt8>
    ) throws -> ReturnedAttributes {
        let commonattr: UInt32 = try read(from: buffer)
        let volattr: UInt32 = try read(from: buffer)
        let dirattr: UInt32 = try read(from: buffer)
        let fileattr: UInt32 = try read(from: buffer)
        let forkattr: UInt32 = try read(from: buffer)
        return ReturnedAttributes(
            commonattr: commonattr,
            volattr: volattr,
            dirattr: dirattr,
            fileattr: fileattr,
            forkattr: forkattr
        )
    }

    mutating func readComponent(
        from buffer: borrowing Span<UInt8>,
        ifPresent: Bool
    ) throws -> FilePath.Component? {
        guard ifPresent else { return nil }
        let referenceOffset = offset
        let dataOffset: Int32 = try read(from: buffer)
        let dataLength: UInt32 = try read(from: buffer)
        let reference = AttributeReference(dataOffset: dataOffset, length: dataLength)
        return try component(from: reference, relativeTo: referenceOffset, buffer: buffer)
    }

    private func component(
        from reference: AttributeReference,
        relativeTo referenceOffset: Int,
        buffer: borrowing Span<UInt8>
    ) throws -> FilePath.Component {
        guard reference.dataOffset >= 0,
              let dataOffset = Int(exactly: reference.dataOffset),
              let dataLength = Int(exactly: reference.length) else {
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

        for index in nameStart..<(nameEnd - 1) where buffer[index] == 0 {
            throw BulkRecordParser.ParseError(description: "name attribute contains an embedded null byte")
        }

        let platformName = buffer.extracting(nameStart..<nameEnd)
        let component = platformName.withUnsafeBufferPointer { bytes in
            bytes.withMemoryRebound(to: CChar.self) { characters in
                characters.baseAddress.flatMap {
                    FilePath.Component(platformString: $0)
                }
            }
        }
        guard let component else {
            throw BulkRecordParser.ParseError(description: "invalid file name component")
        }
        return component
    }
}
