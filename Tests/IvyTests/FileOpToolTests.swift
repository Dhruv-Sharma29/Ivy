import Testing
import Foundation
@testable import IvyCore

/// In-memory mock implementation of FileExecutorProtocol for safe unit testing.
final class MockFileExecutor: FileExecutorProtocol, @unchecked Sendable {
    struct RecordedCall: Equatable, Sendable {
        let action: FileAction
        let path: String
        let content: String?
    }

    var files: [String: String] = [:]
    var recordedCalls: [RecordedCall] = []
    var errorToThrow: (any Error)? = nil

    func readFile(at path: String) async throws -> FileOpResult {
        if let errorToThrow { throw errorToThrow }
        recordedCalls.append(RecordedCall(action: .read, path: path, content: nil))
        guard let content = files[path] else {
            throw FileOpError.fileNotFound(path)
        }
        return FileOpResult(
            action: .read,
            path: path,
            content: content,
            bytesAffected: content.utf8.count,
            message: content
        )
    }

    func writeFile(at path: String, content: String) async throws -> FileOpResult {
        if let errorToThrow { throw errorToThrow }
        recordedCalls.append(RecordedCall(action: .write, path: path, content: content))
        files[path] = content
        return FileOpResult(
            action: .write,
            path: path,
            content: nil,
            bytesAffected: content.utf8.count,
            message: "Successfully wrote \(content.utf8.count) bytes to '\(path)'."
        )
    }

    func deleteFile(at path: String) async throws -> FileOpResult {
        if let errorToThrow { throw errorToThrow }
        recordedCalls.append(RecordedCall(action: .delete, path: path, content: nil))
        guard files.removeValue(forKey: path) != nil else {
            throw FileOpError.fileNotFound(path)
        }
        return FileOpResult(
            action: .delete,
            path: path,
            content: nil,
            bytesAffected: 0,
            message: "Successfully deleted file '\(path)'."
        )
    }
}

@Suite("FileOpTool Tests")
struct FileOpToolTests {
    let testSandboxURL: URL

    init() {
        testSandboxURL = URL(fileURLWithPath: "/Users/testuser/Sandbox")
    }

