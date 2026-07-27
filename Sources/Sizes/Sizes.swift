import ArgumentParser
import Foundation
import System

@main
struct SizesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sizes",
        abstract: "Report the allocated disk usage of a directory.",
    )

    @Flag(name: [.short, .long], help: "Report each unreadable path.")
    var verbose = false

    @Flag(help: "Count each group of exact APFS clones only once.")
    var ignoreClones = false

    @Argument(help: "The directory to scan.", completion: .directory)
    var directory: String

    mutating func run() throws {
        let scanner = DiskUsageScanner(verbose: verbose, ignoreClones: ignoreClones)
        do {
            let result = try scanner.scan(FilePath(directory))
            print("\(DiskUsageScanner.formatSize(blocks: result.totalBlocks))\t\(directory)")
            if result.unreadableEntryCount > 0 {
                let noun = result.unreadableEntryCount == 1 ? "file" : "files"
                writeStandardError("\(result.unreadableEntryCount) \(noun) could not be read\n")
            }
        } catch {
            writeStandardError("sizes: \(error)\n")
            throw ExitCode.failure
        }
    }
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
