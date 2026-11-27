import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const viewer = readFileSync(new URL("./hermes-screen.js", import.meta.url), "utf8")
  .replace(/^import RFB.*\n/, "");

function openViewer() {
  const sizes = [];
  const events = [];
  let resize;
  let observeCanvas;
  const canvas = { width: 1280, height: 800 };
  const element = { addEventListener() {}, blur() {} };
  const screen = { ...element, clientWidth: 390, clientHeight: 600, querySelector: () => canvas };
  const window = { webkit: { messageHandlers: { hermesScreen: { postMessage: event => events.push(event) } } } };
  runInNewContext(viewer, {
    window,
    document: { getElementById: id => id === "screen" ? screen : element },
    RFB: class {
      static messages = { setDesktopSize: (_socket, width, height) => sizes.push([width, height]) };
      _supportsSetDesktopSize = true;
      addEventListener() {}
    },
    ResizeObserver: class {
      constructor(callback) { resize = callback; }
      observe() {}
    },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; }
      observe() { observeCanvas = this.callback; }
      disconnect() {}
    },
    setTimeout,
    clearTimeout,
  });
  return {
    control: window.hermesScreen.control,
    prepareHandback: window.hermesScreen.prepareHandback,
    sizes,
    events,
    viewport(width, height) {
      Object.assign(screen, { clientWidth: width, clientHeight: height });
      resize();
    },
    framebuffer(width, height) {
      Object.assign(canvas, { width, height });
      observeCanvas();
    },
  };
}

test("keyboard viewport changes do not resize the desktop during takeover", () => {
  const viewer = openViewer();
  viewer.control(true, 512);
  viewer.framebuffer(512, 788);
  assert.ok(viewer.events.includes("fit"));

  viewer.viewport(390, 325); // The iPhone keyboard opens.
  viewer.viewport(390, 600); // It closes.
  assert.deepEqual(viewer.sizes, [[512, 788]]);
});

test("handback restores the desktop and the next takeover fits the current phone viewport", async () => {
  const viewer = openViewer();
  viewer.control(true, 512);
  viewer.framebuffer(512, 788);
  const handback = viewer.prepareHandback();
  viewer.framebuffer(1280, 800);
  await handback;
  viewer.control(false);
  viewer.viewport(600, 390);
  viewer.control(true, 512);
  assert.deepEqual(viewer.sizes, [[512, 788], [1280, 800], [600, 390]]);
});
