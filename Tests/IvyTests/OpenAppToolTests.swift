import Testing
import Foundation
@testable import IvyCore

final class MockWorkspace: WorkspaceProtocol, @unchecked Sendable {
    var knownApps: [String: URL] = [:]
    var openedURLs: [URL] = []
    var shouldFailOpen: Bool = false
    var failureError: Error = NSError(
        domain: "com.ivy.test",
        code: 500,
        userInfo: [NSLocalizedDescriptionKey: "Application crashed on launch"]
    )

    func findApplicationURL(named name: String) -> URL? {
        let key = name.lowercased()
        if let direct = knownApps[key] { return direct }
        let withApp = key.hasSuffix(".app") ? key : "\(key).app"
        return knownApps[withApp]
    }

    func openApplication(at url: URL) async throws {
        if shouldFailOpen {
            throw failureError
        }
        openedURLs.append(url)
    }
}

@Suite("OpenAppTool Tests")
struct OpenAppToolTests {

    @Test("OpenAppTool declaration metadata is correct")
    func testDeclaration() {
        let tool = OpenAppTool()
        #expect(tool.name == "open_app")
        #expect(tool.declaration.name == "open_app")
        #expect(tool.declaration.parameters?.type == "OBJECT")
        #expect(tool.declaration.parameters?.required?.contains("name") == true)
        #expect(tool.declaration.parameters?.properties["name"]?.type == "STRING")
    }

    @Test("Successfully opens known application")
    func testOpenSuccess() async throws {
        let mock = MockWorkspace()
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        mock.knownApps["safari.app"] = safariURL

        let tool = OpenAppTool(workspace: mock)
        let result = try await tool.execute(arguments: ["name": "Safari"])

        #expect(result.isError == false)
        #expect(result.output.contains("Opened Safari successfully."))
        #expect(mock.openedURLs == [safariURL])
    }

    @Test("Case-insensitively resolves application")
    func testCaseInsensitiveResolution() async throws {
        let mock = MockWorkspace()
        let notesURL = URL(fileURLWithPath: "/System/Applications/Notes.app")
        mock.knownApps["notes.app"] = notesURL

        let tool = OpenAppTool(workspace: mock)
        let result = try await tool.execute(arguments: ["name": "notes"])

        #expect(result.isError == false)
        #expect(mock.openedURLs == [notesURL])
    }

    @Test("Returns failure when application is not found")
    func testAppNotFound() async throws {
        let mock = MockWorkspace()
        let tool = OpenAppTool(workspace: mock)

        let result = try await tool.execute(arguments: ["name": "UnknownApp"])

        #expect(result.isError == true)
        #expect(result.output.contains("not found"))
        #expect(mock.openedURLs.isEmpty)
    }

    @Test("Throws missingArgument when name is not provided")
    func testMissingArgument() async {
        let mock = MockWorkspace()
        let tool = OpenAppTool(workspace: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [:])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": 123])
        }
    }

    @Test("Throws invalidArgument when app name contains injection or path traversal")
    func testInvalidNameRejection() async {
        let mock = MockWorkspace()
        let tool = OpenAppTool(workspace: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": "Safari; rm -rf /"])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": "../Applications/Safari.app"])
        }
    }

    @Test("Returns failure result when workspace openApplication throws")
    func testWorkspaceFailure() async throws {
        let mock = MockWorkspace()
        let appURL = URL(fileURLWithPath: "/Applications/Broken.app")
        mock.knownApps["broken.app"] = appURL
        mock.shouldFailOpen = true

        let tool = OpenAppTool(workspace: mock)
        let result = try await tool.execute(arguments: ["name": "Broken"])

        #expect(result.isError == true)
        #expect(result.output.contains("Failed to open 'Broken'"))
        #expect(result.output.contains("crashed"))
    }
}
