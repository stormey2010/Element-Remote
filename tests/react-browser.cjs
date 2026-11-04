const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const dgram = require("node:dgram");
const { once } = require("node:events");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const osc = require("osc");
(async () => {
  const { createRemoteServer } = await import("../server/index.mjs");
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), "element-ui-"));
  const consoleUDP = dgram.createSocket("udp4");
  consoleUDP.bind(0, "127.0.0.1");
  await once(consoleUDP, "listening");
  const consolePort = consoleUDP.address().port;
  const temp = dgram.createSocket("udp4");
  temp.bind(0, "127.0.0.1");
  await once(temp, "listening");
  const receivePort = temp.address().port;
  temp.close();
  const packets = [];
  const reply = (address, args) =>
    consoleUDP.send(
      Buffer.from(osc.writePacket({ address, args })),
      receivePort,
      "127.0.0.1",
    );
  consoleUDP.on("message", (bytes) => {
    const p = osc.readPacket(bytes, { metadata: false });
    packets.push(p);
    if (p.address === "/eos/ping") reply("/eos/out/ping", p.args);
    if (p.address === "/eos/fader/1/config/1/40")
      for (let n = 1; n <= 40; n++) {
        reply(`/eos/out/fader/1/${n}/name`, ["Sub " + n]);
        reply(`/eos/fader/1/${n}`, [0]);
      }
    if (/^\/eos\/fader\/1\/\d+$/.test(p.address)) reply(p.address, p.args);
    if (p.address === "/eos/get/patch/count")
      reply("/eos/out/get/patch/count", [1]);
    if (p.address === "/eos/get/patch/index" && p.args[0] === 0)
      reply("/eos/out/get/patch/42/1/list/0/6", [
        0,
        "uid",
        "Front wash",
        "ETC",
        "Source Four",
        513,
      ]);
    if (p.address.startsWith("/eos/cuelist/1/config/"))
      reply("/eos/out/cuelist/1/3", [
        "12 Evening",
        "12",
        "Evening",
        "",
        "",
        false,
        5000,
        -1,
      ]);
  });
  let server, browser;
  try {
    server = await createRemoteServer({
      configPath: path.join(folder, "config.json"),
      config: { consoleHost: "127.0.0.1", consolePort, receivePort },
      udpBind: "127.0.0.1",
      pingInterval: 300,
    });
    const address = await server.listen(0, "127.0.0.1");
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(`http://127.0.0.1:${address.port}`);
    await page.getByText("Console responding", { exact: true }).waitFor();
    await page.getByRole("button", { name: "7", exact: true }).click();
    await page.waitForFunction(() => true);
    await new Promise((r) => setTimeout(r, 50));
    assert.deepEqual(
      packets.filter((p) => p.address === "/eos/key/7").map((p) => p.args),
      [[1], [0]],
    );
    await page.getByRole("link", { name: "Faders", exact: true }).click();
    await page.getByRole("heading", { name: "Faders", exact: true }).waitFor();
    assert.equal(await page.locator(".fader-tile").count(), 40);
    const before = packets.filter((p) =>
      /^\/eos\/fader\/1\/\d+$/.test(p.address),
    ).length;
    await page
      .getByRole("button", { name: "Select fader 1", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Select fader 3", exact: true })
      .click();
    assert.equal(
      packets.filter((p) => /^\/eos\/fader\/1\/\d+$/.test(p.address)).length,
      before,
    );
    await page.getByRole("button", { name: "50%", exact: true }).click();
    await page.waitForFunction(
      () =>
        document.querySelector(".fader-tile .fader-readout").textContent ===
        "50%",
    );
    assert.deepEqual(
      packets
        .filter((p) => /^\/eos\/fader\/1\/\d+$/.test(p.address))
        .map((p) => [p.address, p.args]),
      [
        ["/eos/fader/1/1", [0.5]],
        ["/eos/fader/1/3", [0.5]],
      ],
    );
    await page
      .getByRole("button", { name: "Select fader 3", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Select fader 40", exact: true })
      .click();
    await page.getByRole("button", { name: "Full", exact: true }).click();
    await page.waitForFunction(() =>
      document.querySelectorAll(".fader-tile")[39].textContent.includes("100%"),
    );
    assert.deepEqual(
      packets
        .filter((p) => /^\/eos\/fader\/1\/\d+$/.test(p.address))
        .slice(-2)
        .map((p) => p.address),
      ["/eos/fader/1/1", "/eos/fader/1/40"],
    );
    await page.getByRole("button", { name: "Clear", exact: true }).click();
    assert.equal(
      await page.getByLabel("Selected faders level").isDisabled(),
      true,
    );
    await page.evaluate(() => (location.hash = "wheels"));
    await page.getByRole("heading", { name: "Parameter wheels" }).waitFor();
    await page.getByLabel("Fine", { exact: true }).check();
    await page
      .getByRole("button", { name: "Pan increase", exact: true })
      .click();
    await page.evaluate(() => (location.hash = "color"));
    await page.getByRole("heading", { name: "Color", exact: true }).waitFor();
    await page.getByLabel("Hue", { exact: true }).fill("180");
    await page.getByLabel("Saturation", { exact: true }).fill("75");
    await new Promise((r) => setTimeout(r, 80));
    assert.deepEqual(
      packets.filter((p) => p.address === "/eos/color/hs").at(-1).args,
      [180, 75],
    );
    await page.evaluate(() => (location.hash = "patch"));
    await page
      .getByRole("button", { name: "↻ Load patch", exact: true })
      .click();
    await page.getByText("Source Four · Front wash", { exact: true }).waitFor();
    await page.evaluate(() => (location.hash = "cues"));
    await page.getByRole("button", { name: "Load list", exact: true }).click();
    await page.getByText("Evening", { exact: true }).waitFor();
    assert.equal(
      await page.getByRole("button", { name: "Go", exact: true }).isDisabled(),
      true,
    );
    await page.getByLabel("Cue controls").selectOption("unlocked");
    await page.getByRole("button", { name: "Go", exact: true }).click();
    for (const width of [320, 375, 390, 768, 1024, 1440]) {
      await page.setViewportSize({ width, height: 850 });
      for (const tab of [
        "console",
        "faders",
        "wheels",
        "color",
        "patch",
        "cues",
        "focus",
        "playback",
        "subs",
        "macros",
        "connect",
      ]) {
        await page.evaluate((tab) => (location.hash = tab), tab);
        await page.waitForFunction(
          (tab) => document.querySelector("main").dataset.view === tab,
          tab,
        );
        await page.locator("main h2, .six-grid").first().waitFor();
        const layout = await page.evaluate(() => ({
          width: innerWidth,
          scroll: document.documentElement.scrollWidth,
        }));
        assert.ok(
          layout.scroll <= layout.width,
          `Overflow ${width} ${tab} ${JSON.stringify(layout)}`,
        );
      }
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(() => (location.hash = "faders"));
    await page.getByRole("heading", { name: "Faders", exact: true }).waitFor();
    await page
      .getByRole("button", { name: "Select fader 1", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Select fader 5", exact: true })
      .click();
    await page.screenshot({
      path: "/tmp/element-react-faders.png",
      fullPage: true,
    });
    await page.getByRole("link", { name: "More", exact: true }).click();
    await page
      .getByRole("heading", { name: "More controls", exact: true })
      .waitFor();
    assert.equal(await page.locator("nav a").count(), 4);
    assert.equal(await page.locator(".tools-grid a").count(), 8);
    await page.locator('.tools-grid a[href="#color"]').click();
    await page.getByRole("heading", { name: "Color", exact: true }).waitFor();
    await page.evaluate(() => (location.hash = "connect"));
    await page
      .getByRole("heading", { name: "Connections", exact: true })
      .waitFor();
    await page
      .getByRole("button", { name: "Third Party", exact: true })
      .click();
    assert.equal(
      await page
        .getByRole("button", { name: "Third Party", exact: true })
        .getAttribute("aria-pressed"),
      "true",
    );
    await page.getByRole("button", { name: "UDP", exact: true }).click();
    await page.getByText("Server receive port", { exact: true }).waitFor();
    await page.screenshot({
      path: "/tmp/element-charcoal-connection.png",
      fullPage: true,
    });
    await page.evaluate(() => (location.hash = "more"));
    await page
      .getByRole("heading", { name: "More controls", exact: true })
      .waitFor();
    await page.screenshot({
      path: "/tmp/element-charcoal-more.png",
      fullPage: true,
    });
    assert.deepEqual(errors, []);
    console.log(
      "PASS React: real UDP key edges, 40 faders, multi-selection without output, selected-only levels, live feedback, fine wheels, color, patch/cue data, lock and eleven views at six widths.",
    );
  } finally {
    await browser?.close();
    await server?.close();
    consoleUDP.close();
    await fs.rm(folder, { recursive: true, force: true });
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
