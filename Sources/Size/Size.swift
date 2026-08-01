import ArgumentParser
import Foundation
import System

@main
struct SizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sz",
        abstract: "Report the disk usage of a directory.",
    )

    @Flag(name: [.short, .long], help: "Prints each unreadable path and its error.")
    var verbose = false

    @Flag(help: "Exclude APFS clones that don't take up any space yet.")
    var ignoreClones = false

    @Option(
        name: [.short, .long],
        parsing: .unconditional,
        help: "Report directories up to this depth.",
    )
    var depth: Int?

    @Flag(help: "Omit tree hierarchy symbols.")
    var plain = false

    @Argument(help: "The directory to scan. Defaults to the current directory.", completion: .directory)
    var directory: String = "."

    mutating func validate() throws {
        if let depth, depth < 0 {
            throw ValidationError("'--depth' must be nonnegative.")
        }
    }

    mutating func run() throws {
        let scanner = DiskUsageScanner(
            verbose: verbose,
            ignoreClones: ignoreClones,
            maximumReportDepth: depth,
        )
        do {
            let result = try scanner.scan(FilePath(directory))
            let output = UsageRenderer.render(
                result: result,
                rootArgument: directory,
                depthEnabled: depth != nil,
                plain: plain,
            )
            FileHandle.standardOutput.write(Data(output.utf8))
            if result.unreadableEntryCount > 0 {
                let noun = result.unreadableEntryCount == 1 ? "file" : "files"
                writeStandardError("\(result.unreadableEntryCount) \(noun) could not be read\n")
            }
        } catch {
            writeStandardError("sz: \(error)\n")
            throw ExitCode.failure
        }
    }
}

private enum UsageRenderer {
    private struct Frame {
        let children: [DirectoryUsage]
        var nextIndex = 0
    }

    private struct PlainItem {
        let usage: DirectoryUsage
        let visited: Bool
    }

    static func render(
        result: ScanResult,
        rootArgument: String,
        depthEnabled: Bool,
        plain: Bool,
    ) -> String {
        guard depthEnabled, let root = result.directoryUsages.first(where: { $0.parentPath == nil }) else {
            return line(blocks: result.totalBlocks, path: rootArgument)
        }

        let children = childrenByParent(result.directoryUsages)
        if plain {
            return renderPlain(root: root, rootArgument: rootArgument, children: children)
        }
        return renderTree(root: root, rootArgument: rootArgument, children: children)
    }

    private static func childrenByParent(
        _ usages: [DirectoryUsage]
    ) -> [FilePath: [DirectoryUsage]] {
        var result: [FilePath: [DirectoryUsage]] = [:]
        for usage in usages {
            guard let parentPath = usage.parentPath else { continue }
            result[parentPath, default: []].append(usage)
        }
        for parentPath in result.keys {
            result[parentPath]?.sort(by: orderedBefore)
        }
        return result
    }

    private static func orderedBefore(_ lhs: DirectoryUsage, _ rhs: DirectoryUsage) -> Bool {
        if lhs.totalBlocks != rhs.totalBlocks {
            return lhs.totalBlocks > rhs.totalBlocks
        }
        return platformStringLessThan(lhs.path, rhs.path)
    }

    private static func renderTree(
        root: DirectoryUsage,
        rootArgument: String,
        children: [FilePath: [DirectoryUsage]],
    ) -> String {
        var output = line(blocks: root.totalBlocks, path: rootArgument)
        var stack = [Frame(children: children[root.path] ?? [])]

        while !stack.isEmpty {
            let level = stack.count - 1
            if stack[level].nextIndex == stack[level].children.count {
                stack.removeLast()
                continue
            }

            let childIndex = stack[level].nextIndex
            let child = stack[level].children[childIndex]
            stack[level].nextIndex += 1
            let isLast = stack[level].nextIndex == stack[level].children.count

            var prefix = ""
            if level > 0 {
                for ancestorLevel in 0 ..< level {
                    let ancestor = stack[ancestorLevel]
                    prefix += ancestor.nextIndex == ancestor.children.count ? "    " : "│   "
                }
            }
            prefix += isLast ? "└── " : "├── "
            let name = child.path.lastComponent?.lossyString ?? child.path.lossyString
            output += line(blocks: child.totalBlocks, path: prefix + name)
            stack.append(Frame(children: children[child.path] ?? []))
        }

        return output
    }

    private static func renderPlain(
        root: DirectoryUsage,
        rootArgument: String,
        children: [FilePath: [DirectoryUsage]],
    ) -> String {
        var output = ""
        var stack = [PlainItem(usage: root, visited: false)]
        while let item = stack.popLast() {
            if item.visited {
                let path = item.usage.parentPath == nil ? rootArgument : item.usage.path.lossyString
                output += line(blocks: item.usage.totalBlocks, path: path)
                continue
            }

            stack.append(PlainItem(usage: item.usage, visited: true))
            for child in (children[item.usage.path] ?? []).reversed() {
                stack.append(PlainItem(usage: child, visited: false))
            }
        }
        return output
    }

    private static func line(blocks: UInt64, path: String) -> String {
        "\(DiskUsageScanner.formatSize(blocks: blocks))\t\(path)\n"
    }
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
