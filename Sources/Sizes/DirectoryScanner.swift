import Darwin
import Foundation
import System

final class ScanContext: @unchecked Sendable {
    private let queue: OperationQueue
    private let group = DispatchGroup()
    private let accumulator: ScanAccumulator
    private let identities = ShardedIdentitySet()
    private let buffers: ReusableBufferPool

    init(
        workerCount: Int,
        verbose: Bool,
        diagnosticHandler: @escaping @Sendable (String) -> Void
    ) {
        queue = OperationQueue()
        queue.name = "sizes.directory-scanner"
        queue.maxConcurrentOperationCount = workerCount
        queue.qualityOfService = .userInitiated
        accumulator = ScanAccumulator(verbose: verbose, diagnosticHandler: diagnosticHandler)
        buffers = ReusableBufferPool(count: workerCount, size: DiskUsageScanner.bufferSize)
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

        scheduleDirectory(path: root, descriptor: descriptor, isRoot: true)
        group.wait()
        if let fatalError = accumulator.fatalError {
            throw fatalError
        }
        return accumulator.result
    }

    private func scheduleDirectory(
        path: FilePath,
        descriptor: Int32? = nil,
        isRoot: Bool = false
    ) {
        group.enter()
        queue.addOperation { [self] in
            defer { group.leave() }
            guard !accumulator.hasFatalError else {
                if let descriptor { close(descriptor) }
                return
            }
            scanDirectory(path: path, descriptor: descriptor, isRoot: isRoot)
        }
    }

    private func scanDirectory(path: FilePath, descriptor: Int32?, isRoot: Bool) {
        guard let descriptor = openDirectory(
            path: path,
            preopenedDescriptor: descriptor,
            isRoot: isRoot
        ) else { return }
        defer { close(descriptor) }

        guard let blocks = directoryBlocks(descriptor: descriptor, path: path, isRoot: isRoot) else {
            return
        }

        var accounting = DirectoryAccounting(directBlocks: blocks)
        buffers.withBuffer { buffer in
            readDirectory(
                descriptor: descriptor,
                path: path,
                isRoot: isRoot,
                buffer: &buffer,
                accounting: &accounting
            )
        }
        commit(accounting)
    }

    private func openDirectory(
        path: FilePath,
        preopenedDescriptor: Int32?,
        isRoot: Bool
    ) -> Int32? {
        if let preopenedDescriptor { return preopenedDescriptor }
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

private extension ScanContext {
    func readDirectory(
        descriptor: Int32,
        path: FilePath,
        isRoot: Bool,
        buffer: inout [UInt8],
        accounting: inout DirectoryAccounting
    ) {
        var attributeList = BulkRecordParser.attributeList
        while !accumulator.hasFatalError {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                getattrlistbulk(
                    descriptor,
                    &attributeList,
                    rawBuffer.baseAddress,
                    rawBuffer.count,
                    0
                )
            }
            if count == 0 { return }
            guard count > 0 else {
                recordFailure(path: path, code: errno, isRoot: isRoot)
                return
            }

            do {
                let entries = try BulkRecordParser.parse(
                    buffer: buffer.span,
                    recordCount: Int(count)
                )
                for entry in entries {
                    guard process(
                        entry: entry,
                        descriptor: descriptor,
                        parentPath: path,
                        isRoot: isRoot,
                        accounting: &accounting
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
        isRoot: Bool,
        accounting: inout DirectoryAccounting
    ) -> Bool {
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
            var childPath = parentPath
            childPath.append(component)
            scheduleDirectory(path: childPath)
            return true
        }
        if entry.objectType == BulkRecordParser.regularType,
           let allocation = bulkAllocation(for: entry) {
            accounting.regularFiles.append(allocation)
            return true
        }
        guard !accumulator.hasFatalError else { return false }

        accountUsingStat(
            descriptor: descriptor,
            component: component,
            parentPath: parentPath,
            accounting: &accounting
        )
        return !accumulator.hasFatalError
    }
}

private extension ScanContext {
    func bulkAllocation(for entry: BulkRecordParser.Entry) -> FileAllocation? {
        guard let device = entry.device,
              let inode = entry.fileID,
              let allocationSize = entry.allocationSize else { return nil }
        do {
            return FileAllocation(
                identity: FileIdentity(device: device, inode: inode),
                blocks: try DiskUsageScanner.blocksForAllocatedBytes(allocationSize)
            )
        } catch {
            accumulator.recordFatal(.arithmeticOverflow)
            return nil
        }
    }

    func accountUsingStat(
        descriptor: Int32,
        component: FilePath.Component,
        parentPath: FilePath,
        accounting: inout DirectoryAccounting
    ) {
        var metadata = stat()
        let status = component.withPlatformString {
            fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            let code = errno
            var childPath = parentPath
            childPath.append(component)
            recordFailure(path: childPath, code: code, isRoot: false)
            return
        }
        guard metadata.st_blocks >= 0 else {
            accumulator.recordFatal(.arithmeticOverflow)
            return
        }

        let blocks = UInt64(metadata.st_blocks)
        if fileType(metadata.st_mode) == S_IFREG {
            accounting.regularFiles.append(
                FileAllocation(
                    identity: FileIdentity(
                        device: UInt64(UInt32(bitPattern: metadata.st_dev)),
                        inode: UInt64(metadata.st_ino)
                    ),
                    blocks: blocks
                )
            )
        } else {
            do {
                accounting.directBlocks = try DiskUsageScanner.checkedAdd(accounting.directBlocks, blocks)
            } catch {
                accumulator.recordFatal(.arithmeticOverflow)
            }
        }
    }

    func commit(_ accounting: DirectoryAccounting) {
        guard !accumulator.hasFatalError else { return }
        do {
            let fileBlocks = try identities.insertAndSum(accounting.regularFiles)
            accumulator.add(
                blocks: try DiskUsageScanner.checkedAdd(accounting.directBlocks, fileBlocks)
            )
        } catch {
            accumulator.recordFatal(.arithmeticOverflow)
        }
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
