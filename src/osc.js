import { isNativeIOS, NativeOSC, loadPreferences } from "./platform";
import { useSyncExternalStore, useCallback } from "react";
const empty = [];
const messages = new Map(),
  listeners = new Map(),
  statusListeners = new Set(),
  noticeListeners = new Set();
let status = {
    bridge: false,
    configured: false,
    consoleOnline: false,
    udpReady: false,
    error: "",
  },
  socket,
  timer,
  bootstrapped = false;
const queued = new Map();
let flushTimer;
function notify(address) {
  listeners.get(address)?.forEach((fn) => fn());
}
function updateStatus(next) {
  status = { ...status, ...next };
  statusListeners.forEach((fn) => fn());
}
export function notice(message) {
  noticeListeners.forEach((fn) => fn(message));
}
export function subscribeNotice(fn) {
  noticeListeners.add(fn);
  return () => noticeListeners.delete(fn);
}
function clearFeedback() {
  messages.clear();
  for (const address of listeners.keys()) notify(address);
}
export function useMessage(address) {
  return useSyncExternalStore(
    (fn) => {
      if (!listeners.has(address)) listeners.set(address, new Set());
      listeners.get(address).add(fn);
      return () => listeners.get(address)?.delete(fn);
    },
    () => messages.get(address) ?? empty,
  );
}
export function useStatus() {
  return useSyncExternalStore(
    (fn) => {
      statusListeners.add(fn);
      return () => statusListeners.delete(fn);
    },
    () => status,
  );
}
export function send(address, parameters = []) {
  if (!isNativeIOS && socket?.readyState !== WebSocket.OPEN) {
    notice("Disconnected. Commands are not queued.");
    return false;
  }
  if (!status.configured) {
    notice("Set your console address in Connection.");
    return false;
  }
  if (!status.udpReady) {
    notice("OSC socket unavailable. Check Connection.");
    return false;
  }
  if (isNativeIOS)
    NativeOSC.send({ address, parameters }).catch((error) =>
      notice(error.message || "OSC command failed."),
    );
  else socket.send(JSON.stringify({ type: "osc", address, parameters }));
  return true;
}
export function coalesce(address, parameters) {
  if (!status.bridge || !status.configured || !status.udpReady)
    return send(address, parameters);
  queued.set(address, parameters);
  if (!flushTimer)
    flushTimer = setTimeout(() => {
      flushTimer = null;
      if (isNativeIOS) {
        if (status.configured && status.udpReady)
          NativeOSC.sendBatch({
            messages: [...queued].map(([address, parameters]) => ({
              address,
              parameters,
            })),
          }).catch((error) => notice(error.message || "OSC update failed."));
      } else for (const [a, p] of queued) send(a, p);
      queued.clear();
    }, 33);
  return true;
}
export function tap(address) {
  if (send(address, [1])) send(address, [0]);
}
export function key(name) {
  tap("/eos/key/" + name);
}
export function command(text) {
  send("/eos/cmd", [text]);
}
function initialize() {
  send("/eos/fader/1/config/1/40");
  send("/eos/ds/1/group/12");
  send("/eos/ds/4/cp/25");
  send("/eos/subscribe/param/intens/pan/tilt/edge/zoom", [1]);
}
let nativeListening;
function acceptMessage(msg) {
  if (msg.type === "status") {
    updateStatus({ ...msg, bridge: true });
    if (!msg.udpReady) bootstrapped = false;
    if (msg.configured && msg.udpReady && !bootstrapped) {
      bootstrapped = true;
      initialize();
    }
  } else if (msg.type === "reset") {
    updateStatus({
      consoleOnline: false,
      udpReady: false,
      session: (status.session || 0) + 1,
    });
    clearFeedback();
    queued.clear();
    bootstrapped = false;
  } else if (msg.type === "error") notice(msg.message);
  else if (msg.type === "osc" && Array.isArray(msg.parameters)) {
    const old = messages.get(msg.address);
    if (
      !old ||
      old.length !== msg.parameters.length ||
      old.some((v, i) => v !== msg.parameters[i])
    ) {
      messages.set(msg.address, msg.parameters);
      notify(msg.address);
    }
    publishOSC(msg);
  }
}
async function connectNative() {
  try {
    if (!nativeListening)
      nativeListening = NativeOSC.addListener("message", acceptMessage);
    await nativeListening;
    await NativeOSC.setKeepAwake({ enabled: loadPreferences().keepAwake });
    await NativeOSC.connect();
    updateStatus({ bridge: true, native: true });
  } catch (error) {
    nativeListening = null;
    updateStatus({
      bridge: false,
      native: true,
      error: error.message || "Native OSC unavailable.",
    });
    notice("Native OSC could not start. " + (error.message || ""));
  }
}
export function connect() {
  if (isNativeIOS) {
    connectNative();
    return;
  }

  clearTimeout(timer);
  const previous = socket;
  if (previous) {
    previous.onclose = null;
    previous.close();
  }
  bootstrapped = false;
  socket = new WebSocket(
    `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/ws/osc`,
  );
  const current = socket;
  socket.onopen = () => {
    if (current === socket) updateStatus({ bridge: true });
  };
  socket.onmessage = (event) => {
    if (current !== socket) return;
    try {
      acceptMessage(JSON.parse(event.data));
    } catch {}
  };
  socket.onclose = () => {
    if (current !== socket) return;
    queued.clear();
    clearFeedback();
    updateStatus({ bridge: false, consoleOnline: false });
    timer = setTimeout(connect, 3000);
  };
  socket.onerror = () => {};
}
window.addEventListener("online", () => {
  if (!isNativeIOS && socket?.readyState !== WebSocket.OPEN) connect();
});
document.addEventListener("visibilitychange", () => {
  if (!isNativeIOS && !document.hidden && socket?.readyState !== WebSocket.OPEN)
    connect();
});
const eventListeners = new Set();
export function subscribeOSC(fn) {
  eventListeners.add(fn);
  return () => eventListeners.delete(fn);
}
export function publishOSC(msg) {
  eventListeners.forEach((fn) => fn(msg));
}
export function readMessage(address) {
  return messages.get(address) ?? empty;
}

export function useMessages(addresses) {
  const signature = addresses.join("|");
  return JSON.parse(
    useSyncExternalStore(
      useCallback(
        (fn) => {
          const cleanup = signature
            .split("|")
            .filter(Boolean)
            .map((address) => {
              if (!listeners.has(address)) listeners.set(address, new Set());
              listeners.get(address).add(fn);
              return () => listeners.get(address)?.delete(fn);
            });
          return () => cleanup.forEach((f) => f());
        },
        [signature],
      ),
      useCallback(
        () =>
          JSON.stringify(
            signature
              ? signature.split("|").map((a) => messages.get(a) ?? [])
              : [],
          ),
        [signature],
      ),
    ),
  );
}

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    queued.clear();
    clearTimeout(flushTimer);
    flushTimer = null;
  }
});
