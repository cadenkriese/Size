import Darwin
import Foundation
import Testing

private final class TestBundleMarker: NSObject {}

struct DiskUsageScannerTests {
    @Test func showsGeneratedHelp() throws {
        let result = try invoke(["--help"])
        #expect(result.status == 0)
        #expect(result.standardOutput.contains("USAGE: sizes"))
        #expect(result.standardOutput.contains("--verbose"))
    }

    @Test func rejectsMissingDirectory() throws {
        let result = try invoke([])
        #expect(result.status != 0)
        #expect(result.standardError.contains("Missing expected argument"))
    }

    @Test func rejectsInvalidRoot() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sizes-missing-\(UUID().uuidString)")
        let result = try invoke([missing.path])
        #expect(result.status != 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("sizes:"))
    }

    @Test func rejectsRegularFileRoot() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("file")
            try Data("contents".utf8).write(to: file)
            let result = try invoke([file.path])
            #expect(result.status != 0)
            #expect(result.standardOutput.isEmpty)
            #expect(result.standardError.localizedCaseInsensitiveContains("not a directory"))
        }
    }

    @Test func matchesDuForRepresentativeTree() throws {
        try withTemporaryDirectory { root in
            let fileManager = FileManager.default
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)

            let allocated = root.appendingPathComponent("allocated")
            try Data(repeating: 0xA5, count: 16 * 1_024).write(to: allocated)
            try fileManager.linkItem(at: allocated, to: nested.appendingPathComponent("hard-link"))
            try fileManager.createSymbolicLink(
                at: root.appendingPathComponent("symbolic-link"),
                withDestinationURL: allocated
            )
            try Data().write(to: nested.appendingPathComponent("empty"))

            let result = try invoke([root.path])
            let expectedSize = try duSize(for: root)
            #expect(result.status == 0)
            #expect(firstField(of: result.standardOutput) == expectedSize)
            #expect(result.standardOutput.hasSuffix("\t\(root.path)\n"))
            #expect(result.standardError.isEmpty)
        }
    }

    @Test func matchesDuForInvalidUTF8Filename() throws {
        try withTemporaryDirectory { root in
            try createAllocatedFileWithInvalidUTF8Name(in: root)

            let result = try invoke([root.path])
            let expectedSize = try duSize(for: root)
            #expect(result.status == 0)
            #expect(firstField(of: result.standardOutput) == expectedSize)
            #expect(result.standardError.isEmpty)
        }
    }

    @Test func summarizesAndReportsUnreadableDescendants() throws {
        try withTemporaryDirectory { root in
            let restricted = root.appendingPathComponent("restricted", isDirectory: true)
            try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
            try Data("hidden".utf8).write(to: restricted.appendingPathComponent("file"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: restricted.path
                )
            }

            let summarized = try invoke([root.path])
            #expect(summarized.status == 0)
            #expect(summarized.standardError == "1 file could not be read\n")

            let verbose = try invoke(["--verbose", root.path])
            #expect(verbose.status == 0)
            #expect(verbose.standardError.contains(restricted.path))
            #expect(verbose.standardError.hasSuffix("1 file could not be read\n"))
        }
    }

    private struct Invocation {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private func createAllocatedFileWithInvalidUTF8Name(in directory: URL) throws {
        var path = directory.path.utf8.map(CChar.init(bitPattern:))
        path.append(47)
        path.append(CChar(bitPattern: 0xFF))
        path.append(contentsOf: [88, 88, 88, 88, 88, 88, 0])

        let fileDescriptor = path.withUnsafeMutableBufferPointer {
            mkstemp($0.baseAddress)
        }
        let creationError = errno
        if fileDescriptor < 0, creationError == EILSEQ {
            try Test.cancel("The temporary filesystem rejects invalid UTF-8 names")
        }
        try #require(fileDescriptor >= 0, "mkstemp failed with errno \(creationError)")
        defer { close(fileDescriptor) }

        let contents = [UInt8](repeating: 0xA5, count: 16 * 1_024)
        let written = contents.withUnsafeBytes {
            Darwin.write(fileDescriptor, $0.baseAddress, $0.count)
        }
        #expect(written == contents.count)
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
        let products = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("sizes")
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
        return try #require(firstField(of: text))
    }

    private func firstField(of text: String) -> Substring? {
        text.split(whereSeparator: \Character.isWhitespace).first
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("sizes-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        try body(root)
    }
}
