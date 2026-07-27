import Testing
@testable import Sizes

struct ScannerStateTests {
    @Test func deduplicatesHardLinksBeforeDeviceScopedClones() throws {
        let files = ShardedIdentitySet()
        let clones = ShardedCloneIdentitySet()
        let allocations = [
            cloneAllocation(device: 1, inode: 10, cloneID: 99),
            cloneAllocation(device: 1, inode: 10, cloneID: 99),
            cloneAllocation(device: 1, inode: 11, cloneID: 99),
            cloneAllocation(device: 2, inode: 12, cloneID: 99),
            CloneFileAllocation(
                allocation: FileAllocation(
                    identity: FileIdentity(device: 1, inode: 13),
                    blocks: 8
                ),
                cloneIdentity: nil
            )
        ]

        let uniqueFiles = files.insertUnique(allocations)
        #expect(uniqueFiles.count == 4)
        #expect(try clones.insertAndSum(uniqueFiles) == 24)
    }

    private func cloneAllocation(
        device: UInt64,
        inode: UInt64,
        cloneID: UInt64
    ) -> CloneFileAllocation {
        CloneFileAllocation(
            allocation: FileAllocation(
                identity: FileIdentity(device: device, inode: inode),
                blocks: 8
            ),
            cloneIdentity: CloneIdentity(device: device, cloneID: cloneID)
        )
    }
}
