import test from "node:test";
import assert from "node:assert/strict";
import dgram from "node:dgram";
import { once } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";
import osc from "osc";
import {
  createRemoteServer,
  validateConfig,
  validateMessage,
} from "../server/index.mjs";
async function bind(socket) {
  socket.bind(0, "127.0.0.1");
  await once(socket, "listening");
  return socket.address().port;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn) {
  for (let n = 0; n < 100; n++) {
    if (fn()) return;
    await sleep(20);
  }
  throw Error("Timed out");
}
test("validates console configuration and OSC input", () => {
  assert.throws(() =>
    validateConfig({
      consoleHost: "bad",
      consolePort: 8000,
      receivePort: 8001,
    }),
  );
  assert.throws(() =>
    validateConfig({ consoleHost: "", consolePort: 80, receivePort: 8001 }),
  );
  assert.equal(
    validateMessage({ address: "/eos/color/hs", parameters: [180, 75] }),
    true,
  );
  for (const value of [
    { address: "/other", parameters: [] },
    { address: "/eos/cmd", parameters: [{}] },
    { address: "/eos/at", parameters: [NaN] },
    { address: "/eos/at", parameters: [].concat(Array(65).fill(1)) },
  ])
    assert.equal(validateMessage(value), false);
});
test("real UDP OSC round trip, websocket, configuration persistence and static caching", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "element-backend-")),
    consoleUDP = dgram.createSocket("udp4"),
    received = [];
  const consolePort = await bind(consoleUDP),
    reserved = dgram.createSocket("udp4"),
    receivePort = await bind(reserved);
  reserved.close();
  let client, server;
  try {
    server = await createRemoteServer({
      configPath: join(dir, "bridge.json"),
      config: { consoleHost: "127.0.0.1", consolePort, receivePort },
      udpBind: "127.0.0.1",
      pingInterval: 100,
    });
    const address = await server.listen(0, "127.0.0.1"),
      base = `http://127.0.0.1:${address.port}`;
    consoleUDP.on("message", (bytes, remote) => {
      const packet = osc.readPacket(bytes, { metadata: false });
      received.push(packet);
      if (packet.address === "/eos/ping")
        consoleUDP.send(
          Buffer.from(
            osc.writePacket({ address: "/eos/out/ping", args: packet.args }),
          ),
          remote.port,
          remote.address,
        );
    });
    client = new WebSocket(`ws://127.0.0.1:${address.port}/ws/osc`);
    const messages = [];
    client.on("message", (bytes) => messages.push(JSON.parse(bytes)));
    await once(client, "open");
    await until(() => messages.some((m) => m.type === "status" && m.udpReady));
    client.send(
      JSON.stringify({ address: "/eos/color/hs", parameters: [180, 75] }),
    );
    await until(() => received.some((p) => p.address === "/eos/color/hs"));
    assert.deepEqual(
      received.find((p) => p.address === "/eos/color/hs").args,
      [180, 75],
    );
    for (const edge of [1, 0])
      client.send(
        JSON.stringify({ address: "/eos/key/go_0", parameters: [edge] }),
      );
    await until(
      () => received.filter((p) => p.address === "/eos/key/go_0").length === 2,
    );
    assert.deepEqual(
      received.filter((p) => p.address === "/eos/key/go_0").map((p) => p.args),
      [[1], [0]],
    );
    const cue = ["12 Evening", "12", "Evening", "", "", false, 5000, -1];
    consoleUDP.send(
      Buffer.from(
        osc.writePacket({ address: "/eos/out/cuelist/1/3", args: cue }),
      ),
      receivePort,
      "127.0.0.1",
    );
    await until(() =>
      messages.some((m) => m.address === "/eos/out/cuelist/1/3"),
    );
    assert.deepEqual(
      messages.find((m) => m.address === "/eos/out/cuelist/1/3").parameters,
      cue,
    );
    await until(() =>
      messages.some((m) => m.type === "status" && m.consoleOnline),
    );
    client.send(JSON.stringify({ address: "/unsafe", parameters: [] }));
    await until(() => messages.some((m) => m.type === "error"));
    const health = await fetch(base + "/api/health").then((r) => r.json());
    assert.equal(health.consoleOnline, true);
    const html = await fetch(base);
    assert.equal(html.status, 200);
    assert.match(html.headers.get("cache-control"), /no-cache/);
    const invalid = await fetch(base + "/api/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ consoleHost: "bad" }),
    });
    assert.equal(invalid.status, 400);
    const foreign = await fetch(base + "/api/config", {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        Origin: "https://other.invalid",
      },
      body: "{}",
    });
    assert.equal(foreign.status, 403);
    const valid = await fetch(base + "/api/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        consoleHost: "127.0.0.1",
        consolePort,
        receivePort,
      }),
    });
    assert.equal(valid.status, 200);
    const saved = JSON.parse(await readFile(join(dir, "bridge.json"), "utf8"));
    assert.equal(saved.consolePort, consolePort);
  } finally {
    client?.terminate();
    await server?.close();
    consoleUDP.close();
    await rm(dir, { recursive: true, force: true });
  }
});
import { createServer as createTCPServer } from "node:net";
import { encodeFrame, createDecoder } from "../server/framing.mjs";
test("TCP framing handles split packets, combined packets and SLIP escapes", () => {
  for (const mode of ["tcp", "third-party"]) {
    const packets = [],
      decode = createDecoder((p) => packets.push([...p]), mode),
      a = Buffer.from([1, 0xc0, 0xdb, 2]),
      b = Buffer.from([3, 4]);
    const combined = Buffer.concat([
      encodeFrame(a, mode),
      encodeFrame(b, mode),
    ]);
    for (const byte of combined) decode(Buffer.from([byte]));
    assert.deepEqual(packets, [[...a], [...b]]);
  }
  assert.throws(() =>
    createDecoder(() => {}, "tcp")(Buffer.from([255, 255, 255, 255])),
  );
});
for (const transport of ["tcp", "third-party"])
  test(`${transport} transports actual OSC with automatic replies`, async () => {
    const dir = await mkdtemp(join(tmpdir(), "element-tcp-")),
      received = [],
      connections = new Set();
    const mock = createTCPServer((socket) => {
      connections.add(socket);
      socket.on("close", () => connections.delete(socket));
      const decode = createDecoder((bytes) => {
        const msg = osc.readPacket(bytes, { metadata: false });
        received.push(msg);
        if (msg.address === "/eos/ping") {
          const frame = encodeFrame(
            Buffer.from(
              osc.writePacket({ address: "/eos/out/ping", args: msg.args }),
            ),
            transport,
          );
          socket.write(frame.subarray(0, 3));
          socket.write(frame.subarray(3));
        }
      }, transport);
      socket.on("data", decode);
    });
    mock.listen(0, "127.0.0.1");
    await once(mock, "listening");
    let server, client;
    try {
      server = await createRemoteServer({
        configPath: join(dir, "bridge.json"),
        config: {
          transport,
          consoleHost: "127.0.0.1",
          consolePort: mock.address().port,
          receivePort: 8001,
        },
        pingInterval: 100,
      });
      const address = await server.listen(0, "127.0.0.1");
      const messages = [];
      client = new WebSocket(`ws://127.0.0.1:${address.port}/ws/osc`);
      client.on("message", (m) => messages.push(JSON.parse(m)));
      await once(client, "open");
      await until(() =>
        messages.some((m) => m.type === "status" && m.consoleOnline),
      );
      client.send(
        JSON.stringify({ address: "/eos/color/xy", parameters: [0.3, 0.4] }),
      );
      await until(() => received.some((m) => m.address === "/eos/color/xy"));
      const args = received.find((m) => m.address === "/eos/color/xy").args;
      assert.ok(Math.abs(args[0] - 0.3) < 0.00001);
      assert.ok(Math.abs(args[1] - 0.4) < 0.00001);
    } finally {
      client?.terminate();
      await server?.close();
      for (const connection of connections) connection.destroy();
      await new Promise((r) => mock.close(r));
      await rm(dir, { recursive: true, force: true });
    }
  });
