(() => {
    // Only URLs opened by Riptide carry a marker. Strip it before the site's scripts run.
    const match = /^#riptide-handoff=([a-f0-9-]{36})&(.*)$/i.exec(location.hash);
    if (!match || window.top !== window) return;
    const [, token, fragment] = match;
    const clean = new URL(location.href);
    clean.hash = fragment ? "#" + fragment : "";
    try {
        history.replaceState(history.state, "", clean.href);
    } finally {
        void browser.runtime.sendMessage({ type: "chat-tab", token }).catch(() => {});
    }
})();
