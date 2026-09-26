import Testing
import Foundation
@testable import IvyCore

@Suite("Tool Validation & Types Tests")
struct ToolValidationTests {

    @Test("Valid application names pass validation")
    func testValidAppNames() throws {
        let validNames = [
            "Safari",
            "Notes",
            "Calculator",
            "Calculator.app",
            "Google Chrome",
            "Visual Studio Code",
            "Slack",
            "Final Cut Pro",
            "Music"
        ]

        for name in validNames {
            let sanitized = try ToolValidation.validateAppName(name)
            #expect(!sanitized.isEmpty)
        }
    }

    @Test("Whitespace surrounding valid names is trimmed")
    func testWhitespaceTrimming() throws {
        let input = "   Safari   \n"
        let sanitized = try ToolValidation.validateAppName(input)
        #expect(sanitized == "Safari")
    }

    @Test("Empty and whitespace-only application names throw invalidArgument")
    func testEmptyAppNames() {
        #expect(throws: ToolError.self) {
            _ = try ToolValidation.validateAppName("")
        }

        #expect(throws: ToolError.self) {
            _ = try ToolValidation.validateAppName("   \t\n  ")
        }
    }

    @Test("Names with path separators and traversals throw invalidArgument")
    func testPathTraversals() {
        let malicious = [
            "../../Applications/Safari.app",
            "/Applications/Safari.app",
            "Safari/../../bin/sh",
            "app\\path",
            "..",
            "."
        ]

        for bad in malicious {
            #expect(throws: ToolError.self) {
                _ = try ToolValidation.validateAppName(bad)
            }
        }
    }

    @Test("Names with shell metacharacters and control characters throw invalidArgument")
    func testShellMetacharacters() {
        let injections = [
            "Safari; rm -rf ~",
            "Safari && echo hacked",
            "Safari | cat",
            "Safari`whoami`",
            "Safari$(whoami)",
            "Safari>out.txt",
            "Safari<input.txt",
            "Safari\0hidden",
            "Safari*",
            "Safari?",
            "Safari{a,b}"
        ]

        for injection in injections {
            #expect(throws: ToolError.self) {
                _ = try ToolValidation.validateAppName(injection)
            }
        }
    }

    @Test("Names exceeding maximum length throw invalidArgument")
    func testExcessiveLength() {
        let oversized = String(repeating: "A", count: ToolValidation.maxAppNameLength + 1)
        #expect(throws: ToolError.self) {
            _ = try ToolValidation.validateAppName(oversized)
        }
    }

    @Test("ToolResult initializers and factory methods")
    func testToolResult() {
        let success = ToolResult.success("Done")
        #expect(success.output == "Done")
        #expect(success.isError == false)

        let failure = ToolResult.failure("Failed")
        #expect(failure.output == "Failed")
        #expect(failure.isError == true)
    }

    @Test("ToolError localized descriptions are informative")
    func testToolErrorDescriptions() {
        let missing = ToolError.missingArgument("name")
        #expect(missing.errorDescription?.contains("name") == true)

        let invalid = ToolError.invalidArgument("Bad path")
        #expect(invalid.errorDescription?.contains("Bad path") == true)

        let notFound = ToolError.toolNotFound("foo_tool")
        #expect(notFound.errorDescription?.contains("foo_tool") == true)

        let exec = ToolError.executionFailed("Crash")
        #expect(exec.errorDescription?.contains("Crash") == true)
    }

    @Test("Valid Unicode and international application names pass validation")
    func testUnicodeAppNames() throws {
        let names = ["微信", "LINE", "カカオトーク", "CaféPlayer", "Übersicht"]
        for name in names {
            let sanitized = try ToolValidation.validateAppName(name)
            #expect(sanitized == name)
        }
    }

    @Test("Exact boundary length of 100 characters succeeds")
    func testBoundaryLength() throws {
        let exactly100 = String(repeating: "A", count: ToolValidation.maxAppNameLength)
        let validated = try ToolValidation.validateAppName(exactly100)
        #expect(validated.count == 100)

        let exactly101 = String(repeating: "A", count: ToolValidation.maxAppNameLength + 1)
        #expect(throws: ToolError.self) {
            _ = try ToolValidation.validateAppName(exactly101)
        }
    }

    @Test("Hidden application names prefixed with dot are rejected")
    func testHiddenDotPrefixNames() {
        let hidden = [".hiddenApp", ".DS_Store", "..privateApp"]
        for bad in hidden {
            #expect(throws: ToolError.self) {
                _ = try ToolValidation.validateAppName(bad)
            }
        }
    }
}
