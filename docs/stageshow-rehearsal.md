# Riptide UI rehearsal

Stageshow 1.1.1 is vendored from [benjitaylor/skills at 299140f](https://github.com/benjitaylor/skills/tree/299140fafd08df55a9c234e610c3f64af3f45531/stageshow). The React kit and its example assets stay outside the app target.

## References

- **Dark hero:** Use graphite surface steps, not outlines or shadows, to distinguish the active connector, search field, and main chat. Reserve Forged green for selection and activity, and amber for requests.
- **AI chat:** Keep the reply and its formatting in place while it streams. Keep one progress cue for the current action; an approval card or a running tool row already tells the reader what is happening.
- **Swipe:** Use real native scrolling and shorter rows for scanning. Keep the tab strip, Inbox searches, and chat scroll position attached to their existing navigation state.

## Native checks

Walk through Inbox → an approval → Back, then a connector → Main Chat → a live reply. Inspect the busy Inbox, the agent's main and saved chats, the composer with and without model controls, live progress, and the finished transcript. Check the iPhone 18 Pro and the narrower iPhone 17e at its native width. Fixtures supply all data.

Use `WorkspaceUXUITests` and `AgentChatsUITests` for the native flow, including taking a finger off the transcript, reading older content during a reply, and switching away while an approval is pending. Attached simulator frames replace Stageshow's browser-only film gate; this is not a scripted web demo. Physical-device accessibility, real backend connections, and distribution are separate checks.
