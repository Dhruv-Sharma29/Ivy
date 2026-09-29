import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 6 - App Bundle, Info.plist & Entitlements")
struct Phase6BundleConfigurationTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Info.plist exists and contains all required TCC privacy usage descriptions")
    func infoPlistCompleteness() throws {
        let plistURL = Self.repoRoot.appendingPathComponent("Sources/Ivy/Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let info = try #require(dict)

        #expect(info["CFBundleIdentifier"] as? String == "com.ivy.assistant")
        #expect(info["CFBundleExecutable"] as? String == "Ivy")
        #expect(info["LSUIElement"] as? Bool == true)

        let micDesc = try #require(info["NSMicrophoneUsageDescription"] as? String)
        #expect(!micDesc.isEmpty && micDesc.contains("microphone"))

        let speechDesc = try #require(info["NSSpeechRecognitionUsageDescription"] as? String)
        #expect(!speechDesc.isEmpty && speechDesc.contains("Hey Ivy"))

        let calDesc = try #require(info["NSCalendarsUsageDescription"] as? String)
        #expect(!calDesc.isEmpty && calDesc.contains("calendar"))

        let calFullDesc = try #require(info["NSCalendarsFullAccessUsageDescription"] as? String)
        #expect(!calFullDesc.isEmpty && calFullDesc.contains("calendar"))

        let aeDesc = try #require(info["NSAppleEventsUsageDescription"] as? String)
        #expect(!aeDesc.isEmpty && aeDesc.contains("automate"))
    }

    @Test("Ivy.entitlements contains the minimal set of production Hardened Runtime entitlements")
    func entitlementsCompleteness() throws {
        let entitlementsURL = Self.repoRoot.appendingPathComponent("Sources/Ivy/Resources/Ivy.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let entitlements = try #require(dict)

        #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements["com.apple.security.personal-information.calendars"] as? Bool == true)
        #expect(entitlements["com.apple.security.automation.apple-events"] as? Bool == true)

        // Strict minimization: verify no arbitrary excessive privileges
        #expect(entitlements["com.apple.security.app-sandbox"] == nil)
        #expect(entitlements["com.apple.security.files.all"] == nil)
        #expect(entitlements["com.apple.security.temporary-exception.shared-preference.read-write"] == nil)
    }

    @Test("Launcher script signs with hardened runtime and entitlements")
    func launcherScriptFlags() throws {
        let scriptURL = Self.repoRoot.appendingPathComponent("scripts/run-ivy-app.sh")
        let text = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(text.contains("--options runtime"))
        #expect(text.contains("--entitlements"))
        #expect(text.contains("Sources/Ivy/Resources/Ivy.entitlements"))
    }
}

@Suite("Phase 6 - Permission Management Abstraction")
struct Phase6PermissionManagerTests {
    @Test("PermissionType cases and display names")
    func typesAndNames() {
        #expect(PermissionType.microphone.displayName == "Microphone")
        #expect(PermissionType.speechRecognition.displayName == "Speech Recognition")
        #expect(PermissionType.calendar.displayName == "Calendar")
        #expect(PermissionType.automation.displayName == "Automation")
        #expect(PermissionType.allCases.count == 4)
    }

    @Test("MockPermissionManager defaults to notDetermined and records requests")
    func mockDefaultsAndRequests() async {
        let manager = MockPermissionManager()
        #expect(manager.status(for: .microphone) == .notDetermined)
        #expect(manager.status(for: .calendar) == .notDetermined)

        manager.setRequestResponse(.denied, for: .microphone)
        let state = await manager.requestPermission(for: .microphone)
        #expect(state == .denied)
        #expect(manager.status(for: .microphone) == .denied)
        #expect(manager.requestedTypes == [.microphone])
    }

    @Test("MockPermissionManager handles all states predictably")
    func mockStates() {
        let manager = MockPermissionManager()
        for state: PermissionState in [.authorized, .denied, .restricted, .notDetermined, .unsupported] {
            manager.setStatus(state, for: .calendar)
            #expect(manager.status(for: .calendar) == state)
        }
    }
}

@Suite("Phase 6 - Microphone & Speech Permission Flows")
@MainActor
struct Phase6VoicePermissionFlowTests {
    @Test("Denied microphone permission transitions to error and halts capture")
    func deniedMicHaltsCapture() async {
        let capture = MockAudioCapture(isPermissionGranted: false)
        let session = MockGeminiLiveSession()
        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(),
            wakeWordDetector: MockWakeWordDetector()
        )

        await coordinator.startSession()

        #expect(!capture.isCapturing)
        #expect(capture.startCaptureCallCount == 0)
        #expect(!session.isConnected)
        if case .error(let msg) = coordinator.state {
            #expect(msg.contains("Microphone access was denied"))
        } else {
            Issue.record("Expected .error state on denied mic permission, got \(coordinator.state)")
        }
    }

    @Test("Speech recognition permission unavailable disables wake phrase without crashing")
    func speechUnavailableGracefulDegradation() async {
        let capture = MockAudioCapture()
        let session = MockGeminiLiveSession()
        let detector = MockWakeWordDetector(isPermissionGranted: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(),
            wakeWordDetector: detector
        )

        await coordinator.startSession()

        #expect(coordinator.state == .listening)
        #expect(!coordinator.isWakePhraseAvailable)
        #expect(capture.isCapturing)
        await coordinator.stopSession()
    }
}

