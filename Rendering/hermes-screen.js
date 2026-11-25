import RFB from "@novnc/novnc";

const bridge = window.webkit.messageHandlers.hermesScreen;
const keyboard = document.getElementById("keyboard");
const keys = document.getElementById("keys");
const screen = document.getElementById("screen");
let sentKeys = "";
let desktopSize;
let passwordInput;
let windowFit;
let chromeMinimumWidth = 0;
let requestedSize;

function sendFrame(bytes) {
  bridge.postMessage({ frame: btoa(String.fromCharCode(...bytes)) });
}

// noVNC accepts a channel as well as a URL. Riptide carries this channel over SSH.
const channel = {
  readyState: "connecting", binaryType: "arraybuffer", protocol: "",
  onopen: null, onclose: null, onmessage: null, onerror: null,
  send(bytes) {
    if (passwordInput) {
      for (const byte of bytes) passwordInput.push(byte);
    } else {
      sendFrame(bytes);
    }
  },
  close() { this.readyState = "closed"; }
};

class ScreenRFB extends RFB {
  // noVNC 1.7's automatic resize uses the view's exact dimensions. Keep its
  // negotiated RFB screen ID and flags while allowing a wider framebuffer.
  requestSize(width, height) {
    if (this.viewOnly || !this._supportsSetDesktopSize) return false;
    RFB.messages.setDesktopSize(this._sock, width, height, this._screenID, this._screenFlags);
    return true;
  }
}

const rfb = new ScreenRFB(screen, channel);
rfb.scaleViewport = true;
rfb.background = "#101114";
rfb.viewOnly = true;
rfb.addEventListener("connect", () => bridge.postMessage("connected"));
rfb.addEventListener("disconnect", () => bridge.postMessage("disconnected"));

function fitPortrait() {
  if (!chromeMinimumWidth || !screen.clientWidth || !screen.clientHeight) return;
  const width = Math.max(chromeMinimumWidth, screen.clientWidth);
  const height = Math.round(screen.clientHeight * width / screen.clientWidth);
  if (requestedSize?.width === width && requestedSize?.height === height) return;
  if (rfb.requestSize(width, height)) requestedSize = { width, height };
}

const viewport = new ResizeObserver(fitPortrait);
viewport.observe(screen);

window.hermesScreen = {
  open() {
    channel.readyState = "open";
    channel.onopen();
  },
  frame(data) {
    const bytes = Uint8Array.from(atob(data), character => character.charCodeAt(0));
    channel.onmessage({ data: bytes.buffer });
    if (!requestedSize) fitPortrait();
  },
  control(allowed, minimumWidth = 0) {
    rfb.viewOnly = !allowed;
    keyboard.hidden = !allowed;
    chromeMinimumWidth = allowed ? minimumWidth : 0;
    requestedSize = undefined;
    if (chromeMinimumWidth) {
      const canvas = screen.querySelector("canvas");
      if (canvas) {
        desktopSize = { width: canvas.width, height: canvas.height };
        const fit = () => {
          if (rfb.viewOnly || canvas.width !== requestedSize?.width ||
              canvas.height !== requestedSize.height) return;
          windowFit?.disconnect();
          bridge.postMessage("fit");
        };
        windowFit = new MutationObserver(fit);
        windowFit.observe(canvas, { attributes: true, attributeFilter: ["width", "height"] });
        fitPortrait();
        fit();
      }
    } else if (!allowed) {
      windowFit?.disconnect();
      keys.blur();
    }
  },
  async prepareHandback() {
    windowFit?.disconnect();
    keys.blur();
    chromeMinimumWidth = 0;
    if (rfb.viewOnly || !desktopSize || !requestedSize) return;
    const canvas = screen.querySelector("canvas");
    const { width, height } = desktopSize;
    if (!canvas || (canvas.width === width && canvas.height === height)) return;
    // Restore the desktop while the iPhone still holds the control lease.
    await new Promise(resolve => {
      const finish = () => {
        clearTimeout(timeout);
        observer.disconnect();
        resolve();
      };
      const observer = new MutationObserver(() => {
        if (canvas.width === width && canvas.height === height) finish();
      });
      const timeout = setTimeout(finish, 800);
      observer.observe(canvas, { attributes: true, attributeFilter: ["width", "height"] });
      if (!rfb.requestSize(width, height)) finish();
    });
  },
  typeText(text) {
    if (rfb.viewOnly) return false;
    passwordInput = [];
    try {
      for (const character of text) sendCharacter(character);
      for (let offset = 0; offset < passwordInput.length; offset += 4096) {
        sendFrame(passwordInput.slice(offset, offset + 4096));
      }
      return true;
    } finally {
      passwordInput = undefined;
    }
  }
};

// noVNC maps one-finger drags to selection. Route them to scrolling on phones.
let lastDrag;
for (const phase of ["gesturestart", "gesturemove", "gestureend"]) {
  screen.addEventListener(phase, event => {
    if (rfb.viewOnly || event.detail.type !== "drag") return;
    event.stopPropagation();
    const { clientX, clientY } = event.detail;
    if (phase === "gesturemove" && lastDrag) {
      event.target.dispatchEvent(new WheelEvent("wheel", {
        clientX, clientY, deltaX: lastDrag.x - clientX, deltaY: lastDrag.y - clientY,
        bubbles: true, cancelable: true
      }));
    }
    lastDrag = phase === "gestureend" ? undefined : { x: clientX, y: clientY };
  }, { capture: true });
}

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
  for (const character of next.slice(shared)) sendCharacter(character);
  sentKeys = keys.value;
  keys.setSelectionRange(sentKeys.length, sentKeys.length);
}

function sendCharacter(character) {
  const code = character.codePointAt(0);
  rfb.sendKey(code <= 0xff ? code : 0x01000000 | code);
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
