import Synchronization
import System

struct DirectoryAccounting {
    var directBlocks: UInt64
    var regularFiles: [FileAllocation] = []
}

struct FileAllocation: Sendable {
    let identity: FileIdentity
    let blocks: UInt64
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

    private func shardIndex(for identity: FileIdentity) -> Int {
        let mixed = identity.device &* 0x9E37_79B9_7F4A_7C15 ^ identity.inode
        return Int(mixed & UInt64(Self.shardCount - 1))
    }
}

final class ScanAccumulator: Sendable {
    private struct State {
        var totalBlocks: UInt64 = 0
        var unreadableCount = 0
        var fatalError: ScanError?
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
            ScanResult(totalBlocks: $0.totalBlocks, unreadableEntryCount: $0.unreadableCount)
        }
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
        buffers = Mutex((0..<count).map { _ in [UInt8](repeating: 0, count: size) })
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
