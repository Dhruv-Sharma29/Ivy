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
        #expect(result.output.contains("Application 'UnknownApp' not found"))
        #expect(result.output.contains("~/Applications"))
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

    @Test("SystemWorkspace resolves existing system application URL")
    func testSystemWorkspaceLookup() {
        let systemWorkspace = SystemWorkspace()
        let safariURL = systemWorkspace.findApplicationURL(named: "Safari")
        #expect(safariURL != nil)

        let nonExistent = systemWorkspace.findApplicationURL(named: "NonExistentApp123456789")
        #expect(nonExistent == nil)
    }

    @Test("OpenAppTool handles application name that already ends with .app")
    func testAppSuffixHandling() async throws {
        let mock = MockWorkspace()
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        mock.knownApps["calendar.app"] = calendarURL

        let tool = OpenAppTool(workspace: mock)
        let result = try await tool.execute(arguments: ["name": "Calendar.app"])

        #expect(result.isError == false)
        #expect(result.output.contains("Opened Calendar.app successfully."))
        #expect(mock.openedURLs == [calendarURL])
    }

    @Test("OpenAppTool safely ignores superfluous arguments when parsing name")
    func testSuperfluousArgumentsIgnored() async throws {
        let mock = MockWorkspace()
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        mock.knownApps["safari.app"] = safariURL

        let tool = OpenAppTool(workspace: mock)
        let result = try await tool.execute(arguments: [
            "name": "Safari",
            "extra": "ignore",
            "number": 99,
            "flag": true
        ])

        #expect(result.isError == false)
        #expect(mock.openedURLs == [safariURL])
    }

    @Test("OpenAppTool rejects boolean, array, and null variants for name")
    func testInvalidTypeVariants() async {
        let mock = MockWorkspace()
        let tool = OpenAppTool(workspace: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": true])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": ["nested": "Safari"]])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": ["item1", "item2"]])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["name": nil])
        }
    }

    @Test("SystemWorkspace with custom search directories returns nil for empty directory")
    func testCustomEmptySearchDirectory() {
        let emptyWS = SystemWorkspace(searchDirectories: ["/nonexistent_test_dir_12345"])
        #expect(emptyWS.findApplicationURL(named: "Safari") == nil)
    }

    @Test("VS Code aliases resolve the installed bundle without launching it", arguments: [
        "VS Code", "vscode", "Vs CoDe.APP", "  VS Code  ", "Visual Studio Code.app"
    ])
    func testVSCodeAliases(request: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Visual Studio Code.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let workspace = SystemWorkspace(searchDirectories: [root.path])
        #expect(workspace.findApplicationURL(named: request)?.standardizedFileURL == app.standardizedFileURL)
        #expect(workspace.findApplicationURL(named: "Code Studio") == nil)
        #expect(workspace.findApplicationURL(named: "VS Code Insiders") == nil)
    }

    @Test("Insiders aliases stay separate and compare names case-insensitively", arguments: [
        "VS Code Insiders", "vscode-insiders.app", "VSCODEINSIDERS"
    ])
    func testInsidersAliases(request: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("visual studio code - insiders.APP")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let workspace = SystemWorkspace(searchDirectories: [root.path])
        let resolved = try #require(workspace.findApplicationURL(named: request))
        let resolvedID = try resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let appID = try app.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        #expect(resolvedID != nil && resolvedID == appID)
        #expect(workspace.findApplicationURL(named: "VS Code") == nil)
    }

    @Test("Exact installed names take priority over known aliases across directories")
    func testAliasPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let canonical = first.appendingPathComponent("Visual Studio Code.app")
        let exact = second.appendingPathComponent("VS Code.app")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exact, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let workspace = SystemWorkspace(searchDirectories: [first.path, second.path])
        #expect(workspace.findApplicationURL(named: "VS Code")?.standardizedFileURL == exact.standardizedFileURL)
        #expect(workspace.findApplicationURL(named: "Visual Studio Code")?.standardizedFileURL == canonical.standardizedFileURL)
    }
}
