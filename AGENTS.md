# Riptide project instructions

## Chat intent

- Never infer user intent or trigger a workflow by matching words or phrases in chat messages. Pass natural-language messages to the agent and handle its decisions through structured tool calls or protocol events. Require explicit UI actions for consent where the app must verify it independently.

## UI changes

- For every user-visible UI change, run the updated app on an iPhone simulator or device, capture the changed screens or states, and include the screenshots in the final reply. Attach or embed the images; a description or local path alone is not enough.
- Use fixture or sanitized data in screenshots. Keep captures out of Git unless requested. If capture is blocked, say why rather than substituting a mockup for the running app.
