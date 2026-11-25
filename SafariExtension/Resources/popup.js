const heading = document.querySelector("#heading");
const description = document.querySelector("#description");
const agentPicker = document.querySelector("#agent-picker");
const agentSelect = document.querySelector("#agent");
const primary = document.querySelector("#primary");
const refresh = document.querySelector("#refresh");
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
        const selected = state.agents.find(agent => agent.id === state.agentID);
        agentPicker.hidden = state.agents.length < 2 || !!state.sharing || !!state.canRelease;
        agentSelect.replaceChildren(...state.agents.map(agent => new Option(agent.name, agent.id)));
        if (selected) agentSelect.value = selected.id;
        refresh.hidden = !!state.sharing || !!state.canRelease;
        if (!selected) {
            heading.textContent = "Pair an agent in Riptide";
            description.textContent = "Open Riptide to use an existing SSH pairing or connect an agent.";
        } else if (state.connectionError) {
            heading.textContent = "Relay unavailable";
            description.textContent = selected.name;
            setError(state.connectionError);
            if (state.canRelease) action("Take back control", "release");
        } else if (state.sharing) {
            heading.textContent = "Agent is in control";
            description.textContent = new URL(state.handoff.origin).host + " is shared. Keep this Safari tab open.";
            action("Take back control", "release");
        } else if (state.busy || state.handoff?.active) {
            heading.textContent = "A tab is already shared";
            description.textContent = "Take back control on the device sharing the tab or ask your agent to finish.";
        } else if (state.handoff) {
            heading.textContent = new URL(state.handoff.origin).host;
            description.textContent = state.matchingTab
                ? "Finish signing in before you share this tab with your agent."
                : "Open the requested website in Safari and sign in.";
            action(state.matchingTab ? "Hand back" : "Open sign-in page",
                state.matchingTab ? "grant" : "open", { id: state.handoff.id });
        } else {
            heading.textContent = "Ready for a handoff";
            description.textContent = "Ask " + selected.name + " to request a Safari handoff, then check here.";
        }
    } catch (error) {
        heading.textContent = "Pairings unavailable";
        description.textContent = "Open Riptide to refresh your agent connections.";
        agentPicker.hidden = true;
        refresh.hidden = false;
        setError(error.message);
    }
}

async function perform(operation) {
    if (busy) return;
    busy = true;
    for (const button of document.querySelectorAll("button, select")) button.disabled = true;
    setError();
    try {
        await operation();
    } catch (error) {
        await render();
        setError(error.message);
    } finally {
        busy = false;
        for (const button of document.querySelectorAll("button, select")) button.disabled = false;
    }
}

agentSelect.addEventListener("change", () => void perform(async () => {
    await send("select", { id: agentSelect.value });
    await render();
}));

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
void perform(render);
