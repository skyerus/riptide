import RiptideCore
import SwiftUI

@MainActor
@Observable
final class SafariChatApproval {
    private let relay = SafariSSHRelay()
    private(set) var pending: SafariChatHandoff?
    private(set) var errorMessage: String?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    func restore(agentID: UUID?, chatID: String) {
        cancelTurn()
        pending = nil
        errorMessage = nil
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
            cancelTurn()
            pending = handoff
            errorMessage = nil
            return marked
        } catch {
            errorMessage = "Couldn’t prepare Safari handoff. You can still share from Safari’s Riptide menu."
            return nil
        }
    }

    func cancelTurn() {
        turnID = nil
        monitor?.cancel()
        monitor = nil
    }

    func prepareTurn(agent: SafariSSHAgent, chatID: String, stillInChat: @escaping () -> Bool,
                     turnWorking: @escaping () -> Bool, resume: @escaping (URL) -> Void) async {
        guard let pending, pending.agentID == agent.profile.id, pending.chatID == chatID,
              pending.expires > .now, stillInChat(),
              let store = SafariSSHKeychain(), (try? pending.isBound(in: store)) == true else { return }
        cancelTurn()
        let token = UUID()
        turnID = token
        guard (try? await pending.prepareChatTurn(token: token, on: relay, agent: agent)) == true,
              turnID == token, stillInChat(), !Task.isCancelled else { return }
        monitor = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(90)
            while let self, !Task.isCancelled, self.turnID == token, stillInChat(), .now < deadline {
                // Check once after the turn finishes too. The tool may have answered just before the stop event.
                guard let request = try? await SafariChatHandoff.Request.pending(on: self.relay, agent: agent),
                      request.id == pending.requestID,
                      !Task.isCancelled, self.turnID == token, stillInChat() else { return }
                if pending.acceptsConfirmation(request, token: token) {
                    if let url = self.approve(pending) { resume(url) }
                    return
                }
                guard turnWorking() else { return }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    private func approve(_ handoff: SafariChatHandoff) -> URL? {
        guard pending == handoff else { return nil }
        do {
            guard let store = SafariSSHKeychain(),
                  let saved = try SafariChatHandoff.load(from: store), saved == handoff, saved.expires > .now else {
                pending = nil
                errorMessage = "That Safari handoff expired. Ask for a new link."
                return nil
            }
            guard try saved.isBound(in: store) else {
                errorMessage = "In Safari, open Riptide and enable chat handoff for this site, then reopen the chat link."
                return nil
            }
            var handoff = saved
            handoff.approve()
            guard let url = handoff.resumeURL else { return nil }
            try handoff.save(to: store)
            pending = nil
            errorMessage = nil
            return url
        } catch {
            errorMessage = "Couldn’t pass your approval to Safari. Try again or use the Riptide menu in Safari."
            return nil
        }
    }
}
