/**
 * pi_server.mjs
 *
 * HTTP server for the On Air lamp. Receives mic state from mic_watch.swift,
 * controls a USB lamp via shell commands, and serves an SSE-powered
 * web display as secondary indicator.
 *
 * Routes:
 *   GET /        – ON AIR display (HTML)
 *   GET /on      – turn lamp on
 *   GET /off     – turn lamp off
 *   GET /status  – JSON status
 *   GET /events  – SSE stream of lamp state changes
 *
 * Usage:  node pi_server.mjs
 */

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { exec } from "node:child_process";

// ---------------------------------------------------------------------------
// .env loader
// ---------------------------------------------------------------------------

/** Reads .env from the script directory. Returns parsed key-value pairs. */
function loadEnv() {
  try {
    const content = readFileSync(new URL(".env", import.meta.url), "utf-8");
    const env = {};
    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      env[key] = value;
    }
    return env;
  } catch {
    return {};
  }
}

const dotenv = loadEnv();

/** Resolves config: process env → .env → fallback. */
function cfg(key, fallback = "") {
  return process.env[key] ?? dotenv[key] ?? fallback;
}

const HOST         = cfg("PI_HOST", "localhost");
const PORT         = parseInt(cfg("PI_PORT", "8080"), 10);
const LAMP_CMD_ON  = cfg("LAMP_CMD_ON");
const LAMP_CMD_OFF = cfg("LAMP_CMD_OFF");

// ---------------------------------------------------------------------------
// State & SSE
// ---------------------------------------------------------------------------

let lampOn = false;

/** Connected SSE clients (Set of `http.ServerResponse`). */
const sseClients = new Set();

/**
 * Executes a shell command to control the physical USB lamp.
 * Skipped silently when no command is configured (simulator mode).
 */
function execLampCmd(cmd, label) {
  if (!cmd) return;
  exec(cmd, (err, stdout, stderr) => {
    if (err) {
      console.log(`[${timestamp()}]  ⚠️  Lamp ${label} command failed: ${err.message}`);
      return;
    }
    console.log(`[${timestamp()}]  💡  Lamp ${label} command executed`);
  });
}

/** Sends a lamp-state event to every connected SSE client. */
function broadcastState() {
  const data = JSON.stringify({ lamp: lampOn });
  for (const client of sseClients) {
    client.write(`data: ${data}\n\n`);
  }
  console.log(`[${timestamp()}]  📡  SSE broadcast → lamp: ${lampOn}  (${sseClients.size} client(s))`);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function timestamp() {
  return new Date().toISOString().replace("T", " ").slice(0, 19);
}

let requestCount = 0;

// ---------------------------------------------------------------------------
// ON AIR HTML page (inlined to avoid extra files)
// ---------------------------------------------------------------------------

const ON_AIR_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ON AIR</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  html,body{width:100%;height:100%;overflow:hidden;font-family:-apple-system,system-ui,sans-serif}
  body{display:flex;align-items:center;justify-content:center;
       transition:background .4s ease,color .4s ease}
  body.off{background:#111;color:#333}
  body.on{background:#c0392b;color:#fff}
  .label{font-size:18vw;font-weight:900;letter-spacing:.04em;text-transform:uppercase;
         user-select:none;opacity:0;transition:opacity .4s ease}
  body.on .label{opacity:1}
  .dot{display:inline-block;width:.15em;height:.15em;border-radius:50%;
       background:#fff;margin-right:.15em;vertical-align:middle;
       animation:pulse 1.2s ease-in-out infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  .status{position:fixed;bottom:1.5vh;right:2vw;font-size:1.4vh;opacity:.35}
</style>
</head>
<body class="off">
  <div class="label"><span class="dot"></span>ON AIR</div>
  <div class="status" id="status">connecting…</div>
<script>
(function(){
  var body=document.body, statusEl=document.getElementById("status");
  function apply(lamp){
    body.className=lamp?"on":"off";
    statusEl.textContent=lamp?"active":"standby";
  }
  function connect(){
    var es=new EventSource("/events");
    es.onopen=function(){statusEl.textContent="connected";};
    es.onmessage=function(e){
      try{var d=JSON.parse(e.data);apply(d.lamp);}catch(err){}
    };
    es.onerror=function(){
      statusEl.textContent="reconnecting…";
      es.close();
      setTimeout(connect,2000);
    };
  }
  // Fetch initial state, then open SSE stream
  fetch("/status").then(function(r){return r.json();})
    .then(function(d){apply(d.lamp);})
    .catch(function(){})
    .finally(connect);

  // Keep-Silk-Open: plays silent audio to prevent Echo Show from closing the browser
  try{
    var ctx=new(window.AudioContext||window.webkitAudioContext)();
    var osc=ctx.createOscillator();
    var gain=ctx.createGain();
    gain.gain.value=0;
    osc.connect(gain);gain.connect(ctx.destination);
    osc.start();
  }catch(e){}
})();
</script>
</body>
</html>`;

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

const server = createServer((req, res) => {
  const path = req.url?.split("?")[0];
  requestCount++;
  const stateLabel = lampOn ? "ON 🔴" : "OFF ⚪";
  console.log(`[${timestamp()}]  #${requestCount}  ${req.method} ${path}  (lamp: ${stateLabel})`);

  // -- ON AIR display page --------------------------------------------------
  if (path === "/") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(ON_AIR_HTML);
    return;
  }

  // -- SSE event stream ------------------------------------------------------
  if (path === "/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    });
    res.write(`data: ${JSON.stringify({ lamp: lampOn })}\n\n`);
    sseClients.add(res);
    console.log(`[${timestamp()}]  🔗  SSE client connected  (${sseClients.size} total)`);

    req.on("close", () => {
      sseClients.delete(res);
      console.log(`[${timestamp()}]  🔌  SSE client disconnected  (${sseClients.size} remaining)`);
    });
    return;
  }

  // -- Lamp ON ---------------------------------------------------------------
  if (path === "/on") {
    lampOn = true;
    console.log(`[${timestamp()}]  🔴  Lamp ON   ← ${req.method} ${req.url}`);
    execLampCmd(LAMP_CMD_ON, "ON");
    broadcastState();
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ON\n");
    return;
  }

  // -- Lamp OFF --------------------------------------------------------------
  if (path === "/off") {
    lampOn = false;
    console.log(`[${timestamp()}]  ⚪  Lamp OFF  ← ${req.method} ${req.url}`);
    execLampCmd(LAMP_CMD_OFF, "OFF");
    broadcastState();
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("OFF\n");
    return;
  }

  // -- Status JSON -----------------------------------------------------------
  if (path === "/status") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ lamp: lampOn }) + "\n");
    return;
  }

  // -- 404 -------------------------------------------------------------------
  console.log(`[${timestamp()}]  ⚠️   Unknown route: ${req.method} ${req.url}`);
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not Found\n");
});

server.listen(PORT, HOST, () => {
  console.log(`[${timestamp()}]  🚀  Pi server listening on http://${HOST}:${PORT}`);
  console.log(`[${timestamp()}]  Routes: /  /on  /off  /status  /events`);
  if (LAMP_CMD_ON) {
    console.log(`[${timestamp()}]  💡  Lamp commands configured (ON: "${LAMP_CMD_ON}")`);
  } else {
    console.log(`[${timestamp()}]  ℹ️   No LAMP_CMD_ON set – running in simulator mode`);
  }
});
