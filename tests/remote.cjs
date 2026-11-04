// Run: node tests/remote.cjs (requires Playwright; set PLAYWRIGHT_MODULE if external).
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.route("http://element.test/**", (route) => {
    const file = path.join(
      __dirname,
      "../docs",
      new URL(route.request().url()).pathname === "/"
        ? "index.html"
        : new URL(route.request().url()).pathname,
    );
    return route.fulfill({
      body: fs.readFileSync(file),
      contentType: file.endsWith(".js")
        ? "text/javascript"
        : file.endsWith(".css")
          ? "text/css"
          : file.endsWith(".html")
            ? "text/html"
            : "application/json",
    });
  });
  await page.addInitScript(() => {
    window.sent = [];
    window.connections = [];
    class MockSocket extends EventTarget {
      static OPEN = 1;
      constructor() {
        super();
        this.readyState = 0;
        window.connections.push(this);
        setTimeout(() => {
          this.readyState = 1;
          this.dispatchEvent(new Event("open"));
        }, 0);
      }
      send(raw) {
        const msg = JSON.parse(raw);
        window.sent.push(msg);
        if (msg.address === "/eos/ping")
          this.reply("/eos/out/ping", msg.parameters);
      }
      close() {
        this.readyState = 3;
        this.dispatchEvent(new Event("close"));
      }
      reply(address, parameters) {
        this.dispatchEvent(
          new MessageEvent("message", {
            data: JSON.stringify({ type: "osc", address, parameters }),
          }),
        );
      }
    }
    window.WebSocket = MockSocket;
  });
  await page.goto("http://element.test/");
  await page.waitForFunction(
    () =>
      document.getElementById("console-state").textContent ===
      "Console responding",
  );
  assert.equal(await page.locator("#direct-selects button").count(), 12);
  await page.locator("#direct-selects button").first().click();
  assert.deepEqual(
    await page.evaluate(() =>
      sent.filter((x) => x.address === "/eos/ds/1/1").map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await page.locator("#direct-type").selectOption("cp");
  assert.equal(
    await page.evaluate(() => sent.at(-1).address),
    "/eos/ds/1/cp/12",
  );
  await page.evaluate(() =>
    connections.at(-1).reply("/eos/out/ds/1/1", ["Warm wash [1]"]),
  );
  assert.equal(
    await page.locator(".direct-label").first().textContent(),
    "Warm wash [1]",
  );
  await page.locator('#keypad [data-key="@"] ').click();
  assert.deepEqual(
    await page.evaluate(() =>
      sent.filter((x) => x.address === "/eos/key/@").map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await page.getByRole("button", { name: "7", exact: true }).click();
  assert.deepEqual(
    await page.evaluate(() =>
      sent.filter((x) => x.address === "/eos/key/7").map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await page.locator('[data-page="focus"]').click();
  await page.locator('[data-view="focus"]').waitFor({ state: "visible" });
  await page.locator("#channel").fill("42");
  await page
    .getByRole("button", { name: "Select channel", exact: true })
    .click();
  assert.equal(
    await page.evaluate(
      () => sent.findLast((x) => x.address === "/eos/chan").parameters[0],
    ),
    42,
  );
  await page.getByRole("button", { name: "50%", exact: true }).click();
  assert.equal(
    await page.evaluate(
      () => sent.findLast((x) => x.address === "/eos/at").parameters[0],
    ),
    50,
  );
  await page.evaluate(() => {
    connections.at(-1).reply("/eos/out/active/chan", ["42 [75]"]);
    connections
      .at(-1)
      .reply("/eos/out/active/cue/text", ["1/12 Evening 5.0 100%"]);
    connections.at(-1).reply("/eos/out/cmd", ["<img src=x onerror=alert(1)>"]);
  });
  assert.equal(await page.locator("#intensity-value").textContent(), "75%");
  assert.equal(await page.locator("#command img").count(), 0);
  await page.locator('[data-page="subs"]').click();
  await page.locator('[data-view="subs"]').waitFor({ state: "visible" });
  await page.locator("#sub-slider-1").evaluate((el) => {
    el.value = 75;
    el.dispatchEvent(new Event("input"));
  });
  assert.equal(
    await page.evaluate(
      () => sent.findLast((x) => x.address === "/eos/sub/1").parameters[0],
    ),
    0.75,
  );
  const bump = page.getByRole("button", {
    name: "Hold to bump submaster 1",
    exact: true,
  });
  await bump.focus();
  await page.keyboard.down("Space");
  await page.keyboard.up("Space");
  assert.deepEqual(
    await page.evaluate(() =>
      sent
        .filter((x) => x.address === "/eos/sub/1/fire")
        .map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await bump.hover();
  await page.mouse.down();
  await page.evaluate(() => window.dispatchEvent(new Event("blur")));
  await page.mouse.up();
  assert.deepEqual(
    await page.evaluate(() =>
      sent
        .filter((x) => x.address === "/eos/sub/1/fire")
        .slice(-2)
        .map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await page.locator('[data-page="macros"]').click();
  await page.locator('[data-view="macros"]').waitFor({ state: "visible" });
  await page.locator("#macro-grid button").first().click();
  assert.deepEqual(
    await page.evaluate(() =>
      sent
        .filter((x) => x.address === "/eos/macro/1/fire")
        .map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await page.locator('[data-page="playback"]').click();
  await page.locator('[data-view="playback"]').waitFor({ state: "visible" });
  await page.getByRole("button", { name: "▶ Go", exact: true }).click();
  assert.deepEqual(
    await page.evaluate(() =>
      sent
        .filter((x) => x.address === "/eos/key/go_0")
        .map((x) => x.parameters),
    ),
    [[1], [0]],
  );
  await page.locator('[data-page="directs"]').click();
  await page.locator('[data-view="directs"]').waitFor({ state: "visible" });
  assert.equal(await page.locator(".mapped-fader input").count(), 8);
  await page.locator("#mapped-fader-1").evaluate((el) => {
    el.value = 75;
    el.dispatchEvent(new Event("input"));
  });
  assert.deepEqual(
    await page.evaluate(() => ({
      address: sent.at(-1).address,
      parameters: sent.at(-1).parameters,
    })),
    { address: "/eos/fader/1/1", parameters: [0.75] },
  );
  await page.evaluate(() => {
    connections.at(-1).reply("/eos/out/fader/1/1/name", ["Front wash"]);
    connections.at(-1).reply("/eos/fader/1/1", [0.5]);
  });
  assert.equal(
    await page.locator(".mapped-fader h3").first().textContent(),
    "Front wash",
  );
  assert.equal(await page.locator("#mapped-fader-1").inputValue(), "50");
  await page.getByRole("button", { name: "Fader 1 full", exact: true }).click();
  assert.equal(await page.evaluate(() => sent.at(-1).parameters[0]), 1);
  await page.locator("#fader-next").click();
  assert.equal(
    await page.evaluate(() => sent.at(-1).address),
    "/eos/fader/1/config/2/8",
  );
  assert.equal(
    await page.locator(".mapped-fader output").first().textContent(),
    "—",
  );
  await page.locator("#fader-prev").click();
  assert.equal(
    await page.evaluate(() => sent.at(-1).address),
    "/eos/fader/1/config/1/8",
  );
  await page.locator('[data-page="wheels"]').click();
  await page.locator('[data-view="wheels"]').waitFor({ state: "visible" });
  await page.getByRole("button", { name: "Pan increase", exact: true }).click();
  assert.equal(
    await page.evaluate(() => sent.at(-1).address),
    "/eos/wheel/coarse/pan",
  );
  await page.locator("#fine-mode").check();
  await page
    .getByRole("button", { name: "Tilt decrease", exact: true })
    .click();
  assert.deepEqual(
    await page.evaluate(() => ({
      address: sent.at(-1).address,
      parameters: sent.at(-1).parameters,
    })),
    { address: "/eos/wheel/fine/tilt", parameters: [-1] },
  );
  await page.evaluate(() =>
    connections.at(-1).reply("/eos/out/param/pan", [[45, -270, 270]]),
  );
  assert.equal(await page.locator("#wheel-pan").textContent(), "45");
  await page.locator("#pad-mode").selectOption("absolute");
  await page.locator("#position-pad").click({ position: { x: 80, y: 80 } });
  assert.equal(
    await page.evaluate(() => sent.at(-1).address),
    "/eos/pantilt/xy",
  );
  assert.equal(await page.evaluate(() => sent.at(-1).parameters.length), 2);
  await page.locator('[data-page="color"]').click();
  await page.locator('[data-view="color"]').waitFor({ state: "visible" });
  await page.locator("#hue").evaluate((el) => {
    el.value = 180;
    el.dispatchEvent(new Event("input"));
  });
  assert.deepEqual(
    await page.evaluate(() => sent.at(-1).parameters),
    [180, 100],
  );
  await page.locator("#color-pad").focus();
  await page.keyboard.press("ArrowDown");
  assert.deepEqual(
    await page.evaluate(() => sent.at(-1).parameters),
    [180, 99],
  );
  await page.evaluate(() =>
    connections.at(-1).reply("/eos/out/ds/4/1", ["Lavender [1]"]),
  );
  await page.locator("#color-search").fill("Lavender");
  assert.equal(await page.locator("#color-palettes button:visible").count(), 1);
  await page.locator("#color-space").selectOption("xy");
  await page.locator("#color-pad").focus();
  await page.keyboard.press("ArrowRight");
  assert.equal(await page.evaluate(() => sent.at(-1).address), "/eos/color/xy");
  assert.equal(await page.evaluate(() => sent.at(-1).parameters.length), 2);
  await page.locator('[data-page="patch"]').click();
  await page.locator('[data-view="patch"]').waitFor({ state: "visible" });
  await page.locator("#patch-refresh").click();
  assert.equal(
    await page.evaluate(
      () => sent.filter((m) => m.address === "/eos/get/patch/index").length,
    ),
    25,
  );
  await page.evaluate(() => {
    connections.at(-1).reply("/eos/out/get/patch/count", [30]);
    connections
      .at(-1)
      .reply("/eos/out/get/patch/42/1/list/0/6", [
        [0, "uid", "Front wash", "ETC", "Source Four", 513],
      ]);
  });
  assert.match(await page.locator("#patch-rows").textContent(), /Source Four/);
  await page.locator("#patch-next").click();
  assert.equal(
    await page.evaluate(
      () =>
        sent.filter((m) => m.address === "/eos/get/patch/index").at(-1)
          .parameters[0],
    ),
    49,
  );
  assert.equal(await page.locator("#patch-rows tr").count(), 0);
  await page.locator('[data-page="cues"]').click();
  await page.locator('[data-view="cues"]').waitFor({ state: "visible" });
  assert.equal(await page.locator("#cue-go").isDisabled(), true);
  await page.locator("#cue-load").click();
  assert.equal(
    await page.evaluate(() => sent.at(-1).address),
    "/eos/cuelist/1/config/1/3/12",
  );
  await page.evaluate(() =>
    connections
      .at(-1)
      .reply("/eos/out/cuelist/1/3", [
        ["12 Evening", "12", "Evening", "", "", false, 5000, -1],
      ]),
  );
  assert.match(await page.locator("#cue-rows").textContent(), /5.0s/);
  await page.locator("#cue-lock").selectOption("unlocked");
  await page.locator("#cue-go").click();
  assert.deepEqual(
    await page.evaluate(() =>
      sent
        .filter((m) => m.address === "/eos/cues/1/fire")
        .map((m) => m.parameters),
    ),
    [[1], [0]],
  );
  await page.locator('[data-page="console"]').click();
  await page.locator('[data-view="console"]').waitFor({ state: "visible" });
  await page.locator('[data-page="cues"]').click();
  await page.locator('[data-view="cues"]').waitFor({ state: "visible" });
  assert.equal(await page.locator("#cue-go").isDisabled(), true);

  for (const width of [320, 375, 390, 768, 1024, 1440]) {
    await page.setViewportSize({ width, height: 850 });
    for (const tab of [
      "directs",
      "wheels",
      "color",
      "patch",
      "cues",
      "console",
      "focus",
      "playback",
      "subs",
      "macros",
      "connect",
    ]) {
      await page.locator(`[data-page="${tab}"]`).click();
      await page.waitForFunction(
        (t) => document.querySelector(`[data-view="${t}"]`).hidden === false,
        tab,
      );
      const layout = await page.evaluate(() => ({
        width: innerWidth,
        scroll: document.documentElement.scrollWidth,
        overflow: [...document.querySelectorAll("main *")]
          .filter((el) => el.getBoundingClientRect().right > innerWidth + 1)
          .map((el) => ({
            tag: el.tagName,
            id: el.id,
            class: el.className,
            width: el.getBoundingClientRect().width,
            right: el.getBoundingClientRect().right,
          }))
          .slice(-15),
      }));
      assert.ok(
        layout.scroll <= layout.width,
        `Overflow ${width} ${tab}: ${JSON.stringify(layout)}`,
      );
    }
  }
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.locator('[data-page="console"]').click();
  await page.locator('[data-view="console"]').waitFor({ state: "visible" });
  await page.waitForFunction(
    () => document.getElementById("page-title").textContent === "Console",
  );
  await page.screenshot({ path: "/tmp/element-desktop.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "/tmp/element-mobile.png", fullPage: true });
  for (const tab of ["directs", "wheels", "color", "patch", "cues"]) {
    await page.locator(`[data-page="${tab}"]`).click();
    await page.waitForFunction(
      (t) => document.querySelector(`[data-view="${t}"]`).hidden === false,
      tab,
    );
    await page.screenshot({ path: `/tmp/element-${tab}.png`, fullPage: true });
  }
  await page.evaluate(() => connections.at(-1).close());
  await page.locator('[data-page="focus"]').click();
  await page.locator('[data-view="focus"]').waitFor({ state: "visible" });
  await page.getByRole("button", { name: "50%", exact: true }).click();
  assert.match(await page.locator("#toast").textContent(), /disconnected/);
  await page.waitForFunction(
    () => connections.length === 2 && connections.at(-1).readyState === 1,
  );
  assert.deepEqual(errors, []);
  await browser.close();
  console.log(
    "PASS: console controls; mapped faders and paging; fine wheels; pan/tilt; HS and CIE color; palette search; patch paging; cue feedback and lock; eleven views at six responsive widths; reconnect.",
  );
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
