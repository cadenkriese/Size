import Darwin
import Foundation
import System

final class ScanContext: @unchecked Sendable {
    private let queue: OperationQueue
    private let group = DispatchGroup()
    let accumulator: ScanAccumulator
    let identities = ShardedIdentitySet()
    let cloneIdentities: ShardedCloneIdentitySet?
    private let buffers: ReusableBufferPool
    let ignoreClones: Bool
    let maximumReportDepth: Int?

    init(
        workerCount: Int,
        verbose: Bool,
        ignoreClones: Bool,
        maximumReportDepth: Int?,
        diagnosticHandler: @escaping @Sendable (String) -> Void,
    ) {
        queue = OperationQueue()
        queue.name = "size.directory-scanner"
        queue.maxConcurrentOperationCount = workerCount
        queue.qualityOfService = .userInitiated
        accumulator = ScanAccumulator(verbose: verbose, diagnosticHandler: diagnosticHandler)
        cloneIdentities = ignoreClones ? ShardedCloneIdentitySet() : nil
        buffers = ReusableBufferPool(count: workerCount, size: DiskUsageScanner.bufferSize)
        self.ignoreClones = ignoreClones
        self.maximumReportDepth = maximumReportDepth
    }
}

extension ScanContext {
    func scan(_ root: FilePath) throws -> ScanResult {
        let descriptor = root.withPlatformString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ScanError.root(path: root, code: errno)
        }

        scheduleDirectory(
            path: root,
            parentPath: nil,
            depth: 0,
            descriptor: descriptor,
            isRoot: true,
        )
        group.wait()
        if let fatalError = accumulator.fatalError {
            throw fatalError
        }
        if let maximumReportDepth {
            return try depthResult(root: root, maximumReportDepth: maximumReportDepth)
        }
        return accumulator.result
    }

    private func scheduleDirectory(
        path: FilePath,
        parentPath: FilePath?,
        depth: Int,
        descriptor: Int32? = nil,
        isRoot: Bool = false,
    ) {
        group.enter()
        queue.addOperation { [self] in
            defer { group.leave() }
            guard !accumulator.hasFatalError else {
                if let descriptor {
                    close(descriptor)
                }
                return
            }
            scanDirectory(
                path: path,
                parentPath: parentPath,
                depth: depth,
                descriptor: descriptor,
                isRoot: isRoot,
            )
        }
    }

    private func scanDirectory(
        path: FilePath,
        parentPath: FilePath?,
        depth: Int,
        descriptor: Int32?,
        isRoot: Bool,
    ) {
        guard let descriptor = openDirectory(
            path: path,
            preopenedDescriptor: descriptor,
            isRoot: isRoot,
        ) else { return }
        defer { close(descriptor) }

        guard let blocks = directoryBlocks(descriptor: descriptor, path: path, isRoot: isRoot) else {
            return
        }

        var accounting = DirectoryAccounting(
            directBlocks: blocks,
            collectCloneMetadata: ignoreClones,
        )
        buffers.withBuffer { buffer in
            readDirectory(
                descriptor: descriptor,
                path: path,
                depth: depth,
                buffer: &buffer,
                accounting: &accounting,
            )
        }
        commit(
            accounting,
            path: path,
            parentPath: parentPath,
            depth: depth,
        )
    }

    private func openDirectory(
        path: FilePath,
        preopenedDescriptor: Int32?,
        isRoot: Bool,
    ) -> Int32? {
        if let preopenedDescriptor {
            return preopenedDescriptor
        }
        let descriptor = path.withPlatformString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            recordFailure(path: path, code: errno, isRoot: isRoot)
            return nil
        }
        return descriptor
    }

    private func directoryBlocks(descriptor: Int32, path: FilePath, isRoot: Bool) -> UInt64? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            recordFailure(path: path, code: errno, isRoot: isRoot)
            return nil
        }
        guard metadata.st_blocks >= 0 else {
            accumulator.recordFatal(.arithmeticOverflow)
            return nil
        }
        return UInt64(metadata.st_blocks)
    }
}

