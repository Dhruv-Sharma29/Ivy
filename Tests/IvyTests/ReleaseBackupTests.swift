import Foundation
import Testing
@testable import IvyCore

private struct BackupFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ivy-backup-" + UUID().uuidString)
        suite = "ivy.backup.tests." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    func write(_ text: String, _ name: String) throws {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
    var backup: ReleaseDataBackup { ReleaseDataBackup(directory: directory, defaults: defaults) }
}

private final class FailingBackupFiles: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

@Suite("Release integration — one-time rollback backup")
struct ReleaseBackupTests {
    @Test("durable stores and exact settings are secured before decoding, without copying cache, captures or credentials")
    func backup() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        try fixture.write("v1 history", "Conversations/history.json")
        try fixture.write("task", "Tasks/task.json")
        try fixture.write("proactive", "Proactive/state.json")
        try fixture.write("profile", "profile.json")
        try fixture.write("workspaces", "workspaces.json")
        try fixture.write("pixels", "Screenshots/ignored.png")
        try fixture.write("audio", "Cache/ignored.pcm")
        let settings = Data(#"{"pushToTalkEnabled":false}"#.utf8)
        fixture.defaults.set(settings, forKey: UserDefaultsSettingsStore.storageKey)
        fixture.defaults.set("fixture-keychain-is-not-exported", forKey: "unrelated-credential")
        let destination = try #require(try fixture.backup.prepare())
        #expect(destination.lastPathComponent == "1.0")
        #expect(try String(contentsOf: destination.appendingPathComponent("Conversations/history.json"), encoding: .utf8) == "v1 history")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("settings.plist")), format: nil) as? [String: Any])
        #expect(plist.count == 1 && plist[UserDefaultsSettingsStore.storageKey] as? Data == settings)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Screenshots").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Cache").path))
        for path in ["", "Conversations", "Tasks", "Proactive"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(path).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("settings.plist").path)
        #expect((mode[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try fixture.write("new history", "Conversations/history.json")
        #expect(try fixture.backup.prepare() == nil)
        #expect(try String(contentsOf: destination.appendingPathComponent("Conversations/history.json"), encoding: .utf8) == "v1 history")
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("release-data-version.json"))
        #expect(try fixture.backup.prepare() == destination, "a completed backup survives a crash before the version marker")
    }

    @Test("fresh installs mark the current release without treating subsequently created history as v1.0")
    func freshInstall() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        #expect(try fixture.backup.prepare() == nil)
        try fixture.write("v1.1 history", "Conversations/history.json")
        #expect(try fixture.backup.prepare() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Backups/1.0").path))
        let settings = TemporarySettingsStore()
        var edited = settings.load()
        edited.pushToTalkEnabled = false
        try settings.save(edited)
        #expect(settings.load().pushToTalkEnabled == false)
        let history = TemporaryConversationStore()
        var conversation = Conversation()
        #expect(throws: ConversationStoreError.self) { try history.update(conversation) }
        try history.save(conversation)
        #expect(history.load(conversation.id) == conversation)
        conversation.title = "Temporary"
        try history.update(conversation)
        #expect(history.list().first?.title == "Temporary")
        try history.delete(conversation.id)
        try history.delete(conversation.id)
        #expect(history.list().isEmpty)

    }

    @Test("failure removes incomplete staging and cannot modify or migrate original data")
    func failedCopy() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        try fixture.write("original", "Conversations/history.json")
        let backup = ReleaseDataBackup(directory: fixture.directory, defaults: fixture.defaults, files: FailingBackupFiles())
        #expect(throws: CocoaError.self) { try backup.prepare() }
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("Conversations/history.json"), encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("Backups").path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("release-data-version.json").path))
        #expect(try fixture.backup.prepare() != nil)
    }

    @Test("symlinks, incomplete backups, unknown markers and invalid manifests are rejected")
    func unsafePaths() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        try fixture.write("outside", "outside.json")
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("profile.json"), withDestinationURL: fixture.directory.appendingPathComponent("outside.json"))
        #expect(throws: ReleaseDataBackup.BackupError.self) { try fixture.backup.prepare() }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("profile.json"))
        try fixture.write("unfinished", "Backups/1.0/incomplete.json")
        #expect(throws: (any Error).self) { try fixture.backup.prepare() }
        try fixture.write(#"{"sourceVersion":"1.0.0","targetVersion":"1.1.0","createdAt":0,"entries":["../outside.json"]}"#, "Backups/1.0/manifest.json")
        #expect(throws: ReleaseDataBackup.BackupError.self) { try fixture.backup.prepare() }
        try fixture.write(#"{"sourceVersion":"1.0.0","targetVersion":"1.1.0","createdAt":0,"entries":["settings.plist"]}"#, "Backups/1.0/manifest.json")
        #expect(throws: ReleaseDataBackup.BackupError.self) { try fixture.backup.prepare() }
        try fixture.write("\"9.0.0\"", "release-data-version.json")
        #expect(throws: ReleaseDataBackup.BackupError.self) { try fixture.backup.prepare() }
    }

    @Test("startup failure presents a visible temporary session instead of opening stores that migrate data")
    @MainActor
    func startupRecovery() async {
        let environment = IvyAppEnvironment.production(credentials: FixedCredentialProvider([:]), prepareBackup: { throw CocoaError(.fileWriteOutOfSpace) })
        #expect(environment.brain.storageNotice?.contains("Existing data is untouched") == true)
        #expect(environment.conversationStore is TemporaryConversationStore)
        #expect(environment.brain.persistsHistory == false && environment.settings.settings.pushToTalkEnabled == false)
        #expect(environment.needsOnboarding == false)
        #expect(environment.liveCoordinator.state == .idle)
        await environment.shutdown()
    }
}
