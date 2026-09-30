import Foundation
import AVFoundation
import Speech
import EventKit
import Contacts
import UserNotifications
import ApplicationServices
import CoreGraphics
import os

/// The system privacy permissions required by Ivy's features.
public enum PermissionType: String, CaseIterable, Sendable {
    /// Microphone input for Gemini Live voice streaming.
    case microphone
    /// Speech recognition for "Hey Ivy" wake phrase detection.
    case speechRecognition
    /// Calendar access for creating schedule events.
    case calendar
    /// AppleEvents automation for AppleScript tool execution.
    case automation
    /// Reminders, for the `reminders` tool.
    case reminders
    /// Contacts, for the `contacts` tool.
    case contacts
    /// Screen recording, for the `screenshot` tool.
    case screenRecording
    /// Accessibility, for moving and resizing windows.
    case accessibility
    /// Local notifications, for the `notify` tool.
    case notifications

    public var displayName: String {
        switch self {
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .calendar: return "Calendar"
        case .automation: return "Automation"
        }
    }

    /// Deep link to this permission's pane in System Settings › Privacy & Security.
    public var settingsURL: URL? {
        let anchor: String
        switch self {
        case .reminders: anchor = "Privacy_Reminders"
        case .contacts: anchor = "Privacy_Contacts"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .calendar: anchor = "Privacy_Calendars"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// The authorization state of a macOS privacy permission.
public enum PermissionState: String, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unsupported
}

/// Abstract interface for querying and requesting macOS permissions.
public protocol PermissionManaging: Sendable {
    /// Current authorization status without prompting the user.
    func status(for type: PermissionType) -> PermissionState
    /// Asynchronously requests authorization from the user if not yet determined.
    func requestPermission(for type: PermissionType) async -> PermissionState
}

/// Production implementation of PermissionManaging querying macOS subsystem APIs.
public struct SystemPermissionManager: PermissionManaging {
    public init() {}

    public func status(for type: PermissionType) -> PermissionState {
        switch type {
        case .microphone:
            return Self.microphoneStatus()
        case .speechRecognition:
            return Self.speechStatus()
        case .calendar:
            return Self.calendarStatus()
        case .automation:
            // macOS does not provide a general pre-flight API for AppleEvents; it prompts on first event.
            return .notDetermined
        case .reminders:
            return Self.eventKitState(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .authorized : .notDetermined
        case .notifications:
            // The notification centre only answers asynchronously; `requestPermission` reports the real state.
            return .notDetermined
        }
    }

    private static func eventKitState(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .fullAccess: return .authorized
        case .writeOnly, .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestPermission(for type: PermissionType) async -> PermissionState {
        switch type {
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .authorized : .denied

        case .speechRecognition:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authStatus in
                    switch authStatus {
                    case .authorized:
                        continuation.resume(returning: .authorized)
                    case .denied:
                        continuation.resume(returning: .denied)
                    case .restricted:
                        continuation.resume(returning: .restricted)
                    case .notDetermined:
                        continuation.resume(returning: .notDetermined)
                    @unknown default:
                        continuation.resume(returning: .denied)
                    }
                }
            }

        case .calendar:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                do {
                    let granted = try await store.requestFullAccessToEvents()
                    return granted ? .authorized : .denied
                } catch {
                    return .denied
                }
            } else {
                do {
                    let granted = try await store.requestAccess(to: .event)
                    return granted ? .authorized : .denied
                } catch {
                    return .denied
                }
            }

        case .automation:
            return .notDetermined

        case .reminders:
            do {
                return try await EKEventStore().requestFullAccessToReminders() ? .authorized : .denied
            } catch {
                return .denied
            }

        case .contacts:
            do {
                return try await CNContactStore().requestAccess(for: .contacts) ? .authorized : .denied
            } catch {
                return .denied
            }

        case .screenRecording:
            // Shows the system prompt the first time; access only takes effect after the user allows it.
            return CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() ? .authorized : .denied

        case .accessibility:
            // The literal value of kAXTrustedCheckOptionPrompt (a global the concurrency checker rejects).
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied

        case .notifications:
            // The notification centre traps in a process without a bundle (`swift run`, tests).
            guard Bundle.main.bundleURL.pathExtension == "app" else { return .unsupported }
            do {
                return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) ? .authorized : .denied
            } catch {
                return .denied
            }
        }
    }

    // MARK: - Status Queries

    private static func microphoneStatus() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func speechStatus() -> PermissionState {
        guard SFSpeechRecognizer(locale: Locale(identifier: "en-US")) != nil else {
            return .unsupported
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func calendarStatus() -> PermissionState {
        let status: EKAuthorizationStatus
        if #available(macOS 14.0, *) {
            status = EKEventStore.authorizationStatus(for: .event)
        } else {
            status = EKEventStore.authorizationStatus(for: .event)
        }
        switch status {
        case .authorized, .fullAccess, .writeOnly: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// In-memory permission manager for deterministic unit testing.
public final class MockPermissionManager: PermissionManaging, @unchecked Sendable {
    private struct State {
        var statuses: [PermissionType: PermissionState] = [:]
        var requestResponses: [PermissionType: PermissionState] = [:]
        var requestedTypes: [PermissionType] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(initialStatuses: [PermissionType: PermissionState] = [:]) {
        state.withLock { $0.statuses = initialStatuses }
    }

    public func setStatus(_ state: PermissionState, for type: PermissionType) {
        self.state.withLock { $0.statuses[type] = state }
    }

    public func setRequestResponse(_ state: PermissionState, for type: PermissionType) {
        self.state.withLock { $0.requestResponses[type] = state }
    }

    public var requestedTypes: [PermissionType] {
        state.withLock { $0.requestedTypes }
    }

    public func status(for type: PermissionType) -> PermissionState {
        state.withLock { $0.statuses[type] ?? .notDetermined }
    }

    public func requestPermission(for type: PermissionType) async -> PermissionState {
        state.withLock { s -> PermissionState in
            s.requestedTypes.append(type)
            let result = s.requestResponses[type] ?? .authorized
            s.statuses[type] = result
            return result
        }
    }
}