    @Test("Declaration metadata and schema properties")
    func testToolDeclaration() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(tool.name == "file_op")
        #expect(tool.safetyClassification == .risky)
        #expect(tool.declaration.name == "file_op")
        #expect(tool.declaration.parameters?.properties["action"]?.type == "STRING")
        #expect(tool.declaration.parameters?.properties["path"]?.type == "STRING")
        #expect(tool.declaration.parameters?.properties["content"]?.type == "STRING")
        #expect(tool.declaration.parameters?.required == ["action", "path"])
    }

    @Test("Valid read arguments validate and execute successfully")
    func testReadExecution() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("note.txt").path
        mock.files[filePath] = "Hello from Ivy."

        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)
        let args: [String: AnyCodable] = [
            "action": AnyCodable("read"),
            "path": AnyCodable(filePath)
        ]

        try tool.validate(arguments: args)
        let result = try await tool.execute(arguments: args)

        #expect(result.isError == false)
        #expect(result.output == "Hello from Ivy.")
        #expect(mock.recordedCalls.count == 1)
        #expect(mock.recordedCalls[0] == MockFileExecutor.RecordedCall(action: .read, path: filePath, content: nil))
    }

    @Test("Valid write arguments validate and execute successfully")
    func testWriteExecution() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("output.txt").path
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let args: [String: AnyCodable] = [
            "action": AnyCodable("write"),
            "path": AnyCodable(filePath),
            "content": AnyCodable("Brand new content")
        ]

        try tool.validate(arguments: args)
        let result = try await tool.execute(arguments: args)

        #expect(result.isError == false)
        #expect(result.output.contains("Successfully wrote"))
        #expect(mock.files[filePath] == "Brand new content")
        #expect(mock.recordedCalls.count == 1)
        #expect(mock.recordedCalls[0] == MockFileExecutor.RecordedCall(action: .write, path: filePath, content: "Brand new content"))
    }

    @Test("Valid delete arguments validate and execute successfully")
    func testDeleteExecution() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("temp.txt").path
        mock.files[filePath] = "To be deleted"
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let args: [String: AnyCodable] = [
            "action": AnyCodable("delete"),
            "path": AnyCodable(filePath)
        ]

        try tool.validate(arguments: args)
        let result = try await tool.execute(arguments: args)

        #expect(result.isError == false)
        #expect(result.output.contains("Successfully deleted"))
        #expect(mock.files[filePath] == nil)
        #expect(mock.recordedCalls.count == 1)
        #expect(mock.recordedCalls[0] == MockFileExecutor.RecordedCall(action: .delete, path: filePath, content: nil))
    }

    @Test("Missing action argument throws missingArgument")
    func testMissingActionThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "path": AnyCodable("/Users/testuser/Sandbox/file.txt")
            ])
        }
    }

    @Test("Invalid action argument throws invalidArgument")
    func testInvalidActionThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("chmod"),
                "path": AnyCodable("/Users/testuser/Sandbox/file.txt")
            ])
        }
    }

    @Test("Missing path argument throws missingArgument")
    func testMissingPathThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read")
            ])
        }
    }

    @Test("Empty path throws invalidArgument")
    func testEmptyPathThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("   ")
            ])
        }
    }

    @Test("Write action missing content argument throws missingArgument")
    func testWriteMissingContentThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("write"),
                "path": AnyCodable("/Users/testuser/Sandbox/file.txt")
            ])
        }
    }

    @Test("Null byte in path throws invalidArgument")
    func testNullByteInPathThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/testuser/Sandbox/file\0.txt")
            ])
        }
    }

    @Test("Path traversal sequence '..' throws invalidArgument")
    func testPathTraversalThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/testuser/Sandbox/../Secret/passwords.txt")
            ])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("../../etc/passwd")
            ])
        }
    }

    @Test("System root paths are rejected as prohibited")
    func testSystemRootPathsRejected() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        for sysPath in ["/System/Library", "/usr/bin/python", "/etc/hosts", "/private/var"] {
            #expect(throws: ToolError.self) {
                try tool.validate(arguments: [
                    "action": AnyCodable("read"),
                    "path": AnyCodable(sysPath)
                ])
            }
        }
    }

    @Test("Sensitive user credential paths are rejected")
    func testSensitivePathsRejected() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        for sensitive in [".ssh/id_rsa", ".gnupg/secring.gpg", ".aws/credentials", "Library/Keychains/login.keychain"] {
            let fullPath = testSandboxURL.appendingPathComponent(sensitive).path
            #expect(throws: ToolError.self) {
                try tool.validate(arguments: [
                    "action": AnyCodable("read"),
                    "path": AnyCodable(fullPath)
                ])
            }
        }
    }

    @Test("Path escaping permitted scope throws invalidArgument")
    func testPathEscapingPermittedScopeThrows() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/otheruser/Documents/secret.txt")
            ])
        }
    }

    @Test("FileOpError.fileNotFound returns structured failure ToolResult")
    func testFileNotFoundReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)
        let filePath = testSandboxURL.appendingPathComponent("missing.txt").path

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("read"),
            "path": AnyCodable(filePath)
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("File not found"))
    }

    @Test("FileOpError.permissionDenied returns structured failure ToolResult")
    func testPermissionDeniedReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("locked.txt").path
        mock.errorToThrow = FileOpError.permissionDenied(filePath)
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("read"),
            "path": AnyCodable(filePath)
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Permission denied"))
    }

    @Test("FileOpError.isDirectory returns structured failure ToolResult")
    func testDirectoryReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let dirPath = testSandboxURL.appendingPathComponent("subfolder").path
        mock.errorToThrow = FileOpError.isDirectory(dirPath)
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("delete"),
            "path": AnyCodable(dirPath)
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Directory operations are not permitted"))
    }

    @Test("FileOpError.fileTooLarge returns structured failure ToolResult")
    func testFileTooLargeReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("huge.log").path
        mock.errorToThrow = FileOpError.fileTooLarge(actual: 10_000_000, maxAllowed: 1_048_576)
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("read"),
            "path": AnyCodable(filePath)
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("File exceeds maximum read size limit"))
    }

    @Test("Unexpected non-string argument types throw invalidArgument")
    func testUnexpectedArgumentTypes() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        // Non-string action
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable(123),
                "path": AnyCodable("/Users/testuser/Sandbox/note.txt")
            ])
        }

        // Non-string path
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable(true)
            ])
        }

        // Non-string content for write
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("write"),
                "path": AnyCodable("/Users/testuser/Sandbox/note.txt"),
                "content": AnyCodable(999)
            ])
        }
    }

    @Test("Path normalization resolves relative segments and double slashes")
    func testPathNormalization() throws {
        let normalized = try ToolValidation.validateFilePath(
            "/Users/testuser/Sandbox/./folder//file.txt",
            allowedRoot: testSandboxURL
        )
        #expect(normalized == "/Users/testuser/Sandbox/folder/file.txt")
    }

    @Test("../../ traversal sequences are strictly rejected")
    func testDoubleDotTraversalRejection() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/testuser/Sandbox/../../etc/shadow")
            ])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/testuser/Sandbox/folder/..")
            ])
        }
    }

    @Test("Path exceeding maximum length of 4096 characters throws invalidArgument")
    func testPathExceedingMaxLength() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)
        let longPath = "/Users/testuser/Sandbox/" + String(repeating: "a", count: 4100)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable(longPath)
            ])
        }
    }

    @Test("Symlink escaping permitted scope is rejected")
    func testSymlinkEscapingPermittedScope() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let outsideDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outsideDir) }

        let symlinkURL = tempDir.appendingPathComponent("escape_link")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDir)

        #expect(throws: ToolError.self) {
            try ToolValidation.validateFilePath(symlinkURL.path, allowedRoot: tempDir)
        }
    }

    @Test("Write error: FileOpError.parentDirectoryNotFound returns failure ToolResult")
    func testParentDirectoryNotFoundReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("nonexistent/dir/file.txt").path
        mock.errorToThrow = FileOpError.parentDirectoryNotFound("/Users/testuser/Sandbox/nonexistent/dir")
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("write"),
            "path": AnyCodable(filePath),
            "content": AnyCodable("payload")
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Parent directory does not exist"))
    }

    @Test("Write error: FileOpError.permissionDenied returns failure ToolResult")
    func testWritePermissionDeniedReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("readonly.txt").path
        mock.errorToThrow = FileOpError.permissionDenied(filePath)
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("write"),
            "path": AnyCodable(filePath),
            "content": AnyCodable("content")
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Permission denied"))
    }

    @Test("Delete error: FileOpError.permissionDenied returns failure ToolResult")
    func testDeletePermissionDeniedReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("system.txt").path
        mock.errorToThrow = FileOpError.permissionDenied(filePath)
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("delete"),
            "path": AnyCodable(filePath)
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Permission denied"))
    }

    @Test("Delete error: FileOpError.fileNotFound returns failure ToolResult")
    func testDeleteFileNotFoundReturnsFailure() async throws {
        let mock = MockFileExecutor()
        let filePath = testSandboxURL.appendingPathComponent("missing.txt").path
        mock.errorToThrow = FileOpError.fileNotFound(filePath)
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        let result = try await tool.execute(arguments: [
            "action": AnyCodable("delete"),
            "path": AnyCodable(filePath)
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("File not found"))
    }

    @Test("Unexpected arguments outside schema throw invalidArgument")
    func testUnexpectedArgumentsThrow() {
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: testSandboxURL)

        // Unknown key
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/testuser/Sandbox/file.txt"),
                "force": AnyCodable(true)
            ])
        }

        // 'content' passed to read action
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("read"),
                "path": AnyCodable("/Users/testuser/Sandbox/file.txt"),
                "content": AnyCodable("unexpected")
            ])
        }

        // 'content' passed to delete action
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": AnyCodable("delete"),
                "path": AnyCodable("/Users/testuser/Sandbox/file.txt"),
                "content": AnyCodable("unexpected")
            ])
        }
    }

    @Test("SystemFileExecutor rejects directory targets across read, write, and delete")
    func testSystemFileExecutorRejectsDirectories() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let executor = SystemFileExecutor()

        // Read directory
        await #expect(throws: FileOpError.isDirectory(tempDir.path)) {
            _ = try await executor.readFile(at: tempDir.path)
        }

        // Write to existing directory
        await #expect(throws: FileOpError.isDirectory(tempDir.path)) {
            _ = try await executor.writeFile(at: tempDir.path, content: "data")
        }

        // Delete directory
        await #expect(throws: FileOpError.isDirectory(tempDir.path)) {
            _ = try await executor.deleteFile(at: tempDir.path)
        }
    }

    @Test("SystemFileExecutor conforms to FileExecutorProtocol")
    func testSystemExecutorConformance() {
        let executor: any FileExecutorProtocol = SystemFileExecutor()
        #expect(executor is SystemFileExecutor)
    }
}
