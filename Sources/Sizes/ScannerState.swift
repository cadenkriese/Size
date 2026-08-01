import Synchronization
import System

struct DirectoryAccounting: Sendable {
    var directBlocks: UInt64
    var regularFiles: [FileAllocation] = []
    var cloneFiles: [CloneFileAllocation]?

    init(directBlocks: UInt64, collectCloneMetadata: Bool) {
        self.directBlocks = directBlocks
        cloneFiles = collectCloneMetadata ? [] : nil
    }

    mutating func append(_ allocation: FileAllocation, cloneIdentity: CloneIdentity?) {
        if cloneFiles != nil {
            cloneFiles?.append(CloneFileAllocation(allocation: allocation, cloneIdentity: cloneIdentity))
        } else {
            regularFiles.append(allocation)
        }
    }
}

struct ScannedDirectory: Sendable {
    let path: FilePath
    let parentPath: FilePath?
    let depth: Int
    let accounting: DirectoryAccounting
}

struct FileAllocation: Sendable {
    let identity: FileIdentity
    let blocks: UInt64
}

struct CloneFileAllocation: Sendable {
    let allocation: FileAllocation
    let cloneIdentity: CloneIdentity?
}

final class ShardedIdentitySet: Sendable {
    private static let shardCount = 128
    private let shards: [128 of Mutex<Set<FileIdentity>>] = .init { _ in Mutex(Set()) }

    func insertAndSum(_ allocations: [FileAllocation]) throws -> UInt64 {
        guard !allocations.isEmpty else { return 0 }
        var grouped: [128 of [FileAllocation]] = .init { _ in [] }
        for allocation in allocations {
            grouped[shardIndex(for: allocation.identity)].append(allocation)
        }

        var total: UInt64 = 0
        for index in grouped.indices where !grouped[index].isEmpty {
            let subtotal = try shards[index].withLock { identities in
                try grouped[index].reduce(into: UInt64(0)) { sum, allocation in
                    guard identities.insert(allocation.identity).inserted else { return }
                    sum = try DiskUsageScanner.checkedAdd(sum, allocation.blocks)
                }
            }
            total = try DiskUsageScanner.checkedAdd(total, subtotal)
        }
        return total
    }

    func insertUnique(_ allocations: [CloneFileAllocation]) -> [CloneFileAllocation] {
        guard !allocations.isEmpty else { return [] }
        var grouped: [128 of [CloneFileAllocation]] = .init { _ in [] }
        for allocation in allocations {
            grouped[shardIndex(for: allocation.allocation.identity)].append(allocation)
        }

        var unique: [CloneFileAllocation] = []
        unique.reserveCapacity(allocations.count)
        for index in grouped.indices where !grouped[index].isEmpty {
            shards[index].withLock { identities in
                for allocation in grouped[index]
                where identities.insert(allocation.allocation.identity).inserted {
                    unique.append(allocation)
                }
            }
        }
        return unique
    }

    private func shardIndex(for identity: FileIdentity) -> Int {
        let mixed = identity.device &* 0x9E37_79B9_7F4A_7C15 ^ identity.inode
        return Int(mixed & UInt64(Self.shardCount - 1))
    }
}

final class ShardedCloneIdentitySet: Sendable {
    private static let shardCount = 128
    private let shards: [128 of Mutex<Set<CloneIdentity>>] = .init { _ in Mutex(Set()) }

    func insertAndSum(_ allocations: [CloneFileAllocation]) throws -> UInt64 {
        guard !allocations.isEmpty else { return 0 }
        var grouped: [128 of [CloneFileAllocation]] = .init { _ in [] }
        var total: UInt64 = 0
        for allocation in allocations {
            if let identity = allocation.cloneIdentity {
                grouped[shardIndex(for: identity)].append(allocation)
            } else {
                total = try DiskUsageScanner.checkedAdd(total, allocation.allocation.blocks)
            }
        }

        for index in grouped.indices where !grouped[index].isEmpty {
            let subtotal = try shards[index].withLock { identities in
                try grouped[index].reduce(into: UInt64(0)) { sum, allocation in
                    guard let identity = allocation.cloneIdentity,
                          identities.insert(identity).inserted else { return }
                    sum = try DiskUsageScanner.checkedAdd(sum, allocation.allocation.blocks)
                }
            }
            total = try DiskUsageScanner.checkedAdd(total, subtotal)
        }
        return total
    }

    private func shardIndex(for identity: CloneIdentity) -> Int {
        let mixed = identity.device &* 0x9E37_79B9_7F4A_7C15 ^ identity.cloneID
        return Int(mixed & UInt64(Self.shardCount - 1))
    }
}

final class ScanAccumulator: Sendable {
    private struct State {
        var totalBlocks: UInt64 = 0
        var unreadableCount = 0
        var fatalError: ScanError?
        var directories: [ScannedDirectory] = []
    }

    private let state = Mutex(State())
    private let diagnosticLock = Mutex(())
    private let verbose: Bool
    private let diagnosticHandler: @Sendable (String) -> Void

    init(verbose: Bool, diagnosticHandler: @escaping @Sendable (String) -> Void) {
        self.verbose = verbose
        self.diagnosticHandler = diagnosticHandler
    }

    var hasFatalError: Bool {
        state.withLock { $0.fatalError != nil }
    }

    var fatalError: ScanError? {
        state.withLock { $0.fatalError }
    }

    var result: ScanResult {
        state.withLock {
            ScanResult(
                totalBlocks: $0.totalBlocks,
                unreadableEntryCount: $0.unreadableCount,
                directoryUsages: [],
            )
        }
    }

    var unreadableEntryCount: Int {
        state.withLock { $0.unreadableCount }
    }

    var directories: [ScannedDirectory] {
        state.withLock { $0.directories }
    }

    func add(blocks: UInt64) {
        state.withLock { state in
            guard state.fatalError == nil else { return }
            let (total, overflow) = state.totalBlocks.addingReportingOverflow(blocks)
            if overflow {
                state.fatalError = .arithmeticOverflow
            } else {
                state.totalBlocks = total
            }
        }
    }

    func recordDirectory(_ directory: ScannedDirectory) {
        state.withLock { state in
            guard state.fatalError == nil else { return }
            state.directories.append(directory)
        }
    }

    func recordFatal(_ error: ScanError) {
        state.withLock { state in
            if state.fatalError == nil {
                state.fatalError = error
            }
        }
    }

    func recordUnreadable(path: FilePath, message: String) {
        state.withLock { $0.unreadableCount += 1 }
        guard verbose else { return }
        diagnosticLock.withLock { _ in
            diagnosticHandler("sizes: \(path.lossyString): \(message)\n")
        }
    }
}

final class ReusableBufferPool: Sendable {
    private let buffers: Mutex<[[UInt8]]>

    init(count: Int, size: Int) {
        buffers = Mutex((0 ..< count).map { _ in [UInt8](repeating: 0, count: size) })
    }

    func withBuffer(_ body: (inout [UInt8]) -> Void) {
        var buffer = buffers.withLock { buffers in
            precondition(!buffers.isEmpty, "worker count exceeded buffer count")
            return buffers.removeLast()
        }
        defer { buffers.withLock { $0.append(buffer) } }
        body(&buffer)
    }
}
