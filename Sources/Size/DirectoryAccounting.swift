import Darwin
import System

extension ScanContext {
    func account(
        _ allocation: FileAllocation,
        cloneIdentity: CloneIdentity?,
        linkCount: UInt64?,
        accounting: inout DirectoryAccounting,
    ) {
        if maximumReportDepth != nil, linkCount == 1, cloneIdentity == nil {
            addDirectBlocks(allocation.blocks, to: &accounting)
            return
        }
        accounting.append(allocation, cloneIdentity: cloneIdentity)
    }

    func accountUsingStat(
        descriptor: Int32,
        component: FilePath.Component,
        parentPath: FilePath,
        accounting: inout DirectoryAccounting,
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
            account(
                FileAllocation(
                    identity: FileIdentity(
                        device: UInt64(UInt32(bitPattern: metadata.st_dev)),
                        inode: UInt64(metadata.st_ino),
                    ),
                    blocks: blocks,
                ),
                cloneIdentity: nil,
                linkCount: UInt64(metadata.st_nlink),
                accounting: &accounting,
            )
        } else {
            addDirectBlocks(blocks, to: &accounting)
        }
    }

    func commit(
        _ accounting: DirectoryAccounting,
        path: FilePath,
        parentPath: FilePath?,
        depth: Int,
    ) {
        guard !accumulator.hasFatalError else { return }
        if maximumReportDepth != nil {
            accumulator.recordDirectory(
                ScannedDirectory(
                    path: path,
                    parentPath: parentPath,
                    depth: depth,
                    accounting: accounting,
                ),
            )
            return
        }

        do {
            try accumulator.add(
                blocks: DiskUsageScanner.checkedAdd(
                    accounting.directBlocks,
                    uniqueFileBlocks(in: accounting),
                ),
            )
        } catch {
            accumulator.recordFatal(.arithmeticOverflow)
        }
    }

    func depthResult(root: FilePath, maximumReportDepth: Int) throws -> ScanResult {
        var directories = accumulator.directories
        directories.sort { platformStringLessThan($0.path, $1.path) }
        var usagesByPath = try ownUsages(for: directories)
        try accumulateSubtrees(in: &usagesByPath)

        guard let rootUsage = usagesByPath[root] else {
            throw ScanError.root(path: root, code: EIO)
        }
        let reported = usagesByPath.values
            .filter { $0.depth <= maximumReportDepth }
            .sorted(by: reportOrder)
        return ScanResult(
            totalBlocks: rootUsage.totalBlocks,
            unreadableEntryCount: accumulator.unreadableEntryCount,
            directoryUsages: reported,
        )
    }

    private func addDirectBlocks(
        _ blocks: UInt64,
        to accounting: inout DirectoryAccounting,
    ) {
        do {
            accounting.directBlocks = try DiskUsageScanner.checkedAdd(accounting.directBlocks, blocks)
        } catch {
            accumulator.recordFatal(.arithmeticOverflow)
        }
    }

    private func uniqueFileBlocks(in accounting: DirectoryAccounting) throws -> UInt64 {
        if let cloneFiles = accounting.cloneFiles, let cloneIdentities {
            return try cloneIdentities.insertAndSum(
                identities.insertUnique(cloneFiles),
            )
        }
        return try identities.insertAndSum(accounting.regularFiles)
    }

    private func ownUsages(
        for directories: [ScannedDirectory]
    ) throws -> [FilePath: DirectoryUsage] {
        var usages: [FilePath: DirectoryUsage] = [:]
        usages.reserveCapacity(directories.count)
        for directory in directories {
            let ownBlocks = try DiskUsageScanner.checkedAdd(
                directory.accounting.directBlocks,
                uniqueFileBlocks(in: directory.accounting),
            )
            usages[directory.path] = DirectoryUsage(
                path: directory.path,
                parentPath: directory.parentPath,
                depth: directory.depth,
                totalBlocks: ownBlocks,
            )
        }
        return usages
    }

    private func accumulateSubtrees(
        in usagesByPath: inout [FilePath: DirectoryUsage]
    ) throws {
        let deepestFirst = usagesByPath.values.sorted { lhs, rhs in
            if lhs.depth != rhs.depth {
                return lhs.depth > rhs.depth
            }
            return platformStringLessThan(lhs.path, rhs.path)
        }
        for originalUsage in deepestFirst {
            guard let usage = usagesByPath[originalUsage.path],
                  let parentPath = usage.parentPath,
                  let parent = usagesByPath[parentPath] else { continue }
            usagesByPath[parentPath] = DirectoryUsage(
                path: parent.path,
                parentPath: parent.parentPath,
                depth: parent.depth,
                totalBlocks: try DiskUsageScanner.checkedAdd(
                    parent.totalBlocks,
                    usage.totalBlocks,
                ),
            )
        }
    }

    private func reportOrder(_ lhs: DirectoryUsage, _ rhs: DirectoryUsage) -> Bool {
        if lhs.depth != rhs.depth {
            return lhs.depth < rhs.depth
        }
        return platformStringLessThan(lhs.path, rhs.path)
    }
}
