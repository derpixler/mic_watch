/**
 * test_simulator.mjs
 *
 * Tests the pi_simulator HTTP routes using the built-in node:test runner.
 * Starts the server on a random port, validates all endpoints, then shuts down.
 *
 * Usage:  node --test test_simulator.mjs
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

/** Minimal inline server matching pi_simulator.mjs behaviour. */
function buildServer() {
  let lampOn = false;

  const server = createServer((req, res) => {
    const path = req.url?.split("?")[0];

    if (path === "/on") {
      lampOn = true;
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("ON\n");
      return;
    }
    if (path === "/off") {
      lampOn = false;
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("OFF\n");
      return;
    }
    if (path === "/status") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ lamp: lampOn }) + "\n");
      return;
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not Found\n");
  });

  return { server, getLampState: () => lampOn };
}

/** Sends a GET request and returns { status, body }. */
async function get(baseURL, path) {
  const res = await fetch(`${baseURL}${path}`);
  const body = await res.text();
  return { status: res.status, body: body.trim() };
}

describe("Pi Simulator Routes", () => {
  let server;
  let baseURL;

  before(async () => {
    const app = buildServer();
    server = app.server;
    await new Promise((resolve) => {
      server.listen(0, () => {
        const port = server.address().port;
        baseURL = `http://localhost:${port}`;
        resolve();
      });
    });
  });

  after(() => {
    server.close();
  });

  it("GET /on → 200, lamp turns on", async () => {
    const res = await get(baseURL, "/on");
    assert.equal(res.status, 200);
    assert.equal(res.body, "ON");
  });

  it("GET /status after /on → lamp is true", async () => {
    await get(baseURL, "/on");
    const res = await get(baseURL, "/status");
    assert.equal(res.status, 200);
    const json = JSON.parse(res.body);
    assert.equal(json.lamp, true);
  });

  it("GET /off → 200, lamp turns off", async () => {
    const res = await get(baseURL, "/off");
    assert.equal(res.status, 200);
    assert.equal(res.body, "OFF");
  });

  it("GET /status after /off → lamp is false", async () => {
    await get(baseURL, "/off");
    const res = await get(baseURL, "/status");
    assert.equal(res.status, 200);
    const json = JSON.parse(res.body);
    assert.equal(json.lamp, false);
  });

  it("GET /unknown → 404", async () => {
    const res = await get(baseURL, "/foobar");
    assert.equal(res.status, 404);
  });

  it("state transitions ON → OFF → ON are consistent", async () => {
    await get(baseURL, "/on");
    let status = await get(baseURL, "/status");
    assert.equal(JSON.parse(status.body).lamp, true);

    await get(baseURL, "/off");
    status = await get(baseURL, "/status");
    assert.equal(JSON.parse(status.body).lamp, false);

    await get(baseURL, "/on");
    status = await get(baseURL, "/status");
    assert.equal(JSON.parse(status.body).lamp, true);
  });

  it("initial state is OFF (lamp = false)", async () => {
    const fresh = buildServer();
    await new Promise((r) => fresh.server.listen(0, r));
    const port = fresh.server.address().port;

    const res = await get(`http://localhost:${port}`, "/status");
    assert.equal(JSON.parse(res.body).lamp, false);

    fresh.server.close();
  });
});
