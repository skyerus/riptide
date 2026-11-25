(() => {
    if (globalThis.riptideSafariWorker) return;
    globalThis.riptideSafariWorker = true;

    const selector = "a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=link], [contenteditable=true]";
    let references = new Map();
    let snapshotURL;
    let sharedID;
    let previous;
    let timer;
    let stopped = false;

    function short(value, length = 120) {
        return (value ?? "").replace(/\s+/g, " ").trim().slice(0, length);
    }

    function visible(element) {
        return element.getClientRects().length > 0 && getComputedStyle(element).visibility === "visible";
    }

    function protectedField(element) {
        return element instanceof HTMLInputElement && (element.type === "password" ||
            /password|one-time-code|cc-/.test(element.autocomplete));
    }

    function description(element) {
        return short(element.getAttribute("aria-label") || Array.from(element.labels ?? [], item => item.textContent).join(" ")
            || element.innerText || element.placeholder || element.title || element.name);
    }

    function snapshot() {
        const nonce = crypto.randomUUID();
        references = new Map();
        snapshotURL = location.href;
        const controls = [];
        let optionBudget = 40;
        for (const element of document.querySelectorAll(selector)) {
            if (controls.length === 80) break;
            if (!visible(element) || element.matches(":disabled,[aria-disabled=true]") || protectedField(element)) continue;
            const ref = nonce + ":" + controls.length;
            references.set(ref, element);
            const control = { ref, kind: short(element.getAttribute("role") || element.type || element.localName, 24),
                label: description(element) };
            if (element instanceof HTMLSelectElement && optionBudget > 0) {
                control.options = Array.from(element.options).slice(0, Math.min(optionBudget, 12)).map(option => ({
                    label: short(option.text, 60), value: short(option.value, 60)
                }));
                optionBudget -= control.options.length;
            }
            controls.push(control);
        }
        return { url: location.href.slice(0, 2048), title: short(document.title),
            text: document.body?.innerText.slice(0, 12000) ?? "", controls };
    }

    function fill(element, value) {
        const input = element instanceof HTMLInputElement;
        const select = element instanceof HTMLSelectElement;
        const textArea = element instanceof HTMLTextAreaElement;
        if (protectedField(element) || element.readOnly || (input &&
            !["text", "email", "url", "tel", "number", "search"].includes(element.type))) {
            throw new Error("That field requires manual entry.");
        }
        if (select && !Array.from(element.options).some(option => option.value === value && !option.disabled)) {
            throw new Error("That select option is unavailable.");
        }
        if (input || select || textArea) {
            const prototype = input ? HTMLInputElement.prototype : select ? HTMLSelectElement.prototype : HTMLTextAreaElement.prototype;
            Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
        } else if (element.isContentEditable) {
            element.textContent = value;
        } else {
            throw new Error("That element is not an editable field.");
        }
        element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
        element.dispatchEvent(new Event("change", { bubbles: true }));
    }

    function safeTarget(url) {
        const destination = new URL(url, location.href);
        if (destination.origin !== location.origin || destination.username || destination.password) {
            throw new Error("This action leaves the shared site. The user can take over to continue.");
        }
        return destination.href;
    }

    function run(command) {
        if (command.kind === "snapshot") return snapshot();
        if (command.kind === "navigate") {
            const url = safeTarget(command.url);
            return { afterReply: () => location.assign(url) };
        }
        const element = references.get(command.ref);
        if (!element?.isConnected || snapshotURL !== location.href || !visible(element) ||
            element.matches(":disabled,[aria-disabled=true]") || protectedField(element)) {
            throw new Error("That control changed. Take a fresh snapshot.");
        }
        if (command.kind === "read_value" && (element instanceof HTMLInputElement ||
            element instanceof HTMLTextAreaElement) && element.readOnly) {
            return { value: element.value.slice(0, 4096) };
        }
        if (command.kind === "fill") {
            fill(element, command.value);
        } else if (command.kind === "click") {
            const link = element.closest("a[href]");
            if (link) {
                safeTarget(link.href);
                if (link.target && link.target !== "_self") throw new Error("That link opens a new tab.");
            }
            if (element.type === "submit" && element.form) {
                safeTarget(element.getAttribute("formaction") || element.form.action || location.href);
                const target = element.getAttribute("formtarget") || element.form.target;
                if (target && target !== "_self") throw new Error("That form opens a new tab.");
            }
            return { afterReply: () => {
                if (element.isConnected && snapshotURL === location.href) element.click();
            } };
        } else {
            throw new Error("Unknown Safari action.");
        }
        return { ok: true };
    }

    function stop() {
        stopped = true;
        clearTimeout(timer);
        browser.runtime.onMessage.removeListener(receive);
        delete globalThis.riptideSafariWorker;
    }

    function receive(message) {
        if (message.type === "stop" && (!sharedID || sharedID === message.id)) stop();
    }

    async function poll() {
        if (stopped) return;
        if (document.visibilityState === "visible") {
            try {
                const reply = await browser.runtime.sendMessage({ type: "tick", result: previous?.response });
                if (stopped || reply?.stopped) return stop();
                if (reply?.error || !reply?.share) throw new Error("Relay unavailable");
                sharedID = reply.share.id;
                const afterReply = previous?.afterReply;
                previous = undefined;
                // A click can submit a form and unload this script. Acknowledge delivery first.
                if (reply.accepted && afterReply && document.visibilityState === "visible") afterReply();
                if (reply.command && document.visibilityState === "visible") {
                    let result;
                    try {
                        result = run(reply.command);
                    } catch (error) {
                        result = { error: error.message };
                    }
                    const { afterReply, ...output } = result;
                    previous = {
                        afterReply,
                        response: { commandID: reply.command.id, result: afterReply ? { ok: true } : output }
                    };
                }
            } catch {
                // The relay expires an unreachable tab. Keep a result for the next successful poll.
            }
        }
        if (!stopped) timer = setTimeout(poll, previous ? 50 : 650);
    }

    browser.runtime.onMessage.addListener(receive);
    void poll();
})();
