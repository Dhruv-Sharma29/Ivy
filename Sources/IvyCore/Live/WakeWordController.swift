import Foundation
import Combine

/// What the idle "Hey Ivy" wake-up is doing, for the UI.
public enum WakeWordStatus: Equatable, Sendable {
    case off
    case listening
    /// Paused while a Live session owns the microphone.
    case paused
    case unavailable(String)
}

/// Runs the idle wake-word listener only while Ivy is idle and enabled; on "Hey Ivy" it hands the microphone
/// to a Live wake session, and resumes listening when that session ends.
@MainActor
public final class WakeWordController: ObservableObject {
    @Published public private(set) var status: WakeWordStatus = .off
    /// Called on the main actor when the wake word fires (e.g. to play a chime).
    public var onWake: (() -> Void)?

    private let listener: WakeWordListening
    private let coordinator: GeminiLiveVoiceCoordinator
    private var enabled = false
    private var isListening = false
    /// Set when starting failed (e.g. permission denied): no retry until re-enabled, so the user isn't re-prompted.
    private var failed = false
    private var syncing = false
    private var needsSync = false
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []
    private var stateSubscription: AnyCancellable?

    public init(listener: WakeWordListening, coordinator: GeminiLiveVoiceCoordinator) {
        self.listener = listener
        self.coordinator = coordinator
        stateSubscription = coordinator.$state
            .removeDuplicates { $0.isLive == $1.isLive }
            .sink { [weak self] _ in
                // @Published emits before the value changes; reconcile on the next main-actor turn.
                Task { @MainActor [weak self] in self?.requestSync() }
            }
    }

    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        failed = false
        requestSync()
    }

    /// Quit path: releases the microphone, including one a start still in flight was about to open.
    public func shutdown() async {
        enabled = false
        requestSync()
        while syncing {
            await withCheckedContinuation { syncWaiters.append($0) }
        }
        if isListening {
            isListening = false
            await listener.stop()
        }
        status = .off
    }

    /// Reconciles serially so rapid state changes can never start two taps or leave one running.
    func requestSync() {
        needsSync = true
        guard !syncing else { return }
        syncing = true
        Task { @MainActor in
            while needsSync {
                needsSync = false
                await reconcile()
            }
            syncing = false
            let waiters = syncWaiters
            syncWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func reconcile() async {
        let live = coordinator.state.isLive
        let want = enabled && !live && !failed
        if want && !isListening {
            do {
                try await listener.start { [weak self] in
                    Task { @MainActor [weak self] in await self?.handleWake() }
                }
                isListening = true
                status = .listening
                // Disabled, shut down, or a session began while the start was in flight: release the mic now.
                if !(enabled && !coordinator.state.isLive) {
                    needsSync = true
                }
            } catch {
                failed = true
                status = .unavailable(error.localizedDescription)
            }
        } else if !want && isListening {
            isListening = false
            await listener.stop()
        }
        if !failed {
            status = !enabled ? .off : (isListening ? .listening : .paused)
        }
    }

    private func handleWake() async {
        // The listener already stopped itself to free the microphone.
        isListening = false
        guard enabled, !coordinator.state.isLive else {
            requestSync()
            return
        }
        status = .paused
        print("[WAKE] \"Hey Ivy\" heard while idle; starting a wake session")
        onWake?()
        await coordinator.startWakeSession()
        requestSync() // if the session failed to start, resume listening
    }
}
