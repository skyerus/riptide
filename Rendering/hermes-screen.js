import RFB from "@novnc/novnc";

const bridge = window.webkit.messageHandlers.hermesScreen;
const keyboard = document.getElementById("keyboard");
const keys = document.getElementById("keys");
const screen = document.getElementById("screen");
let sentKeys = "";

// noVNC accepts a channel as well as a URL. Riptide carries this channel over SSH.
const channel = {
  readyState: "connecting", binaryType: "arraybuffer", protocol: "",
  onopen: null, onclose: null, onmessage: null, onerror: null,
  send(bytes) {
    bridge.postMessage({ frame: btoa(String.fromCharCode(...bytes)) });
  },
  close() { this.readyState = "closed"; }
};

const rfb = new RFB(screen, channel);
rfb.scaleViewport = true;
rfb.resizeSession = false;
rfb.background = "#101114";
rfb.viewOnly = true;
rfb.addEventListener("connect", () => bridge.postMessage("connected"));
rfb.addEventListener("disconnect", () => bridge.postMessage("disconnected"));

window.hermesScreen = {
  open() {
    channel.readyState = "open";
    channel.onopen();
  },
  frame(data) {
    const bytes = Uint8Array.from(atob(data), character => character.charCodeAt(0));
    channel.onmessage({ data: bytes.buffer });
  },
  control(allowed) {
    rfb.viewOnly = !allowed;
    keyboard.hidden = !allowed;
    if (!allowed) keys.blur();
  }
};

keyboard.addEventListener("click", () => keys.focus());
keys.addEventListener("blur", () => {
  sentKeys = "";
  keys.value = "";
});

function sendTypedKeys() {
  if (rfb.viewOnly) return;
  // Keep WebKit's editing buffer intact between events so its software keyboard
  // can apply successive edits and composition against the same input state.
  const previous = Array.from(sentKeys);
  const next = Array.from(keys.value);
  let shared = 0;
  while (shared < previous.length && shared < next.length && previous[shared] === next[shared]) shared++;
  for (let index = shared; index < previous.length; index++) rfb.sendKey(0xff08, "Backspace");
  for (const character of next.slice(shared)) {
    const code = character.codePointAt(0);
    rfb.sendKey(code <= 0xff ? code : 0x01000000 | code);
  }
  sentKeys = keys.value;
  keys.setSelectionRange(sentKeys.length, sentKeys.length);
}

keys.addEventListener("input", event => {
  if (!event.isComposing) sendTypedKeys();
});
keys.addEventListener("compositionend", sendTypedKeys);
keys.addEventListener("keydown", event => {
  if (rfb.viewOnly || event.isComposing) return;
  if (event.key === "Enter") {
    event.preventDefault();
    rfb.sendKey(0xff0d, "Enter");
    sentKeys = "";
    keys.value = "";
  } else if (event.key === "Backspace" && keys.value === "") {
    event.preventDefault();
    rfb.sendKey(0xff08, "Backspace");
  }
});

// Give noVNC one turn to attach its raw-channel event handlers.
setTimeout(() => bridge.postMessage("ready"), 0);
