class RelayError extends Error {
    constructor(message, status) {
        super(message);
        this.status = status;
    }
}

function originOf(url) {
    try {
        const parsed = new URL(url);
        return parsed.protocol === "https:" && !parsed.username && !parsed.password ? parsed.origin : null;
    } catch {
        return null;
    }
}

async function relay(agentID, operation, body = {}) {
    const reply = await browser.runtime.sendNativeMessage("app.riptide.client", { agentID, operation, body });
    if (reply?.status === 200) return reply.body;
    throw new RelayError(reply?.body?.error ?? reply?.error ?? "Riptide couldn’t reach the relay.", reply?.status);
}

async function currentTab() {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    return tab;
}

async function sharedTab() {
    return (await browser.storage.session.get("share")).share;
}

async function stopSharing(share) {
    if ((await sharedTab())?.id !== share.id) return;
    await browser.storage.session.remove("share");
    await browser.tabs.sendMessage(share.tabID, { type: "stop", id: share.id }).catch(() => {});
}

async function release(share) {
    await stopSharing(share);
    try {
        await relay(share.agentID, "release", { id: share.id });
    } catch (error) {
        if (![403, 404, 409].includes(error.status)) {
            throw new Error("Control stopped on this phone. The relay will expire the handoff shortly.");
        }
    }
}

async function inject(tabID) {
    const results = await browser.scripting.executeScript({
        target: { tabId: tabID },
        files: ["page.js"]
    });
    if (!results.length) throw new Error("Safari needs permission for this tab.");
}

async function runPopup(message) {
    const share = await sharedTab();
    if (message.type === "release" && share) {
        await release(share);
        return {};
    }

    const { agents } = await relay(undefined, "agents");
    const { selectedAgent } = await browser.storage.local.get("selectedAgent");
    if (message.type === "select") {
        if (share || !agents.some(agent => agent.id === message.id)) {
            throw new Error("Choose a paired agent after ending the current handoff.");
        }
        await browser.storage.local.set({ selectedAgent: message.id });
        return {};
    }
    const agentID = share?.agentID ?? agents.find(agent => agent.id === selectedAgent)?.id ?? agents[0]?.id;
    if (!agentID) return { agents };
    if (!agents.some(agent => agent.id === agentID)) {
        if (share) await stopSharing(share);
        return { agents };
    }

    let state;
    try {
        state = await relay(agentID, "state");
    } catch (error) {
        if (message.type !== "status") throw error;
        if (share && error.status === 404) await stopSharing(share);
        return { agents, agentID, connectionError: error.message, canRelease: !!share };
    }
    const { handoff, busy } = state;
    if (share && handoff?.id !== share.id) await stopSharing(share);
    const tab = await currentTab();
    const matchingTab = !!handoff && originOf(tab?.url) === handoff.origin;

    if (message.type === "status") {
        const sharing = !!share && handoff?.id === share.id;
        return { agents, agentID, handoff, busy, matchingTab, sharing };
    }
    if (!handoff || handoff.active || handoff.id !== message.id) {
        throw new Error("This request has changed. Check for a new handoff.");
    }
    if (message.type === "open") {
        await browser.tabs.create({ url: handoff.url });
        return {};
    }
    if (message.type === "grant") {
        if (!matchingTab || !Number.isInteger(tab?.id)) {
            throw new Error("Switch to the site requested by your agent before handing back.");
        }
        const probe = await browser.scripting.executeScript({
            target: { tabId: tab.id },
            func: () => location.origin
        });
        if (probe.length !== 1 || probe[0].result !== handoff.origin) {
            throw new Error("Allow Riptide access to this Safari tab and try again.");
        }
        const nextShare = { id: handoff.id, origin: handoff.origin, tabID: tab.id, agentID };
        await relay(agentID, "grant", { id: nextShare.id, origin: nextShare.origin });
        try {
            await browser.storage.session.set({ share: nextShare });
            await inject(tab.id);
        } catch {
            await release(nextShare);
            throw new Error("Safari couldn’t start sharing. Ask your agent for a fresh handoff.");
        }
        return {};
    }
    throw new Error("Unknown Riptide action.");
}

async function tick(message, sender) {
    const share = await sharedTab();
    if (!share?.agentID || sender.frameId !== 0 || sender.tab?.id !== share.tabID ||
        originOf(sender.url) !== share.origin) {
        return { stopped: true };
    }
    const body = { id: share.id, origin: share.origin };
    try {
        const result = message.result
            ? await relay(share.agentID, "result", { ...message.result, ...body })
            : await relay(share.agentID, "next", body);
        if ((await sharedTab())?.id !== share.id) return { stopped: true };
        return { share, ...result };
    } catch (error) {
        if ([403, 404, 409].includes(error.status)) {
            await stopSharing(share);
            return { stopped: true };
        }
        throw error;
    }
}

browser.runtime.onMessage.addListener((message, sender, respond) => {
    const isPopup = sender.url === browser.runtime.getURL("popup.html");
    const popupActions = ["status", "select", "open", "grant", "release"];
    const action = message?.type === "tick" ? tick(message, sender)
        : isPopup && popupActions.includes(message?.type) ? runPopup(message) : null;
    if (!action) return false;
    action.then(result => respond(result), error => respond({ error: error.message, status: error.status }));
    return true;
});

browser.tabs.onUpdated.addListener((tabID, update, tab) => {
    if (!update.url && update.status !== "complete") return;
    void (async () => {
        const share = await sharedTab();
        if (share?.tabID !== tabID) return;
        const origin = originOf(update.url ?? tab.url);
        if (origin && origin !== share.origin) {
            await release(share);
        } else if (update.status === "complete") {
            await inject(tabID);
        }
    })().catch(() => {});
});

browser.tabs.onRemoved.addListener(tabID => {
    void (async () => {
        const share = await sharedTab();
        if (share?.tabID !== tabID) return;
        await release(share);
    })().catch(() => {});
});

browser.runtime.onInstalled.addListener(() => { void browser.storage.local.remove("pairing"); });
