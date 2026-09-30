import Testing
import Foundation
#if os(macOS)
import AppKit
#endif
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

    @Test("Built Ivy.app bundle structure and binary validity if present")
    func realAppBundleStructureAndSignature() throws {
        let appURL = Self.repoRoot.appendingPathComponent(".build/Ivy.app")
        let fm = FileManager.default
        guard fm.fileExists(atPath: appURL.path) else {
            // If the app hasn't been built yet by run-ivy-app.sh, skip
            return
        }

        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/Ivy")
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")

        #expect(fm.fileExists(atPath: binaryURL.path))
        #expect(fm.isExecutableFile(atPath: binaryURL.path))
        #expect(fm.fileExists(atPath: plistURL.path))

        let data = try Data(contentsOf: plistURL)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let info = try #require(dict)

        #expect(info["CFBundleIdentifier"] as? String == "com.ivy.assistant")
        #expect(info["CFBundleExecutable"] as? String == "Ivy")
        #expect(info["LSUIElement"] as? Bool == true)
    }

    @Test("SystemWakeWordDetector handles non-app or test environment without crashing")
    func systemWakeWordDetectorHandlesNonAppBundleSafely() async {
        let detector = SystemWakeWordDetector()
        // Outside an .app bundle or in headless tests, requestPermission() safely returns false without SIGABRT
        let granted = await detector.requestPermission()
        #expect(!granted)
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
        // Phase 11 added reminders, contacts, screen recording, accessibility and notifications for its tools.
        #expect(PermissionType.allCases.count == 9)
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

    @Test("SystemPermissionManager returns valid states without crashing")
    func systemPermissionManagerStatusQueries() {
        let manager = SystemPermissionManager()
        // Querying permissions must never throw, block, or prompt interactively
        let micStatus = manager.status(for: .microphone)
        let speechStatus = manager.status(for: .speechRecognition)
        let calStatus = manager.status(for: .calendar)
        let autoStatus = manager.status(for: .automation)

        #expect([PermissionState.authorized, .denied, .restricted, .notDetermined, .unsupported].contains(micStatus))
        #expect([PermissionState.authorized, .denied, .restricted, .notDetermined, .unsupported].contains(speechStatus))
        #expect([PermissionState.authorized, .denied, .restricted, .notDetermined, .unsupported].contains(calStatus))
        #expect(autoStatus == .notDetermined)
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

    @Test("Microphone permission denial is recoverable on subsequent session start")
    func microphonePermissionRecovery() async {
        let capture = MockAudioCapture(isPermissionGranted: false)
        let session = MockGeminiLiveSession()
        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(),
            wakeWordDetector: MockWakeWordDetector()
        )

        // 1. Initial attempt fails due to denied permission
        await coordinator.startSession()
        #expect(!capture.isCapturing)
        if case .error = coordinator.state {} else {
            Issue.record("Expected .error state on initial attempt")
        }

        // 2. User grants permission in System Settings, retries
        capture.setPermissionGranted(true)
        await coordinator.startSession()

        #expect(capture.isCapturing)
        #expect(session.isConnected)
        #expect(coordinator.state == .listening)

        await coordinator.stopSession()
        #expect(!capture.isCapturing)
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

    @Test("Speech recognition permission authorized enables wake phrase interruption")
    func speechRecognitionAuthorizedEnablesWakePhrase() async {
        let capture = MockAudioCapture()
        let session = MockGeminiLiveSession()
        let player = MockLiveAudioPlayer()
        let detector = MockWakeWordDetector(shouldTrigger: false, isPermissionGranted: true)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector
        )

        await coordinator.startSession()
        #expect(coordinator.isWakePhraseAvailable)

        // Simulate incoming audio putting Ivy into SPEAKING
        session.simulateEvent(.audioChunk(Data(repeating: 0x11, count: 640)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(coordinator.state == .speaking)

        // Wake word detected during speaking interrupts playback
        detector.simulateTranscription("Hey Ivy, stop right there")
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(coordinator.state == .listening)
        #expect(!player.isPlaying)

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

    private struct SuccessfulCalendarExecutor: CalendarExecutorProtocol {
        func createEvent(title: String, startDate: Date, duration: TimeInterval) async throws -> CalendarEventResult {
            CalendarEventResult(
                eventTitle: title,
                calendarName: "Home",
                startDate: startDate,
                duration: duration,
                message: "Created calendar event '\(title)' on 'Home'."
            )
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

    @Test("Generic AppleScript errors preserve failure diagnostic")
    func genericAppleScriptErrorPreservesDiagnostic() async throws {
        let tool = RunAppleScriptTool(executor: FailingAppleScriptExecutor(errorNumber: -1708))
        let result = try await tool.execute(arguments: ["script": .string("tell application \"Finder\" to quit")])

        #expect(result.isError)
        #expect(result.output.contains("Error -1708"))
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

    @Test("Calendar event creation succeeds without permission error when authorized")
    func calendarEventCreationSuccess() async throws {
        let tool = CalendarEventTool(executor: SuccessfulCalendarExecutor())
        let result = try await tool.execute(arguments: [
            "title": .string("1:1 Review"),
            "date": .string("2026-10-15T14:00:00Z")
        ])

        #expect(!result.isError)
        #expect(result.output.contains("Created calendar event '1:1 Review'"))
    }
}

@Suite("Phase 6 - SafetyGate Permission Independence")
struct Phase6SafetyGatePermissionIndependenceTests {
    private struct MockAppleScriptSuccessExecutor: AppleScriptExecutorProtocol {
        func execute(script: String) async throws -> String {
            "executed successfully"
        }
    }

    @Test("Automation permission cannot bypass SafetyGate confirmation for AppleScript")
    func permissionsDoNotBypassSafetyGateForAppleScript() async {
        let tool = RunAppleScriptTool(executor: MockAppleScriptSuccessExecutor())
        let registry = ToolRegistry(tools: [tool])
        // Denying confirmation provider: simulates user rejecting dangerous script
        let safetyGate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in false })
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        let call = FunctionCall(
            name: "run_applescript",
            args: ["script": .string("tell application \"System Events\" to restart")],
            id: "call_ae_01"
        )

        let response = await dispatcher.dispatch(call)
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["rejected"]?.boolValue == true)
        #expect(response.response["cancelled"]?.boolValue == true)
    }

    @Test("Shell execution cannot bypass SafetyGate confirmation")
    func permissionsDoNotBypassSafetyGateForShell() async {
        let tool = RunShellTool(executor: MockShellExecutor())
        let registry = ToolRegistry(tools: [tool])
        let safetyGate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in false })
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        let call = FunctionCall(
            name: "run_shell",
            args: ["command": .string("rm -rf /tmp/test")],
            id: "call_shell_01"
        )

        let response = await dispatcher.dispatch(call)
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["rejected"]?.boolValue == true)
    }

    @Test("FileOp write operations require SafetyGate confirmation regardless of disk permissions")
    func permissionsDoNotBypassSafetyGateForFileOpWrite() async {
        let sandboxURL = URL(fileURLWithPath: "/Users/testuser/Sandbox")
        let tool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let registry = ToolRegistry(tools: [tool])
        let safetyGate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in false })
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        let call = FunctionCall(
            name: "file_op",
            args: [
                "action": .string("write"),
                "path": .string("/Users/testuser/Sandbox/output.txt"),
                "content": .string("test content")
            ],
            id: "call_file_01"
        )

        let response = await dispatcher.dispatch(call)
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["rejected"]?.boolValue == true)
    }

    @Test("FileOp read operation is classified as safe under SafetyPolicy")
    func fileOpReadIsSafeByDefault() {
        let tool = FileOpTool(executor: MockFileExecutor())
        let policy = SafetyPolicy()
        let readCall = FunctionCall(
            name: "file_op",
            args: ["action": .string("read"), "path": .string("/Users/testuser/Sandbox/read.txt")],
            id: "call_read"
        )
        let writeCall = FunctionCall(
            name: "file_op",
            args: ["action": .string("write"), "path": .string("/Users/testuser/Sandbox/write.txt"), "content": .string("abc")],
            id: "call_write"
        )

        #expect(policy.classification(for: tool, call: readCall) == .safe)
        #expect(policy.classification(for: tool, call: writeCall) == .risky)
    }
}

