const heading = document.querySelector("#heading");
const description = document.querySelector("#description");
const pairing = document.querySelector("#pairing");
const code = document.querySelector("#code");
const primary = document.querySelector("#primary");
const refresh = document.querySelector("#refresh");
const settings = document.querySelector("#settings");
const errorText = document.querySelector("#error");
let next;
let busy = false;

async function send(type, body = {}) {
    const response = await browser.runtime.sendMessage({ type, ...body });
    if (!response || response.error) {
        const error = new Error(response?.error ?? "Riptide couldn’t reach the extension.");
        error.status = response?.status;
        throw error;
    }
    return response;
}

function setError(message = "") {
    errorText.textContent = message;
    errorText.hidden = !message;
}

function action(label, type, body = {}) {
    next = { type, body };
    primary.textContent = label;
    primary.hidden = false;
}

async function render() {
    next = undefined;
    primary.hidden = true;
    try {
        const state = await send("status");
        settings.hidden = !state.paired;
        pairing.hidden = !!state.paired;
        refresh.hidden = !state.paired || state.sharing;
        if (!state.paired) {
            heading.textContent = "Connect your agent";
            description.textContent = "Paste the one-time pairing code from your Riptide Safari relay.";
        } else if (state.sharing) {
            heading.textContent = "Agent is in control";
            description.textContent = new URL(state.handoff.origin).host + " is shared. Keep this Safari tab open.";
            action("Take back control", "release");
        } else if (state.handoff?.active) {
            heading.textContent = "Handoff ended on this phone";
            description.textContent = "Wait for the relay to release the old tab, then request a new handoff.";
        } else if (state.handoff) {
            heading.textContent = new URL(state.handoff.origin).host;
            description.textContent = state.matchingTab
                ? "Finish signing in before you share this tab with your agent."
                : "Open the requested website in Safari and sign in.";
            action(state.matchingTab ? "Hand back" : "Open sign-in page",
                state.matchingTab ? "grant" : "open", { id: state.handoff.id });
        } else {
            heading.textContent = "Ready for a handoff";
            description.textContent = "Ask your agent to request a Safari handoff, then check here.";
        }
    } catch (error) {
        heading.textContent = "Relay unavailable";
        description.textContent = "Check that your phone can reach the private agent host.";
        if (error.status === 401) description.textContent = "Disconnect and pair this Safari extension again.";
        settings.hidden = false;
        refresh.hidden = false;
        setError(error.message);
    }
}

async function perform(operation) {
    if (busy) return;
    busy = true;
    for (const button of document.querySelectorAll("button")) button.disabled = true;
    setError();
    try {
        await operation();
    } catch (error) {
        await render();
        setError(error.message);
    } finally {
        busy = false;
        for (const button of document.querySelectorAll("button")) button.disabled = false;
    }
}

pairing.addEventListener("submit", event => {
    event.preventDefault();
    void perform(async () => {
        await send("pair", { code: code.value });
        code.value = "";
        await render();
    });
});

primary.addEventListener("click", () => {
    if (!next) return;
    void perform(async () => {
        const { type, body } = next;
        await send(type, body);
        if (type === "open") window.close();
        else await render();
    });
});

refresh.addEventListener("click", () => void perform(render));
document.querySelector("#disconnect").addEventListener("click", () => {
    void perform(async () => {
        await send("forget");
        await render();
    });
});

void perform(render);
