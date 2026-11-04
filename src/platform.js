import { Capacitor, registerPlugin } from "@capacitor/core";
export const isNativeIOS = Capacitor.getPlatform() === "ios";
export const NativeOSC = registerPlugin("ElementOSC");
export async function loadConnectionConfig() {
  if (isNativeIOS) return NativeOSC.getConfig();
  const response = await fetch("/api/config");
  if (!response.ok) throw Error("Unable to load connection settings.");
  return response.json();
}
export async function saveConnectionConfig(config) {
  if (isNativeIOS) return NativeOSC.configure({ config });
  const response = await fetch("/api/config", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(config),
  });
  const data = await response.json();
  if (!response.ok)
    throw Error(data.error || "Unable to save connection settings.");
  return data;
}
export function loadPreferences() {
  try {
    return {
      haptics: true,
      keepAwake: false,
      ...JSON.parse(localStorage.getItem("element.preferences") || "{}"),
    };
  } catch {
    return { haptics: true, keepAwake: false };
  }
}
export function savePreferences(preferences) {
  try {
    localStorage.setItem("element.preferences", JSON.stringify(preferences));
  } catch {}
  if (isNativeIOS)
    NativeOSC.setKeepAwake({ enabled: preferences.keepAwake }).catch(() => {});
}
export function selectionHaptic() {
  if (isNativeIOS && loadPreferences().haptics)
    NativeOSC.haptic().catch(() => {});
}
