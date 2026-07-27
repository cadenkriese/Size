import Foundation
import System

struct ScanResult: Equatable, Sendable {
    let totalBlocks: UInt64
    let unreadableEntryCount: Int
}

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct CloneIdentity: Hashable, Sendable {
    let device: UInt64
    let cloneID: UInt64
}

enum ScanError: Error, CustomStringConvertible, Sendable {
    case root(path: FilePath, code: Int32)
    case malformedDirectory(path: FilePath, reason: String)
    case arithmeticOverflow

    var description: String {
        switch self {
        case let .root(path, code):
            "\(path.lossyString): \(systemErrorDescription(code))"
        case let .malformedDirectory(path, reason):
            "\(path.lossyString): \(reason)"
        case .arithmeticOverflow:
            "disk usage exceeds the supported range"
        }
    }
}

struct DiskUsageScanner: Sendable {
    static let maximumWorkerCount = 224
    static let bufferSize = 128 * 1024

    var verbose = false
    var ignoreClones = false
    var diagnosticHandler: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data(message.utf8))
    }

    func scan(_ root: FilePath) throws -> ScanResult {
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, Self.maximumWorkerCount)
        return try ScanContext(
            workerCount: max(1, workers),
            verbose: verbose,
            ignoreClones: ignoreClones,
            diagnosticHandler: diagnosticHandler
        ).scan(root)
    }

    static func blocksForAllocatedBytes(_ bytes: Int64) throws -> UInt64 {
        guard bytes >= 0 else { throw ScanError.arithmeticOverflow }
        let (adjusted, overflow) = UInt64(bytes).addingReportingOverflow(511)
        guard !overflow else { throw ScanError.arithmeticOverflow }
        return adjusted / 512
    }

    static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ScanError.arithmeticOverflow }
        return sum
    }

    static func formatSize(blocks: UInt64) -> String {
        guard blocks >= 2 else { return "\(blocks * 512)B" }

        let units = ["K", "M", "G", "T", "P", "E"]
        var value = Double(blocks) / 2
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let format = value < 10 ? "%.1f%@" : "%.0f%@"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value, units[unitIndex])
    }
}
