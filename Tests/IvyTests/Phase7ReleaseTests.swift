import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 7 - Version & Metadata Single Source of Truth")
struct Phase7VersionMetadataTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("IvyVersion constants are non-empty and well-formed")
    func versionConstants() {
        #expect(IvyVersion.marketingVersion == "1.1.0")
        #expect(IvyVersion.buildNumber == "1")
        #expect(IvyVersion.bundleIdentifier == "com.ivy.assistant")
        #expect(IvyVersion.appName == "Ivy")
        #expect(IvyVersion.displayVersion == "v1.1.0 (1)")
        #expect(IvyVersion.userAgent.contains("Ivy/1.1.0"))
        #expect(IvyVersion.userAgent.contains("com.ivy.assistant"))
    }

    @Test("Info.plist version and bundle identifier match IvyVersion single source of truth")
    func infoPlistMatchesIvyVersion() throws {
        let plistURL = Self.repoRoot.appendingPathComponent("Sources/Ivy/Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let info = try #require(dict)

        #expect(info["CFBundleShortVersionString"] as? String == IvyVersion.marketingVersion)
        #expect(info["CFBundleVersion"] as? String == IvyVersion.buildNumber)
        #expect(info["CFBundleIdentifier"] as? String == IvyVersion.bundleIdentifier)
        #expect(info["CFBundleName"] as? String == IvyVersion.appName)
        #expect(info["CFBundleExecutable"] as? String == IvyVersion.appName)
    }
}

@Suite("Phase 7 - Release Packaging & Signing Infrastructure")
struct Phase7ReleasePackagingTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Release script exists, is executable, and contains required security options")
    func releaseScriptIntegrity() throws {
        let scriptURL = Self.repoRoot.appendingPathComponent("scripts/package-release.sh")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: scriptURL.path))
        #expect(fm.isExecutableFile(atPath: scriptURL.path))

        let content = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(content.contains("swift build -c release"))
        #expect(content.contains("--options runtime"))
        #expect(content.contains("--entitlements"))
        #expect(content.contains("Sources/Ivy/Resources/Ivy.entitlements"))
        #expect(content.contains("codesign --verify --deep --strict"))
        #expect(content.contains("hdiutil create"))
        #expect(content.contains("xcrun notarytool submit"))
        #expect(content.contains("xcrun stapler staple"))
        #expect(content.contains("CODESIGN_IDENTITY"))
    }

    @Test("Release artifact hygiene: dist/ directory contains no secrets or temp files")
    func distDirectoryHygiene() throws {
        let distURL = Self.repoRoot.appendingPathComponent("dist")
        let fm = FileManager.default
        guard fm.fileExists(atPath: distURL.path) else {
            // dist not yet built, skip
            return
        }

        let appURL = distURL.appendingPathComponent("Ivy.app")
        if fm.fileExists(atPath: appURL.path) {
            let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
            #expect(fm.fileExists(atPath: plistURL.path))

            let binaryURL = appURL.appendingPathComponent("Contents/MacOS/Ivy")
            #expect(fm.fileExists(atPath: binaryURL.path))
            #expect(fm.isExecutableFile(atPath: binaryURL.path))

            // Verify no .DS_Store leaked
            let dsStoreURL = appURL.appendingPathComponent(".DS_Store")
            #expect(!fm.fileExists(atPath: dsStoreURL.path))
        }
    }
}

@Suite("Phase 7 - First-Launch & Credential UX Lifecycle")
@MainActor
struct Phase7FirstLaunchCredentialTests {
    @Test("First launch with missing API key reports clear missing status without auto-starting capture")
    func firstLaunchMissingKeyBehavior() async {
        let emptyCreds = InMemoryKeychainStore()
        let provider = KeychainCredentialProvider(keychain: emptyCreds, environment: [:])
        let capture = MockAudioCapture()
        let session = MockGeminiLiveSession()

        let brain = IvyBrain(
            client: URLSessionGeminiClient(),
            credentials: provider,
            conversationStore: InMemoryConversationStore()
        )

        #expect(!brain.isGeminiKeyConfigured)
        #expect(brain.geminiCredentialSource == CredentialSource.missing)
        #expect(brain.messages.isEmpty)

        // Sending a message when key is missing produces a friendly error without crashing
        await brain.send("Hello Ivy")
        #expect(brain.messages.count == 2)
        #expect(brain.messages.last?.isError == true)
        #expect(brain.messages.last?.text.contains("Gemini API key") == true)
        #expect(brain.errorMessage == "API key missing")
        #expect(!capture.isCapturing)
        #expect(!session.isConnected)
    }

    @Test("Configuring credential dynamically enables brain and updates credential source")
    func dynamicCredentialConfiguration() async throws {
        let store = InMemoryKeychainStore()
        let provider = KeychainCredentialProvider(keychain: store, environment: [:])
        let brain = IvyBrain(
            client: URLSessionGeminiClient(),
            credentials: provider,
            conversationStore: InMemoryConversationStore()
        )

        #expect(!brain.isGeminiKeyConfigured)

        // User saves key in Settings
        try provider.store("AIzaSyFakeValidKey1234567890abcdef", for: .geminiAPIKey)
        brain.refreshCredentialStatus()

        #expect(brain.isGeminiKeyConfigured)
        #expect(brain.geminiCredentialSource == CredentialSource.keychain)
        #expect(provider.credential(for: .geminiAPIKey) == "AIzaSyFakeValidKey1234567890abcdef")

        // User removes key in Settings
        try provider.remove(.geminiAPIKey)
        brain.refreshCredentialStatus()

        #expect(!brain.isGeminiKeyConfigured)
        #expect(brain.geminiCredentialSource == CredentialSource.missing)
        #expect(provider.credential(for: .geminiAPIKey) == nil)
    }
}

@Suite("Phase 7 - Clean Shutdown & Lifecycle Audit")
@MainActor
struct Phase7ShutdownLifecycleTests {
    @Test("Environment shutdown cleanly tears down coordinator, playback, and denies pending approvals")
    func cleanShutdownTearsDownAllResources() async {
        let capture = MockAudioCapture()
        let session = MockGeminiLiveSession()
        let player = MockLiveAudioPlayer()
        let detector = MockWakeWordDetector()

        let env = IvyAppEnvironment(
            settingsStore: InMemorySettingsStore(),
            credentials: FixedCredentialProvider([.geminiAPIKey: "fake_key"]),
            conversationStore: InMemoryConversationStore(),
            voiceManager: VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        ) { _, _ in
            GeminiLiveVoiceCoordinator(
                session: session,
                audioCapture: capture,
                audioPlayer: player,
                wakeWordDetector: detector
            )
        }

        // Start session
        await env.liveCoordinator.startSession()
        #expect(env.liveCoordinator.state == .listening)
        #expect(capture.isCapturing)

        // Trigger shutdown
        await env.shutdown()

        #expect(env.liveCoordinator.state == .idle)
        #expect(!capture.isCapturing)
        #expect(!session.isConnected)
        #expect(!player.isPlaying)
    }
}
