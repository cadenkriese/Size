import Darwin
import Foundation
import Testing
@testable import Size

private final class DepthTestBundleMarker: NSObject {}

struct DepthOutputTests {
    @Test func printsLargestFirstTreeAndDuStylePlainOutput() throws {
        try withTemporaryDirectory { root in
            let fileManager = FileManager.default
            let large = root.appendingPathComponent("large", isDirectory: true)
            let nested = large.appendingPathComponent("nested", isDirectory: true)
            let small = root.appendingPathComponent("small", isDirectory: true)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: small, withIntermediateDirectories: false)
            try Data(repeating: 0xA5, count: 64 * 1_024)
                .write(to: nested.appendingPathComponent("large-file"))
            try Data(repeating: 0x5A, count: 8 * 1_024)
                .write(to: small.appendingPathComponent("small-file"))

            let rootLine = "\(try duSize(for: root))\t\(root.path)"
            let tree = try invoke(["--depth", "2", root.path])
            let treeLines = tree.standardOutput.split(separator: "\n")
            #expect(tree.status == 0)
            #expect(treeLines.count == 4)
            #expect(treeLines[0] == rootLine)
            #expect(treeLines[1] == "\(try duSize(for: large))\t├── large")
            #expect(treeLines[2] == "\(try duSize(for: nested))\t│   └── nested")
            #expect(treeLines[3] == "\(try duSize(for: small))\t└── small")

            let depthOne = try invoke(["-d", "1", root.path])
            let depthOneLines = depthOne.standardOutput.split(separator: "\n")
            #expect(depthOne.status == 0)
            #expect(depthOneLines.count == 3)
            #expect(depthOneLines[1] == "\(try duSize(for: large))\t├── large")
            #expect(depthOneLines[2] == "\(try duSize(for: small))\t└── small")

            let depthZero = try invoke(["--depth", "0", root.path])
            #expect(depthZero.standardOutput == rootLine + "\n")
            let plainSummary = try invoke(["--plain", root.path])
            #expect(plainSummary.standardOutput == rootLine + "\n")

            let plain = try invoke(["--depth", "2", "--plain", root.path])
            let plainLines = plain.standardOutput.split(separator: "\n").map(String.init)
            #expect(plain.status == 0)
            #expect(plainLines == [
                "\(try duSize(for: nested))\t\(nested.path)",
                "\(try duSize(for: large))\t\(large.path)",
                "\(try duSize(for: small))\t\(small.path)",
                rootLine
            ])
        }
    }

    @Test func attributesCrossDirectoryHardLinksDeterministically() throws {
        try withTemporaryDirectory { root in
            let fileManager = FileManager.default
            let first = root.appendingPathComponent("a", isDirectory: true)
            let second = root.appendingPathComponent("b", isDirectory: true)
            try fileManager.createDirectory(at: first, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: second, withIntermediateDirectories: false)
            let original = first.appendingPathComponent("file")
            try Data(repeating: 0xA5, count: 16 * 1_024).write(to: original)
            try fileManager.linkItem(at: original, to: second.appendingPathComponent("link"))

            let result = try invoke(["--depth", "1", "--plain", root.path])
            let lines = result.standardOutput.split(separator: "\n").map(String.init)
            let firstBlocks = try allocatedBlocks(for: first) + allocatedBlocks(for: original)
            let secondBlocks = try allocatedBlocks(for: second)
            #expect(result.status == 0)
            #expect(lines == [
                "\(DiskUsageScanner.formatSize(blocks: firstBlocks))\t\(first.path)",
                "\(DiskUsageScanner.formatSize(blocks: secondBlocks))\t\(second.path)",
                "\(try duSize(for: root))\t\(root.path)"
            ])
        }
    }

    private struct Invocation {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private func invoke(_ arguments: [String]) throws -> Invocation {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try executableURL()
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return Invocation(
            status: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func executableURL() throws -> URL {
        let products = Bundle(for: DepthTestBundleMarker.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("sz")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        return executable
    }

    private func duSize(for directory: URL) throws -> Substring {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sh", directory.path]
        process.environment = ["BLOCKSIZE": "512", "LC_ALL": "C", "LANG": "C"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = try #require(String(data: data, encoding: .utf8))
        return try #require(text.split(whereSeparator: \Character.isWhitespace).first)
    }

    private func allocatedBlocks(for url: URL) throws -> UInt64 {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation {
            lstat($0, &metadata)
        }
        let statError = errno
        try #require(status == 0, "lstat failed with errno \(statError)")
        try #require(metadata.st_blocks >= 0, "lstat returned a negative block count")
        return UInt64(metadata.st_blocks)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("sizes-depth-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        try body(root)
    }
}
