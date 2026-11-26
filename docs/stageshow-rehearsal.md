# Riptide UI rehearsal

Stageshow 1.1.1 is vendored from [benjitaylor/skills at 299140f](https://github.com/benjitaylor/skills/tree/299140fafd08df55a9c234e610c3f64af3f45531/stageshow). The React kit and its example assets stay outside the app target.

## References

- **Dark hero:** Use graphite surface steps, not outlines or shadows, to distinguish the active connector, search field, and main chat. Reserve Forged green for selection and activity, and amber for requests.
- **AI chat:** Keep the reply and its formatting in place while it streams. Keep one progress cue for the current action; an approval card or a running tool row already tells the reader what is happening.
- **Swipe:** Use real native scrolling and shorter rows for scanning. Keep the tab strip, Inbox searches, and chat scroll position attached to their existing navigation state.

## Chats sheet

The Dark hero reference informed the graphite surface steps and the current-chat marker. Swipe informed the compact rows and native sheet. The compact sheet keeps search and New chat beside one another, then expands when search gets focus.

On both simulator sizes, open Chats from Main Chat, filter for a side chat, clear the query, then switch to the side chat and back. Check the empty catalog, an unmatched search and the create flow. Use `AgentChatsUITests.testChatPickerSearchesAndSwitchesBetweenMainAndSideChat` to capture the resting sheet and the focused search.

## Agent pairing

The AI cards reference informed the in-thread invitation, progress on the primary action, and the compact record of each decision. The invitation puts the agent first and uses the existing graphite surface and green action. The card owns the waiting state while it is visible.

Run `AgentChatsUITests.testPairingCardsShowProgressRetryAndKeepDecisionsInTheChat` on iPhone 17e and iPhone 18 Pro. The fixture walks through the first invitation, connecting, retrying, the second invitation, and both decisions. Inspect the card and both tap targets at each width. The fixture exercises the native chat UI and structured permissions with simulated enrollment.

## Native checks

Walk through Inbox → an approval → Back, then a connector → Main Chat → a live reply. Inspect the busy Inbox, the agent's main and saved chats, the composer with and without model controls, live progress, and the finished transcript. Check the iPhone 18 Pro and the narrower iPhone 17e at its native width. Fixtures supply all data.

Use `WorkspaceUXUITests` and `AgentChatsUITests` for the native flow, including taking a finger off the transcript, reading older content during a reply, and switching away while an approval is pending. Attached simulator frames replace Stageshow's browser-only film gate; this is not a scripted web demo. Physical-device accessibility, real backend connections, and distribution are separate checks.
