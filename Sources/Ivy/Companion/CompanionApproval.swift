import Foundation
import IvyCore

/// A snapshot of the exact request being reviewed, not an independent approval queue.
struct CompanionApproval: Identifiable, Equatable {
    let request: ConfirmationRequest
    let isLive: Bool
    var id: UUID { request.id }

    static func pending(chat: ConfirmationRequest?, live: ConfirmationRequest?) -> Self? {
        if let live { return Self(request: live, isLive: true) }
        return chat.map { Self(request: $0, isLive: false) }
    }

    @MainActor
    func respond(approved: Bool, brain: IvyBrain, liveCoordinator: GeminiLiveVoiceCoordinator) {
        if isLive {
            liveCoordinator.respondToPendingConfirmation(id: id, approved: approved)
        } else {
            brain.respondToPendingConfirmation(id: id, approved: approved)
        }
    }
}
