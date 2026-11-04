// Exercises the real React app through Capacitor's bridge contract, without a server transport.
const { chromium, webkit } = require(
  process.env.PLAYWRIGHT_MODULE || "playwright",
);
const assert = require("node:assert/strict");
(async () => {
  const { createRemoteServer } = await import("../server/index.mjs");
  let server, browser;
  try {
    server = await createRemoteServer({
      config: {
        consoleHost: "",
        consolePort: 3032,
        receivePort: 8001,
        transport: "tcp",
      },
    });
    const addr = await server.listen(0, "127.0.0.1");
    browser = await (
      process.env.TEST_BROWSER === "webkit" ? webkit : chromium
    ).launch({ headless: true });
    const page = await browser.newPage({
      viewport: { width: 390, height: 844 },
      isMobile: true,
      hasTouch: true,
    });
    const calls = [];
    page.on("request", (r) => {
      if (/\/(api|ws)\//.test(new URL(r.url()).pathname)) calls.push(r.url());
    });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.addInitScript(() => {
      window.nativeCalls = [];
      window.nativeSent = [];
      let callback;
      let config = {
        displayName: "Element",
        consoleHost: "",
        consolePort: 3032,
        receivePort: 8001,
        transport: "tcp",
      };
      window.emitNative = (data) => callback?.(data);
      function status() {
        return {
          type: "status",
          bridge: true,
          native: true,
          configured: !!config.consoleHost,
          consoleOnline: !!config.consoleHost,
          udpReady: !!config.consoleHost,
          config,
          error: "",
          latencyMs: 3,
        };
      }
      window.webkit = { messageHandlers: { bridge: {} } };
      window.WebSocket = class {
        constructor() {
          throw Error("Native app attempted WebSocket connection");
        }
      };
      window.Capacitor = {
        PluginHeaders: [
          {
            name: "ElementOSC",
            methods: [
              ...[
                "getConfig",
                "configure",
                "connect",
                "disconnect",
                "send",
                "sendBatch",
                "haptic",
                "setKeepAwake",
                "removeListener",
              ].map((name) => ({ name, rtype: "promise" })),
              { name: "addListener", rtype: "callback" },
            ],
          },
        ],
        nativeCallback(plugin, method, args, fn) {
          if (method === "addListener") callback = fn;
          return "native-listener";
        },
        nativePromise(plugin, method, args) {
          window.nativeCalls.push({ method, args });
          if (method === "getConfig") return Promise.resolve({ ...config });
          if (method === "connect") {
            window.emitNative({ type: "reset" });
            window.emitNative(status());
          }
          if (method === "configure") {
            config = { ...args.config };
            window.emitNative({ type: "reset" });
            window.emitNative(status());
            return Promise.resolve({ ...config });
          }
          if (method === "sendBatch") {
            args.messages.forEach((message) =>
              window.Capacitor.nativePromise(plugin, "send", message),
            );
            return Promise.resolve({});
          }
          if (method === "send") {
            window.nativeSent.push(args);
            if (args.address === "/eos/fader/1/config/1/40")
              for (let n = 1; n <= 40; n++)
                window.emitNative({
                  type: "osc",
                  address: `/eos/fader/1/${n}`,
                  parameters: [0],
                });
            if (/^\/eos\/fader\/1\/\d+$/.test(args.address))
              window.emitNative({ type: "osc", ...args });
          }
          return Promise.resolve({});
        },
      };
    });
    await page.goto(`http://127.0.0.1:${addr.port}/#connect`);
    await page.getByText("On-device OSC", { exact: false }).waitFor();
    assert.match(
      await page.locator("main").textContent(),
      /connects directly to Element/,
    );
    await page
      .getByLabel("Console IPv4 address", { exact: true })
      .fill("192.168.1.102");
    await page.getByLabel("Display name", { exact: true }).fill("Tech");
    await page
      .getByRole("button", { name: "Save & connect", exact: true })
      .click();
    await page.getByText("Settings saved.", { exact: true }).waitFor();
    assert.equal(
      (
        await page.evaluate(
          () => nativeCalls.find((c) => c.method === "configure").args.config,
        )
      ).consoleHost,
      "192.168.1.102",
    );
    await page.getByRole("link", { name: "Faders", exact: true }).click();
    await page.getByRole("heading", { name: "Faders", exact: true }).waitFor();
    await page
      .getByRole("button", { name: "Select fader 1", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Select fader 40", exact: true })
      .click();
    await page.getByRole("button", { name: "50%", exact: true }).click();
    await page.waitForFunction(
      () =>
        nativeSent.filter((m) => /^\/eos\/fader\/1\/\d+$/.test(m.address))
          .length === 2,
    );
    assert.deepEqual(
      await page.evaluate(() =>
        nativeSent
          .filter((m) => /^\/eos\/fader\/1\/\d+$/.test(m.address))
          .map((m) => [m.address, m.parameters]),
      ),
      [
        ["/eos/fader/1/1", [0.5]],
        ["/eos/fader/1/40", [0.5]],
      ],
    );
    assert.ok(
      await page.evaluate(() => nativeCalls.some((c) => c.method === "haptic")),
    );
    await page.evaluate(() => emitNative({ type: "reset" }));
    await page.getByText("0 selected", { exact: true }).waitFor();
    await page.getByRole("link", { name: "More", exact: true }).click();
    await page.getByLabel("Keep screen awake", { exact: true }).check();
    assert.ok(
      await page.evaluate(() =>
        nativeCalls.some((c) => c.method === "setKeepAwake" && c.args.enabled),
      ),
    );
    await page.screenshot({
      path: "/tmp/element-ios-more.png",
      fullPage: true,
    });
    assert.deepEqual(calls, []);
    assert.deepEqual(errors, []);
    console.log(
      "PASS iOS bridge contract: native settings, direct OSC, 40-fader selection, haptics, keep awake, reconnect reset; no WebSocket or HTTP API requests.",
    );
  } finally {
    await browser?.close();
    await server?.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