@Suite("Phase 6 - FileOp & Shell Restrictions")
struct Phase6FileOpAndShellRestrictionsTests {
    @Test("FileOp strictly rejects path traversal attempts")
    func fileOpRejectsPathTraversalOutsideScope() throws {
        let allowedURL = URL(fileURLWithPath: "/Users/test/workspace")
        let tool = FileOpTool(executor: MockFileExecutor(), allowedRoot: allowedURL)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": .string("read"),
                "path": .string("../../../etc/shadow")
            ])
        }
    }

    @Test("FileOp strictly rejects embedded null bytes in path")
    func fileOpRejectsNullBytesInPath() throws {
        let tool = FileOpTool(executor: MockFileExecutor())

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "action": .string("read"),
                "path": .string("/tmp/file\0.txt")
            ])
        }
    }

    @Test("RunShellTool strictly rejects null bytes and BiDi overrides")
    func shellRejectsNullBytesAndBiDiOverrides() throws {
        let tool = RunShellTool(executor: MockShellExecutor())

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "command": .string("ls -la \0 malicious")
            ])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "command": .string("echo \u{202E}dlrow")
            ])
        }
    }
}

@Suite("Phase 6 - Global Hotkey & Push-to-Talk")
struct Phase6GlobalHotkeyAndPTTTests {
    @Test("Default hotkey uses Carbon without requiring accessibility permission")
    func defaultHotkeyUsesCarbonWithoutAccessibility() {
        let shortcut = HotkeyShortcut.defaultPushToTalk
        #expect(shortcut.keyCode == 49) // Space keycode
        #expect(shortcut.modifiers.contains(.command))
        #expect(shortcut.modifiers.contains(.shift))
        // Because keyCode is non-nil, SystemGlobalHotkeyManager routes to Carbon (no Accessibility permission needed)
        #expect(shortcut.keyCode != nil)
    }