extension ScanContext {
    func readDirectory(
        descriptor: Int32,
        path: FilePath,
        depth: Int,
        buffer: inout [UInt8],
        accounting: inout DirectoryAccounting,
    ) {
        let isRoot = depth == 0
        let includeLinkCount = maximumReportDepth != nil
        var attributeList = BulkRecordParser.attributeList(
            includeCloneMetadata: ignoreClones,
            includeLinkCount: includeLinkCount,
        )
        let options = ignoreClones ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0
        while !accumulator.hasFatalError {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                getattrlistbulk(
                    descriptor,
                    &attributeList,
                    rawBuffer.baseAddress,
                    rawBuffer.count,
                    options,
                )
            }
            if count == 0 {
                return
            }
            guard count > 0 else {
                recordFailure(path: path, code: errno, isRoot: isRoot)
                return
            }

            do {
                let entries = try BulkRecordParser.parse(
                    buffer: buffer.span,
                    recordCount: Int(count),
                    includeCloneMetadata: ignoreClones,
                    includeLinkCount: includeLinkCount,
                )
                for entry in entries {
                    guard process(
                        entry: entry,
                        descriptor: descriptor,
                        parentPath: path,
                        parentDepth: depth,
                        accounting: &accounting,
                    ) else { return }
                }
            } catch {
                let reason = (error as? BulkRecordParser.ParseError)?.description
                    ?? "malformed directory attributes"
                recordMalformed(path: path, reason: reason, isRoot: isRoot)
                return
            }
        }
    }

    func process(
        entry: BulkRecordParser.Entry,
        descriptor: Int32,
        parentPath: FilePath,
        parentDepth: Int,
        accounting: inout DirectoryAccounting,
    ) -> Bool {
        let isRoot = parentDepth == 0
        guard let component = entry.component else {
            recordMalformed(path: parentPath, reason: "directory entry has no name", isRoot: isRoot)
            return !isRoot
        }
        guard component.kind == .regular else { return true }

        if let code = entry.errorCode, code != 0 {
            var childPath = parentPath
            childPath.append(component)
            recordFailure(path: childPath, code: code, isRoot: false)
            return true
        }
        if entry.objectType == BulkRecordParser.directoryType {
            let (childDepth, overflow) = parentDepth.addingReportingOverflow(1)
            guard !overflow else {
                accumulator.recordFatal(.arithmeticOverflow)
                return false
            }
            var childPath = parentPath
            childPath.append(component)
            scheduleDirectory(
                path: childPath,
                parentPath: parentPath,
                depth: childDepth,
            )
            return true
        }
        if entry.objectType == BulkRecordParser.regularType,
           let allocation = bulkAllocation(for: entry) {
            account(
                allocation,
                cloneIdentity: exactCloneIdentity(for: entry, device: allocation.identity.device),
                linkCount: entry.linkCount.map(UInt64.init),
                accounting: &accounting,
            )
            return !accumulator.hasFatalError
        }
        guard !accumulator.hasFatalError else { return false }

        accountUsingStat(
            descriptor: descriptor,
            component: component,
            parentPath: parentPath,
            accounting: &accounting,
        )
        return !accumulator.hasFatalError
    }
}

extension ScanContext {
    func bulkAllocation(for entry: BulkRecordParser.Entry) -> FileAllocation? {
        guard let device = entry.device,
              let inode = entry.fileID,
              let allocationSize = entry.allocationSize else { return nil }
        do {
            return try FileAllocation(
                identity: FileIdentity(device: device, inode: inode),
                blocks: DiskUsageScanner.blocksForAllocatedBytes(allocationSize),
            )
        } catch {
            accumulator.recordFatal(.arithmeticOverflow)
            return nil
        }
    }

    func exactCloneIdentity(
        for entry: BulkRecordParser.Entry,
        device: UInt64,
    ) -> CloneIdentity? {
        guard ignoreClones,
              let cloneID = entry.cloneID,
              cloneID != 0,
              let extendedFlags = entry.extendedFlags,
              extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 else { return nil }
        return CloneIdentity(device: device, cloneID: cloneID)
    }

    func recordFailure(path: FilePath, code: Int32, isRoot: Bool) {
        if isRoot {
            accumulator.recordFatal(.root(path: path, code: code))
        } else {
            accumulator.recordUnreadable(path: path, message: systemErrorDescription(code))
        }
    }

    func recordMalformed(path: FilePath, reason: String, isRoot: Bool) {
        if isRoot {
            accumulator.recordFatal(.malformedDirectory(path: path, reason: reason))
        } else {
            accumulator.recordUnreadable(path: path, message: reason)
        }
    }
}
