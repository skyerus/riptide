import RiptideCore
import SwiftUI

@MainActor
@Observable
final class SafariChatApproval {
    private let relay = SafariSSHRelay()
    private(set) var pending: SafariChatHandoff?
    private var message: String?
    var status: String? {
        message ?? pending.map { _ in "After signing in, send “I’ve signed in” here." }
    }

    func restore(agentID: UUID?, chatID: String) {
        pending = nil
        message = nil
        guard let store = SafariSSHKeychain(), let handoff = try? SafariChatHandoff.load(from: store),
              handoff.agentID == agentID, handoff.chatID == chatID, handoff.expires > .now,
              handoff.resumeToken == nil else { return }
        pending = handoff
    }

    func launchURL(for url: URL, agent: SafariSSHAgent, chatID: String,
                   stillInChat: () -> Bool) async -> URL? {
        guard let store = SafariSSHKeychain(),
              let request = try? await SafariChatHandoff.Request.pending(on: relay, agent: agent),
              request.url == url, !Task.isCancelled, stillInChat() else { return nil }
        let handoff = SafariChatHandoff(request: request, agentID: agent.profile.id, chatID: chatID)
        guard let marked = handoff.launchURL else { return nil }
        do {
            try handoff.save(to: store)
            pending = handoff
            message = nil
            return marked
        } catch {
            message = "Couldn’t prepare Safari handoff. You can still share from Safari’s Riptide menu."
            return nil
        }
    }

    func handles(_ text: String, agentID: UUID?, chatID: String) -> Bool {
        guard let pending, pending.agentID == agentID, pending.chatID == chatID else { return false }
        return SafariChatHandoff.isConfirmation(text)
    }

    func approve() -> URL? {
        guard let pending else { return nil }
        do {
            guard let store = SafariSSHKeychain(),
                  let saved = try SafariChatHandoff.load(from: store), saved == pending, saved.expires > .now else {
                self.pending = nil
                message = "That Safari handoff expired. Ask for a new link."
                return nil
            }
            guard try saved.isBound(in: store) else {
                message = "In Safari, open Riptide and enable chat handoff for this site, then reopen the chat link."
                return nil
            }
            var handoff = saved
            handoff.approve()
            guard let url = handoff.resumeURL else { return nil }
            try handoff.save(to: store)
            self.pending = nil
            message = nil
            return url
        } catch {
            message = "Couldn’t pass your approval to Safari. Try again or use the Riptide menu in Safari."
            return nil
        }
    }
}