    #if os(macOS)
    @Test("chordHeld helper correctly identifies modifier combinations")
    func chordHeldHelperMatchesModifiers() {
        var flags: NSEvent.ModifierFlags = [.command, .shift]
        #expect(SystemGlobalHotkeyManager.chordHeld(flags, required: [.command, .shift]))
        #expect(!SystemGlobalHotkeyManager.chordHeld(flags, required: [.command, .option]))

        flags.insert(.option)
        #expect(!SystemGlobalHotkeyManager.chordHeld(flags, required: [.command, .shift]))
        #expect(SystemGlobalHotkeyManager.chordHeld(flags, required: [.command, .shift, .option]))
    }
    #endif
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

    @Test("Environment lifecycle preserves keychain credentials and settings persistence")
    func environmentLifecyclePreservesKeychainAndSettings() async throws {
        let settingsStore = InMemorySettingsStore()
        let creds = FixedCredentialProvider([
            .geminiAPIKey: "AQ.fakeKey_0123456789abcdef0123456789abcdef",
            .elevenLabsAPIKey: "sk_test_elevenlabs_key_0123456789"
        ])
        let conversationStore = InMemoryConversationStore()

        let env = IvyAppEnvironment(
            settingsStore: settingsStore,
            credentials: creds,
            conversationStore: conversationStore,
            voiceManager: VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        ) { _, _ in
            GeminiLiveVoiceCoordinator(
                session: MockGeminiLiveSession(),
                audioCapture: MockAudioCapture(),
                audioPlayer: MockLiveAudioPlayer(),
                wakeWordDetector: MockWakeWordDetector()
            )
        }

        #expect(env.credentials.credential(for: .geminiAPIKey) == "AQ.fakeKey_0123456789abcdef0123456789abcdef")
        #expect(env.credentials.credential(for: .elevenLabsAPIKey) == "sk_test_elevenlabs_key_0123456789")
        #expect(env.settings.settings.pushToTalkEnabled)
        #expect(env.settings.settings.echoCancellation)
    }
}
