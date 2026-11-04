import express from "express";
import compression from "compression";
import { WebSocketServer, WebSocket } from "ws";
import dgram from "node:dgram";
import { createServer } from "node:http";
import { isIPv4, createConnection } from "node:net";
import { encodeFrame, createDecoder } from "./framing.mjs";
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import osc from "osc";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export function validateConfig(input) {
  const consoleHost = String(input.consoleHost ?? "").trim();
  const transport = input.transport ?? "udp";
  if (!["udp", "tcp", "third-party"].includes(transport))
    throw new Error("Invalid OSC transport");
  const displayName = String(input.displayName ?? "Element")
    .trim()
    .slice(0, 64);
  if (consoleHost && !isIPv4(consoleHost))
    throw new Error("Console address must be an IPv4 address.");
  const port = (value, name) => {
    const n = Number(value);
    if (!Number.isInteger(n) || n < 1024 || n > 65535)
      throw new Error(`${name} must be a port from 1024 to 65535.`);
    return n;
  };
  return {
    displayName,
    transport,
    consoleHost,
    consolePort: port(input.consolePort, "Console receive port"),
    receivePort: port(input.receivePort, "Bridge receive port"),
  };
}
export function validateMessage(msg) {
  if (
    !msg ||
    typeof msg.address !== "string" ||
    msg.address.length > 256 ||
    !/^\/eos(?:\/[^\s\x00-\x1f]+)*$/.test(msg.address)
  )
    return false;
  return (
    Array.isArray(msg.parameters) &&
    msg.parameters.length <= 64 &&
    msg.parameters.every(
      (v) =>
        (typeof v === "number" && Number.isFinite(v)) ||
        (typeof v === "string" && v.length <= 2048) ||
        typeof v === "boolean",
    )
  );
}
export async function createRemoteServer(options = {}) {
  const configPath = options.configPath ?? resolve(root, ".data/bridge.json");
  let saved = {};
  try {
    saved = JSON.parse(await readFile(configPath, "utf8"));
  } catch {}
  let config = validateConfig(
    options.config ?? {
      displayName: saved.displayName ?? "Element",
      transport: process.env.OSC_TRANSPORT ?? saved.transport ?? "tcp",
      consoleHost: process.env.OSC_HOST ?? saved.consoleHost ?? "",
      consolePort: process.env.OSC_PORT ?? saved.consolePort ?? 3032,
      receivePort: process.env.OSC_RECEIVE_PORT ?? saved.receivePort ?? 8001,
    },
  );
  const app = express(),
    http = createServer(app),
    wss = new WebSocketServer({
      noServer: true,
      maxPayload: 16384,
      perMessageDeflate: false,
    });
  let udp,
    udpReady = false,
    udpError = "",
    closed = false,
    lastPong = 0,
    pingToken = "",
    udpGeneration = 0,
    transportRetry,
    pingSent = 0,
    latencyMs = null;
  const cache = new Map();
  const status = () => ({
    type: "status",
    configured: !!config.consoleHost,
    consoleOnline: !!lastPong && Date.now() - lastPong < 25000,
    udpReady,
    error: udpError,
    latencyMs,
    config,
  });
  function broadcast(msg) {
    const text = JSON.stringify(msg);
    for (const client of wss.clients)
      if (client.readyState === WebSocket.OPEN) {
        if (client.bufferedAmount > 1024 * 1024) client.terminate();
        else client.send(text);
      }
  }
  function emitStatus() {
    broadcast(status());
  }
  function deliver(packet, depth = 0) {
    if (depth > 8) return;
    if (packet.packets) {
      packet.packets.slice(0, 64).forEach((p) => deliver(p, depth + 1));
      return;
    }
    if (
      typeof packet.address !== "string" ||
      !packet.address.startsWith("/eos/")
    )
      return;
    const parameters = (
      Array.isArray(packet.args)
        ? packet.args
        : packet.args === undefined
          ? []
          : [packet.args]
    ).map((v) => (v && typeof v === "object" && "value" in v ? v.value : v));
    if (packet.address === "/eos/out/ping" && parameters.includes(pingToken)) {
      lastPong = Date.now();
      latencyMs = lastPong - pingSent;
      emitStatus();
      return;
    }
    const msg = { type: "osc", address: packet.address, parameters };
    if (packet.address !== "/eos/out/ping") {
      cache.delete(packet.address);
      cache.set(packet.address, msg);
      if (cache.size > 1000) cache.delete(cache.keys().next().value);
    }
    broadcast(msg);
  }
  function sendOSC(address, parameters = []) {
    if (!udpReady || !config.consoleHost) return false;
    try {
      const args = parameters.map((v) =>
        typeof v === "number"
          ? { type: "f", value: v }
          : typeof v === "string"
            ? { type: "s", value: v }
            : { type: v ? "T" : "F", value: v },
      );
      const bytes = Buffer.from(
        osc.writePacket({ address, args }, { metadata: true }),
      );
      if (config.transport === "udp")
        udp.send(bytes, config.consolePort, config.consoleHost, (error) => {
          if (error) {
            udpError = error.message;
            emitStatus();
          }
        });
      else {
        if (udp.writableLength > 1024 * 1024) {
          udp.destroy();
          return false;
        }
        udp.write(encodeFrame(bytes, config.transport));
      }
      return true;
    } catch (error) {
      udpError = error.message;
      emitStatus();
      return false;
    }
  }
  function pingConsole() {
    if (!config.consoleHost) return;
    pingSent = Date.now();
    pingToken = "element-bridge-" + pingSent;
    sendOSC("/eos/ping", [pingToken]);
  }
  function closeTransport() {
    clearTimeout(transportRetry);
    if (udp) {
      try {
        if (typeof udp.destroy === "function") udp.destroy();
        else udp.close();
      } catch {}
    }
  }
  async function openUDP() {
    const current = ++udpGeneration;
    closeTransport();
    udpReady = false;
    udpError = "";
    lastPong = 0;
    if (config.transport !== "udp") {
      if (!config.consoleHost) {
        emitStatus();
        return;
      }
      const next = createConnection({
        host: config.consoleHost,
        port: config.consolePort,
      });
      udp = next;
      next.setNoDelay(true);
      next.setKeepAlive(true, 10000);
      const decode = createDecoder((bytes) => {
        try {
          deliver(osc.readPacket(bytes, { metadata: true }));
        } catch {}
      }, config.transport);
      next.on("connect", () => {
        if (current !== udpGeneration) return;
        udpReady = true;
        udpError = "";
        cache.clear();
        broadcast({ type: "reset" });
        emitStatus();
        pingConsole();
      });
      next.on("data", (bytes) => {
        if (current !== udpGeneration) return;
        try {
          decode(bytes);
        } catch (error) {
          udpError = error.message;
          next.destroy();
        }
      });
      next.on("error", (error) => {
        if (current !== udpGeneration) return;
        udpError = error.message;
        emitStatus();
      });
      next.on("close", () => {
        if (current !== udpGeneration || closed) return;
        udpReady = false;
        lastPong = 0;
        cache.clear();
        broadcast({ type: "reset" });
        emitStatus();
        transportRetry = setTimeout(openUDP, 3000);
      });
      emitStatus();
      return;
    }
    const next = dgram.createSocket("udp4");
    udp = next;
    next.on("error", (error) => {
      if (current !== udpGeneration) return;
      udpReady = false;
      udpError = error.message;
      emitStatus();
    });
    next.on("message", (bytes, remote) => {
      if (
        current !== udpGeneration ||
        !config.consoleHost ||
        remote.address !== config.consoleHost ||
        bytes.length > 65507
      )
        return;
      try {
        deliver(osc.readPacket(bytes, { metadata: true }));
      } catch {
        /* Invalid OSC datagrams cannot interrupt the bridge. */
      }
    });
    next.on("listening", () => {
      if (current !== udpGeneration) return;
      udpReady = true;
      emitStatus();
      pingConsole();
    });
    next.bind(config.receivePort, options.udpBind ?? "0.0.0.0");
  }
  app.disable("x-powered-by");
  app.use(compression());
  app.use(express.json({ limit: "8kb" }));
  app.use((req, res, next) => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "same-origin");
    next();
  });
  app.get("/api/health", (_req, res) => res.json({ ok: true, ...status() }));
  app.get("/api/config", (_req, res) => res.json(config));
  app.put("/api/config", async (req, res) => {
    try {
      // Browser settings mutations must originate from this site.
      if (
        req.headers.origin &&
        new URL(req.headers.origin).host !== req.headers.host
      )
        return res
          .status(403)
          .json({ error: "Cross-origin configuration is not allowed." });
      const updated = validateConfig(req.body);
      await mkdir(dirname(configPath), { recursive: true });
      await writeFile(
        configPath + ".tmp",
        JSON.stringify(updated, null, 2) + "\n",
        { mode: 0o600 },
      );
      await rename(configPath + ".tmp", configPath);
      config = updated;
      lastPong = 0;
      cache.clear();
      broadcast({ type: "reset" });
      await openUDP();
      emitStatus();
      res.json(config);
    } catch (error) {
      res.status(400).json({ error: error.message });
    }
  });
  const assets = options.dist ?? resolve(root, "dist");
  app.use(
    "/assets",
    express.static(resolve(assets, "assets"), {
      maxAge: "1y",
      immutable: true,
    }),
  );
  app.use(
    express.static(assets, {
      setHeaders: (res, path) => {
        if (path.endsWith(".html")) res.setHeader("Cache-Control", "no-cache");
      },
    }),
  );
  app.get("/", (_req, res) => res.sendFile(resolve(assets, "index.html")));
  app.use((error, _req, res, _next) =>
    res
      .status(400)
      .json({
        error:
          error.type === "entity.parse.failed" ? "Invalid JSON" : error.message,
      }),
  );
  http.on("upgrade", (req, socket, head) => {
    if (req.url !== "/ws/osc") {
      socket.destroy();
      return;
    }
    if (req.headers.origin) {
      try {
        if (new URL(req.headers.origin).host !== req.headers.host) {
          socket.destroy();
          return;
        }
      } catch {
        socket.destroy();
        return;
      }
    }
    wss.handleUpgrade(req, socket, head, (client) =>
      wss.emit("connection", client),
    );
  });
  wss.on("connection", (client) => {
    client.alive = true;
    client.on("pong", () => (client.alive = true));
    client.send(JSON.stringify(status()));
    for (const msg of cache.values()) client.send(JSON.stringify(msg));
    let windowStart = Date.now(),
      count = 0;
    client.on("message", (bytes) => {
      try {
        if (Date.now() - windowStart > 1000) {
          windowStart = Date.now();
          count = 0;
        }
        if (++count > 4000) {
          client.close(1008, "Command rate exceeded");
          return;
        }
        const msg = JSON.parse(bytes.toString());
        if (!validateMessage(msg)) {
          client.send(
            JSON.stringify({ type: "error", message: "Invalid OSC command" }),
          );
          return;
        }
        if (!sendOSC(msg.address, msg.parameters))
          client.send(
            JSON.stringify({
              type: "error",
              message: config.consoleHost
                ? "OSC socket unavailable"
                : "Set the console address in Connection first.",
            }),
          );
      } catch {
        client.send(
          JSON.stringify({ type: "error", message: "Invalid message" }),
        );
      }
    });
    client.on("error", () => {});
  });
  const ping = setInterval(() => {
    pingConsole();
    emitStatus();
  }, options.pingInterval ?? 10000);
  const heartbeat = setInterval(() => {
    for (const client of wss.clients) {
      if (client.alive === false) {
        client.terminate();
        continue;
      }
      client.alive = false;
      client.ping();
    }
  }, 30000);
  await openUDP();
  return {
    app,
    http,
    get config() {
      return config;
    },
    async listen(
      port = Number(process.env.PORT) || 8766,
      host = process.env.HOST || "0.0.0.0",
    ) {
      await new Promise((resolve, reject) => {
        http.once("error", reject);
        http.listen(port, host, resolve);
      });
      return http.address();
    },
    async close() {
      if (closed) return;
      closed = true;
      clearInterval(ping);
      clearInterval(heartbeat);
      for (const c of wss.clients) c.terminate();
      wss.close();
      closeTransport();
      await new Promise((r) => http.close(r));
    },
  };
}
if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const server = await createRemoteServer();
  const address = await server.listen();
  console.log(`Element Remote listening on ${address.address}:${address.port}`);
  for (const signal of ["SIGINT", "SIGTERM"])
    process.on(signal, async () => {
      await server.close();
      process.exit(0);
    });
}
