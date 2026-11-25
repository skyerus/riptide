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

async function relay(pairing, operation, body = {}) {
    const reply = await browser.runtime.sendNativeMessage("app.riptide.client", { ...pairing, operation, body });
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

async function release(pairing, share) {
    await stopSharing(share);
    try {
        await relay(pairing, "release", { id: share.id });
    } catch (error) {
        if (![401, 409].includes(error.status)) {
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
    const { pairing } = await browser.storage.local.get("pairing");
    const share = await sharedTab();

    if (message.type === "pair") {
        if (pairing) throw new Error("Disconnect the current relay first.");
        const url = new URL(message.code.trim());
        const token = url.hash.slice(1);
        if (!originOf(url) || url.search || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
            throw new Error("Enter the private HTTPS pairing code from your agent host.");
        }
        url.hash = "";
        const endpoint = url.href.replace(/\/$/, "");
        const result = await relay({ endpoint, token }, "pair");
        await browser.storage.local.set({ pairing: { endpoint, token: result.token } });
        return {};
    }

    if (message.type === "forget") {
        if (share) await stopSharing(share);
        await browser.storage.local.remove("pairing");
        if (pairing) {
            await relay(pairing, "forget").catch(error => {
                if (error.status !== 401) {
                    throw new Error("Disconnected on this phone. Revoke its pairing from the relay if needed.");
                }
            });
        }
        return {};
    }

    if (!pairing) return { paired: false };
    if (message.type === "release" && share) {
        await release(pairing, share);
        return {};
    }

    const { handoff } = await relay(pairing, "state");
    if (share && handoff?.id !== share.id) await stopSharing(share);
    const tab = await currentTab();
    const matchingTab = !!handoff && originOf(tab?.url) === handoff.origin;

    if (message.type === "status") {
        return { paired: true, handoff, matchingTab, sharing: !!share && handoff?.id === share.id };
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
        const nextShare = { id: handoff.id, origin: handoff.origin, tabID: tab.id };
        await relay(pairing, "grant", { id: nextShare.id, origin: nextShare.origin });
        try {
            await browser.storage.session.set({ share: nextShare });
            await inject(tab.id);
        } catch {
            await release(pairing, nextShare);
            throw new Error("Safari couldn’t start sharing. Ask your agent for a fresh handoff.");
        }
        return {};
    }
    throw new Error("Unknown Riptide action.");
}

async function tick(message, sender) {
    const { pairing } = await browser.storage.local.get("pairing");
    const share = await sharedTab();
    if (!pairing || !share || sender.frameId !== 0 || sender.tab?.id !== share.tabID ||
        originOf(sender.url) !== share.origin) {
        return { stopped: true };
    }
    const body = { id: share.id, origin: share.origin };
    try {
        const result = message.result
            ? await relay(pairing, "result", { ...message.result, ...body })
            : await relay(pairing, "next", body);
        if ((await sharedTab())?.id !== share.id) return { stopped: true };
        return { share, ...result };
    } catch (error) {
        if ([401, 403, 409].includes(error.status)) {
            await stopSharing(share);
            return { stopped: true };
        }
        throw error;
    }
}

browser.runtime.onMessage.addListener((message, sender, respond) => {
    const isPopup = sender.url === browser.runtime.getURL("popup.html");
    const popupActions = ["pair", "forget", "status", "open", "grant", "release"];
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
            const { pairing } = await browser.storage.local.get("pairing");
            if (pairing) await release(pairing, share);
        } else if (update.status === "complete") {
            await inject(tabID);
        }
    })().catch(() => {});
});

browser.tabs.onRemoved.addListener(tabID => {
    void (async () => {
        const share = await sharedTab();
        if (share?.tabID !== tabID) return;
        const { pairing } = await browser.storage.local.get("pairing");
        if (pairing) await release(pairing, share);
    })().catch(() => {});
});