@Suite("Phase 6 - Tool Permission & Automation Error Mapping")
struct Phase6ToolPermissionTests {
    private struct FailingAppleScriptExecutor: AppleScriptExecutorProtocol {
        let errorNumber: Int
        func execute(script: String) async throws -> String {
            if errorNumber == -1743 {
                throw ToolError.executionFailed("Automation permission denied (Error -1743). Please grant Ivy permission to automate target applications in macOS System Settings > Privacy & Security > Automation.")
            }
            throw ToolError.executionFailed("Error \(errorNumber): Target failed.")
        }
    }

    private struct FailingCalendarExecutor: CalendarExecutorProtocol {
        func createEvent(title: String, startDate: Date, duration: TimeInterval) async throws -> CalendarEventResult {
            throw CalendarError.permissionDenied
        }
    }

    @Test("AppleScript errAEEventNotPermitted (-1743) returns user-actionable instructions")
    func appleScriptAutomationErrorMapping() async throws {
        let tool = RunAppleScriptTool(executor: FailingAppleScriptExecutor(errorNumber: -1743))
        let result = try await tool.execute(arguments: ["script": .string("tell application \"Finder\" to activate")])

        #expect(result.isError)
        #expect(result.output.contains("Automation permission denied (Error -1743)"))
        #expect(result.output.contains("Privacy & Security > Automation"))
    }

    @Test("Calendar permission denied returns structured CalendarError.permissionDenied")
    func calendarPermissionDeniedMapping() async throws {
        let tool = CalendarEventTool(executor: FailingCalendarExecutor())
        let result = try await tool.execute(arguments: [
            "title": .string("Team Sync"),
            "date": .string("2026-10-15T10:00:00Z")
        ])

        #expect(result.isError)
        #expect(result.output.contains("Calendar access denied"))
        #expect(result.output.contains("Privacy & Security > Calendars"))
    }
}

@Suite("Phase 6 - Startup Safety Invariants")
@MainActor
struct Phase6StartupSafetyTests {
    @Test("Startup never prompts for microphone, speech, or calendar permissions")
    func noAutoPermissionsAtLaunch() async {
        let capture = MockAudioCapture()
        let session = MockGeminiLiveSession()
        let detector = MockWakeWordDetector()

        let env = IvyAppEnvironment(
            settingsStore: InMemorySettingsStore(),
            credentials: FixedCredentialProvider([.geminiAPIKey: "AQ.fakeKey_0123456789abcdef0123456789abcdef"]),
            conversationStore: InMemoryConversationStore(),
            voiceManager: VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: detector)
        }

        #expect(env.liveCoordinator.state == .idle)
        #expect(capture.startCaptureCallCount == 0)
        #expect(!session.isConnected)
        #expect(detector.processedChunksCount == 0)
        #expect(env.brain.messages.isEmpty)
    }
}
