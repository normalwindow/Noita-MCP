#!/usr/bin/env node
/**
 * Noita AI Agent Bridge -- MCP server (stdio).
 *
 * Zero runtime dependencies: implements the MCP JSON-RPC handshake directly so
 * it works on a machine without npm registry access.
 *
 * Transport to the game is a request/response file pair inside the mod folder:
 *   <noitaDir>/mods/noita_agent/run/state.json     <- world snapshot (game writes)
 *   <noitaDir>/mods/noita_agent/run/request.json   <- command        (we write)
 *   <noitaDir>/mods/noita_agent/run/response.json  <- reply          (game writes)
 *   <noitaDir>/mods/noita_agent/run/status.json    <- bridge health
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');
const http = require('http');
const { spawnSync } = require('child_process');

const SERVER_NAME = 'noita-agent-bridge';
const SERVER_VERSION = '1.0.0';
const PROTOCOL_VERSION = '2024-11-05';

// ---------------------------------------------------------------- wand simulator
//
// Predicting what a wand will actually do needs the "deck model" (draw counts,
// cast blocks, wrap, charge accumulation). That is already implemented, and
// validated against the community model, by the noita-wand-editing skill's
// simulator -- so we call it instead of reimplementing it here.
//
// Its built-in spell table only covers the commonly used spells; anything it
// does not know is treated as a neutral projectile. Unknown ids are therefore
// reported back in the result instead of being silently approximated.

function findWandSim() {
  const explicit = process.env.NOITA_WAND_SIM;
  if (explicit && fs.existsSync(explicit)) return explicit;
  const candidates = [
    path.join(os.homedir(), '.dsh', 'skills', 'noita-wand-editing', 'scripts', 'wand_sim.py'),
    path.join(os.homedir(), '.agents', 'skills', 'noita-wand-editing', 'scripts', 'wand_sim.py'),
    'D:\\STRARG\\GHCode\\myNoitaMod\\.dsh\\skills\\noita-wand-editing\\scripts\\wand_sim.py',
  ];
  for (const c of candidates) { try { if (fs.existsSync(c)) return c; } catch (_) { /* ignore */ } }
  return null;
}

function findPython() {
  const explicit = process.env.NOITA_PYTHON;
  if (explicit) return explicit;
  for (const c of ['python', 'py', 'python3']) {
    const probe = spawnSync(c, ['--version'], { encoding: 'utf8', timeout: 5000 });
    if (!probe.error && probe.status === 0) return c;
  }
  return null;
}

let simSpellTable = null;
function simKnownSpells(python, simPath) {
  if (simSpellTable) return simSpellTable;
  const res = spawnSync(python, [simPath, '--list-spells'], { encoding: 'utf8', timeout: 20000 });
  const text = `${res.stdout || ''}\n${res.stderr || ''}`;
  const ids = new Set();
  for (const line of text.split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)\s+(projectile|modifier|multicast|material|other|static|utility|passive)\b/i);
    if (m) ids.add(m[1].toUpperCase());
  }
  simSpellTable = ids;
  return ids;
}

function runWandSim(args, switches) {
  const simPath = findWandSim();
  if (!simPath) {
    throw new Error('wand simulator not found. Install the noita-wand-editing skill, ' +
      'or set NOITA_WAND_SIM to the path of wand_sim.py');
  }
  const python = findPython();
  if (!python) {
    throw new Error('python not found on PATH; set NOITA_PYTHON to a python executable');
  }

  const argv = [simPath];
  for (const [flag, value] of Object.entries(args)) {
    if (value === undefined || value === null) continue;
    argv.push(flag, String(value));
  }
  // boolean flags take no value; passing one makes argparse reject the call
  for (const flag of switches || []) argv.push(flag);

  const res = spawnSync(python, argv, { encoding: 'utf8', timeout: 60000 });
  const stdout = res.stdout || '';
  const stderr = res.stderr || '';
  if (res.error) throw new Error(`failed to run simulator: ${res.error.message}`);

  // the simulator prints a human summary before the JSON block
  const start = stdout.indexOf('[');
  let rounds = null;
  if (start >= 0) {
    try { rounds = JSON.parse(stdout.slice(start)); } catch (_) { rounds = null; }
  }
  return { stdout, stderr, rounds, argv };
}

function parseSimWarnings(stderr) {
  const unknown = [];
  for (const line of String(stderr).split('\n')) {
    const m = line.match(/\[警告\] 未收录的法术 '([^']+)'/);
    if (m) unknown.push(m[1]);
  }
  return unknown;
}

// ---------------------------------------------------------------- entity catalog
//
// The game ships ~3000 entity definitions and the mod could only ever see the
// handful near the player. This index is built from the unpacked game data and
// lets the AI find an entity by name, tag or kind, which is what turns "spawn a
// big chest" into an executable request instead of a guess.
//
// It lives here rather than in the mod because searching it is pure string work;
// keeping it gameside would mean reading a 600KB file into the Lua state.

// Looks for the unpacked game data.
//
// The game ships its entity definitions packed inside data/data.wak, so there is no
// data/entities folder until the user unpacks it with the game's own switch
// (tools/unpak.ps1 runs `noita.exe -wizard_unpak`).
//
// The definitions are NOT bundled with this project: the Noita Modding Agreement
// forbids redistributing the game's content. So this reads whatever the user has
// unpacked locally, and says how to produce it if nothing is found.
function findGameDirFallback() {
  // Deliberately independent of the NOITA_DIR const below, which is initialised
  // further down the file; this runs earlier and must not hit its temporal dead zone.
  const cands = [process.env.NOITA_DIR, process.env.NOITA_PATH].filter(Boolean);
  for (const d of ['C', 'D', 'E', 'F']) {
    cands.push(`${d}:\\Program Files (x86)\\Steam\\steamapps\\common\\Noita`);
    cands.push(`${d}:\\Program Files\\Steam\\steamapps\\common\\Noita`);
    cands.push(`${d}:\\Steam\\steamapps\\common\\Noita`);
    cands.push(`${d}:\\SteamLibrary\\steamapps\\common\\Noita`);
    cands.push(`${d}:\\Games\\Steam\\steamapps\\common\\Noita`);
  }
  for (const c of cands) {
    try { if (fs.existsSync(path.join(c, 'noita.exe'))) return c; } catch (_) { /* ignore */ }
  }
  return null;
}

function findRefData() {
  const gameDir = findGameDirFallback();
  const candidates = [
    process.env.NOITA_REF_DATA,
    gameDir && path.join(gameDir, 'data'),
    gameDir && path.join(gameDir, 'mods', 'noita_agent', 'files', 'data'),
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      if (c && fs.existsSync(path.join(c, 'entities'))) return c;
    } catch (_) { /* ignore */ }
  }
  return null;
}

// Local reader so this section does not depend on readJson being defined below.
function readJsonFile(file) {
  try {
    const t = fs.readFileSync(file, 'utf8');
    return t ? JSON.parse(t) : null;
  } catch (_) {
    return null;
  }
}

let entityIndexCache;
let entityIndexPath = null;
function findEntityIndex() {
  if (entityIndexCache !== undefined) return entityIndexCache;
  const candidates = [
    process.env.NOITA_ENTITY_INDEX,
    path.join(__dirname, 'entity_index.json'),
    path.join(__dirname, '..', 'data', 'entity_index.json'),
    path.join(__dirname, '..', '..', 'tools', 're', 'entity_index.json'),
  ].filter(Boolean);
  for (const c of candidates) {
    const j = readJsonFile(c);
    if (j && Array.isArray(j.entities)) {
      entityIndexCache = j;
      entityIndexPath = c;
      return j;
    }
  }
  entityIndexCache = null;
  return null;
}

// The fact database: identifiers, numbers and relationships extracted from the game
// data, with the game's own files deliberately not reproduced. One prebuilt copy
// ships with the server; tools/build_db.py regenerates it from a local unpack.
let factDbCache;
let factDbPath = null;
function findFactDb() {
  if (factDbCache !== undefined) return factDbCache;
  const candidates = [
    process.env.NOITA_DB,
    path.join(__dirname, 'noita_db.json'),
    path.join(__dirname, '..', 'data', 'noita_db.json'),
    path.join(__dirname, '..', '..', 'tools', 're', 'noita_db.json'),
  ].filter(Boolean);
  for (const c of candidates) {
    const j = readJsonFile(c);
    if (j && j.entities) {
      factDbCache = j;
      factDbPath = c;
      return j;
    }
  }
  factDbCache = null;
  return null;
}

// Ranked substring search over one array of records. Every term must appear
// somewhere in the record; an exact key match ranks above a substring one.
function searchRecords(rows, terms, keyFields, limit) {
  if (!terms.length) return rows.slice(0, limit);
  const scored = [];
  for (const r of rows) {
    const hay = JSON.stringify(r).toLowerCase();
    let s = 0, ok = true;
    for (const t of terms) {
      if (!hay.includes(t)) { ok = false; break; }
      s += 1;
      for (const f of keyFields) {
        const v = r[f];
        if (typeof v === 'string' && v.toLowerCase() === t) { s += 6; break; }
        if (typeof v === 'string' && v.toLowerCase().includes(t)) { s += 3; break; }
      }
    }
    if (ok) scored.push([s, r]);
  }
  scored.sort((a, b) => b[0] - a[0]);
  return scored.slice(0, limit).map((x) => x[1]);
}

// All needles must appear; file-name hits rank highest, then the localised name.
function scoreEntity(e, needles) {
  const file = (e.file || '').toLowerCase();
  const nm = (e.name || '').toLowerCase();
  const hay = `${e.path} ${file} ${e.tags} ${nm}`.toLowerCase();
  let s = 0;
  for (const n of needles) {
    if (!hay.includes(n)) return -1;
    if (file.includes(n)) s += 3;
    if (nm.includes(n)) s += 2;
    s += 1;
  }
  return s;
}

// ---------------------------------------------------------------- game dir

function candidateSteamRoots() {
  const roots = [
    process.env.NOITA_DIR,
    process.env.NOITA_PATH,
    'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Noita',
    'C:\\Program Files\\Steam\\steamapps\\common\\Noita',
    'D:\\Steam\\steamapps\\common\\Noita',
    'D:\\SteamLibrary\\steamapps\\common\\Noita',
    'E:\\SteamLibrary\\steamapps\\common\\Noita',
  ].filter(Boolean);

  // steam library folders, if the standard install locations missed
  const vdf = [
    'C:\\Program Files (x86)\\Steam\\steamapps\\libraryfolders.vdf',
    'C:\\Program Files\\Steam\\steamapps\\libraryfolders.vdf',
    'C:\\Steam\\steamapps\\libraryfolders.vdf',
    'D:\\Steam\\steamapps\\libraryfolders.vdf',
    'D:\\Sware\\Steam\\steamapps\\libraryfolders.vdf',
    'D:\\SteamLibrary\\steamapps\\libraryfolders.vdf',
    'E:\\SteamLibrary\\steamapps\\libraryfolders.vdf',
    'E:\\Steam\\steamapps\\libraryfolders.vdf',
  ];
  for (const file of vdf) {
    try {
      const text = fs.readFileSync(file, 'utf8');
      for (const m of text.matchAll(/"path"\s*"([^"]+)"/g)) {
        roots.push(path.join(m[1].replace(/\\\\/g, '\\'), 'steamapps', 'common', 'Noita'));
      }
    } catch (_) { /* ignore */ }
  }
  return roots;
}

function isNoitaDir(dir) {
  try {
    return fs.existsSync(path.join(dir, 'noita.exe')) || fs.existsSync(path.join(dir, 'data', 'data.wak'));
  } catch (_) {
    return false;
  }
}

function resolveNoitaDir() {
  for (const dir of candidateSteamRoots()) {
    if (dir && isNoitaDir(dir)) return dir;
  }
  return null;
}

const NOITA_DIR = resolveNoitaDir();
// NOITA_AGENT_RUN_DIR points the bridge at an explicit run/ folder. It exists so
// the test harness can exercise the whole request/response path without a game.
const RUN_DIR = process.env.NOITA_AGENT_RUN_DIR
  || (NOITA_DIR ? path.join(NOITA_DIR, 'mods', 'noita_agent', 'run') : null);

function filePaths() {
  return {
    run: RUN_DIR,
    state: RUN_DIR && path.join(RUN_DIR, 'state.json'),
    request: RUN_DIR && path.join(RUN_DIR, 'request.json'),
    response: RUN_DIR && path.join(RUN_DIR, 'response.json'),
    status: RUN_DIR && path.join(RUN_DIR, 'status.json'),
    ready: RUN_DIR && path.join(RUN_DIR, 'ready.json'),
    // written by the game when the socket transport is listening
    port: RUN_DIR && path.join(RUN_DIR, 'port.json'),
    log: RUN_DIR && path.join(RUN_DIR, 'bridge.log'),
  };
}

// ---------------------------------------------------------------- transport
//
// Two channels, same methods:
//   socket : localhost HTTP, preferred by default when the game is listening
//   file   : the request/response files, always available as the fallback
//
// The socket only wins on BATCHED calls (one round trip for several methods); a
// single call is quantised to one 16.7ms frame either way. So the socket is the
// default preference, and every call falls back to the file bridge on any socket
// problem -- the AI must never be stranded by a transport choice.

let useSocket = true;
let socketFailures = 0;
const SOCKET_FAILURE_LIMIT = 3;
let socketDisabledUntil = 0;

let httpAgent = null;
function socketCall(port, payload, timeoutMs = 6000) {
  return new Promise((resolve, reject) => {
    if (!httpAgent) httpAgent = new http.Agent({ keepAlive: true, maxSockets: 2 });
    const body = JSON.stringify(payload);
    const req = http.request({
      host: '127.0.0.1', port, method: 'POST', path: '/rpc', agent: httpAgent,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('bad JSON from socket')); }
      });
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error('socket timeout')));
    req.on('error', reject);
    req.end(body);
  });
}

function socketPort() {
  const p = readJson(filePaths().port);
  if (p && typeof p.port === 'number' && p.port > 0) return p.port;
  return null;
}

function transportReport() {
  const port = socketPort();
  const suspended = Date.now() < socketDisabledUntil;
  return {
    preference: useSocket ? 'socket' : 'file',
    socket_available: port !== null,
    socket_port: port,
    socket_failures: socketFailures,
    socket_suspended_until_reset: suspended,
    effective: (useSocket && port !== null && !suspended) ? 'socket' : 'file',
    note: 'socket wins on batched calls; single calls cost one frame either way',
  };
}

// ---------------------------------------------------------------- bridge client

let requestSeq = Math.floor(Date.now() % 1000000);

function readJson(file) {
  try {
    const text = fs.readFileSync(file, 'utf8');
    if (!text) return null;
    return JSON.parse(text);
  } catch (_) {
    return null;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Round-trip instrumentation. Real-time behaviour should be measured, not
// asserted, so every call records how long it took and the stats are exposed.
const rpcStats = { count: 0, totalMs: 0, maxMs: 0, lastMs: 0, samples: [] };
const MAX_RTT_SAMPLES = 50;

function recordRtt(ms) {
  rpcStats.count += 1;
  rpcStats.totalMs += ms;
  rpcStats.lastMs = ms;
  if (ms > rpcStats.maxMs) rpcStats.maxMs = ms;
  rpcStats.samples.push(ms);
  if (rpcStats.samples.length > MAX_RTT_SAMPLES) rpcStats.samples.shift();
}

function rttReport() {
  const s = rpcStats.samples;
  if (!s.length) return { calls: rpcStats.count, samples: 0 };
  const sorted = [...s].sort((a, b) => a - b);
  return {
    calls: rpcStats.count,
    samples: s.length,
    rtt_ms_last: rpcStats.lastMs,
    rtt_ms_avg: Math.round((rpcStats.totalMs / rpcStats.count) * 10) / 10,
    rtt_ms_p50: sorted[Math.floor(sorted.length / 2)],
    rtt_ms_max: rpcStats.maxMs,
    note: 'round trip from this process to the game and back',
  };
}

// The file transport. Always available; used directly and as the fallback.
async function rpcFileRaw(payload, timeoutMs = 8000) {
  const p = filePaths();
  if (!p.run) {
    throw new Error(
      'Noita install not found. Set the NOITA_DIR environment variable to the folder containing noita.exe.'
    );
  }
  if (!fs.existsSync(p.run)) {
    throw new Error(
      `Bridge run folder missing: ${p.run}. Install the mod and start a run with "Noita AI Agent Bridge" enabled.`
    );
  }

  const started = Date.now();
  const id = payload.id !== undefined ? payload.id : ++requestSeq;
  // clear a stale reply so we cannot read the previous answer as this one
  try { fs.unlinkSync(p.response); } catch (_) { /* ignore */ }

  const body = JSON.stringify({ ...payload, id, ts: started });
  // write via a temp file + rename so the game never reads a partial write
  const tmp = p.request + '.tmp';
  fs.writeFileSync(tmp, body, 'utf8');
  fs.renameSync(tmp, p.request);

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = readJson(p.response);
    if (res && res.id === id) {
      recordRtt(Date.now() - started);
      return res;
    }
    // 5ms rather than 40ms: the game answers within a frame, so a coarse poll
    // would add up to 40ms of pure client-side delay to every call.
    await sleep(5);
  }
  recordRtt(Date.now() - started);
  throw new Error(
    `Timed out after ${timeoutMs}ms waiting for the game (method=${payload.method}). ` +
    'Is Noita running with the mod enabled and a run in progress?'
  );
}

// Sends one call over the preferred transport, falling back to files.
// Returns the response body only, to keep every existing caller unchanged.
async function rpc(method, params = {}, { timeoutMs = 8000 } = {}) {
  const port = socketPort();
  const suspended = Date.now() < socketDisabledUntil;

  if (useSocket && port !== null && !suspended) {
    try {
      const started = Date.now();
      const res = await socketCall(port, { method, params }, timeoutMs);
      recordRtt(Date.now() - started);
      socketFailures = 0;
      return res;
    } catch (_) {
      socketFailures += 1;
      if (socketFailures >= SOCKET_FAILURE_LIMIT) {
        // stop paying the socket timeout on every call; retry later
        socketDisabledUntil = Date.now() + 15000;
      }
    }
  }
  return rpcFileRaw({ method, params }, timeoutMs);
}

// Several methods in ONE round trip. This is what the socket is actually for:
// a single call costs one frame either way, but N calls batched cost one trip.
async function rpcBatch(calls, { timeoutMs = 10000 } = {}) {
  const port = socketPort();
  const suspended = Date.now() < socketDisabledUntil;

  if (useSocket && port !== null && !suspended) {
    try {
      const started = Date.now();
      const res = await socketCall(port, { calls }, timeoutMs);
      recordRtt(Date.now() - started);
      socketFailures = 0;
      if (res && res.ok) return { results: res.results, transport: 'socket' };
    } catch (_) {
      socketFailures += 1;
      if (socketFailures >= SOCKET_FAILURE_LIMIT) socketDisabledUntil = Date.now() + 15000;
    }
  }

  // file fallback: sequential, which is exactly the cost the socket avoids
  const results = [];
  for (const c of calls) {
    try {
      results.push(await rpcFileRaw({ method: c.method, params: c.params }, timeoutMs));
    } catch (err) {
      results.push({ ok: false, error: err.message, method: c.method });
    }
  }
  return { results, transport: 'file' };
}

// Latency of the whole MCP path as the client sees it.
function rttTool() {
  return {
    client: rttReport(),
    transport: transportReport(),
    hint: 'If p50 is far above ~20ms, the game is not polling every frame; check noita_get_panel latency sliders.',
  };
}

async function bridgeStatus() {
  const p = filePaths();
  const status = readJson(p.status);
  const ready = readJson(p.ready);
  const state = readJson(p.state);
  let log = null;
  try { log = fs.readFileSync(p.log, 'utf8').split('\n').slice(-30).join('\n'); } catch (_) { /* ignore */ }

  // The game's os.time may be missing in a stripped sandbox, in which case ts is
  // 0. Fall back to the file mtime so staleness is still measurable.
  let stateAgeMs = null;
  try {
    const st = fs.statSync(p.state);
    if (state && state.ts > 0) {
      // ts is seconds; compare against wall clock seconds
      stateAgeMs = Math.max(0, (Date.now() / 1000 - state.ts) * 1000);
    } else {
      stateAgeMs = Date.now() - st.mtimeMs;
    }
  } catch (_) { /* no state file yet */ }

  const bridgeLive = !!(ready && ready.ready) && stateAgeMs !== null && stateAgeMs < 5000;

  return {
    noita_dir: NOITA_DIR,
    run_dir: p.run,
    installed: !!(p.run && fs.existsSync(p.run)),
    mod_present: !!(NOITA_DIR && fs.existsSync(path.join(NOITA_DIR, 'mods', 'noita_agent', 'mod.xml'))),
    bridge_live: bridgeLive,
    hint: bridgeLive
      ? 'Bridge is live; the game is running a session.'
      : 'Bridge not live. Start Noita and begin/continue a run with the mod enabled.',
    ready_file: ready,
    status_file: status,
    state_age_ms: stateAgeMs,
    last_log_lines: log,
  };
}

// ---------------------------------------------------------------- tools

const SPELL_SCHEMA = {
  description: 'Array of spell entries. Each entry is an action id string (e.g. "LIGHT_BULLET") ' +
    'or an object {"id":"LIGHT_BULLET","always_cast":false}.',
  type: 'array',
  items: {
    anyOf: [
      { type: 'string' },
      {
        type: 'object',
        properties: {
          id: { type: 'string' },
          always_cast: { type: 'boolean' },
        },
        required: ['id'],
      },
    ],
  },
};

const WAND_ATTRS = {
  mana: { type: 'number', description: 'current mana' },
  mana_max: { type: 'number' },
  mana_charge_speed: { type: 'number' },
  actions_per_round: { type: 'integer', description: 'spells cast per click' },
  deck_capacity: { type: 'integer', description: 'how many spells fit (always-casts included)' },
  reload_time: { type: 'integer', description: 'recharge time in frames (60 = 1s)' },
  shuffle: { type: 'boolean', description: 'shuffle deck when empty' },
  fire_rate_wait: { type: 'integer', description: 'cast delay in frames' },
  spread_degrees: { type: 'number' },
  speed_multiplier: { type: 'number' },
  gun_level: { type: 'integer' },
  name: { type: 'string', description: 'wand display name' },
  sprite: { type: 'string', description: 'wand sprite xml path, e.g. data/items_gfx/wands/wand_0006.xml' },
};

const TOOLS = [
  {
    name: 'noita_bridge_status',
    description: 'Health check for the game<->MCP bridge: install paths, whether the mod is loaded, bridge ready flag and recent mod log lines. Call this first when something fails.',
    inputSchema: { type: 'object', properties: {} },
    handler: async () => bridgeStatus(),
  },
  {
    name: 'noita_get_state',
    description: 'Full snapshot: player vitals/position/effects/perks, nearby entities, all carried wands with their spell decks, and inventory. This is the main "look around" call.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('get_state'),
  },
  {
    name: 'noita_get_player',
    description: 'Player vitals only: hp, max_hp, position, velocity, gold, status effects, perks, current biome.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('get_player'),
  },
  {
    name: 'noita_get_nearby',
    description: 'Entities within a radius of the player, nearest first: name, kind (creature/item/wand/potion/spell/prop), hp, distance, angle, tags.',
    inputSchema: {
      type: 'object',
      properties: {
        radius: { type: 'number', description: 'pixels, default 200' },
        limit: { type: 'integer', description: 'max entries, default 40' },
        tag: { type: 'string', description: 'optional entity tag filter, e.g. "wand", "item", "mortal"' },
      },
    },
    handler: (args) => rpc('get_nearby', args),
  },
  {
    name: 'noita_raycast',
    description: 'Cast a ray from the player toward an angle or offset to test line of sight / terrain. Returns whether something was hit and where.',
    inputSchema: {
      type: 'object',
      properties: {
        angle: { type: 'number', description: 'degrees, 0 = right, 90 = down' },
        distance: { type: 'number', description: 'ray length in pixels, default 200' },
        dx: { type: 'number' },
        dy: { type: 'number' },
        mode: { type: 'string', enum: ['surfaces', 'platforms', 'surfaces_and_liquiform', 'all'] },
      },
    },
    handler: (args) => rpc('raycast', args),
  },
  {
    name: 'noita_get_inventory',
    description: 'List everything the player carries: kind (wand/potion/spell/item), readable name, inventory slot, and which one is active.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('get_inventory'),
  },
  {
    name: 'noita_get_wands',
    description: 'All wands the player carries with full attributes and ordered spell decks. Set held_only to inspect only the active wand.',
    inputSchema: {
      type: 'object',
      properties: { held_only: { type: 'boolean' } },
    },
    handler: async (args) => {
      if (args && args.held_only) return rpc('get_held_wand');
      return rpc('get_wands');
    },
  },
  {
    name: 'noita_list_spells',
    description: 'Catalog of every spell id the game knows (including mods), with readable names, type, mana cost and max uses. Use filter to search by id or name substring.',
    inputSchema: {
      type: 'object',
      properties: { filter: { type: 'string' } },
    },
    handler: (args) => rpc('list_spells', args),
  },
  {
    name: 'noita_list_materials',
    description: 'Catalog of material ids usable in potions (liquids, sands, gases, solids) with readable names.',
    inputSchema: {
      type: 'object',
      properties: {
        filter: { type: 'string' },
        limit: { type: 'integer', description: 'default 400' },
      },
    },
    handler: (args) => rpc('list_materials', args),
  },
  {
    name: 'noita_set_player',
    description: 'Modify the player: teleport (x/y), set rotation, hp/max_hp, invincibility frames, gold (money set or money_add), velocity, air. Only the fields you pass are changed.',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number' },
        y: { type: 'number' },
        rotation: { type: 'number', description: 'radians' },
        hp: { type: 'number' },
        max_hp: { type: 'number' },
        max_hp_cap: { type: 'number', description: 'upper limit the game allows max_hp to reach' },
        invincibility_frames: { type: 'number', description: 'frames of damage immunity (60 = 1s)' },
        money: { type: 'number', description: 'absolute gold amount' },
        money_add: { type: 'number', description: 'gold delta' },
        infinite_money: { type: 'boolean' },
        vx: { type: 'number' },
        vy: { type: 'number' },
        air: { type: 'number' },
      },
    },
    handler: (args) => rpc('set_player', args),
  },
  {
    name: 'noita_heal',
    description: 'Restore the player. fraction defaults to 1 (full heal); max_hp optionally raises the cap first.',
    inputSchema: {
      type: 'object',
      properties: {
        fraction: { type: 'number', description: '0..1 of max hp, default 1' },
        hp: { type: 'number', description: 'absolute hp value, wins over fraction' },
        max_hp: { type: 'number' },
      },
    },
    handler: (args) => rpc('heal', args),
  },
  {
    name: 'noita_add_gold',
    description: 'Add gold to the player wallet.',
    inputSchema: {
      type: 'object',
      properties: { amount: { type: 'integer', description: 'default 1000' } },
    },
    handler: (args) => rpc('add_gold', args),
  },
  {
    name: 'noita_apply_effect',
    description: 'Apply a status effect to the player, e.g. PROTECTION_FIRE, PROTECTION_ALL, REGENERATION, WET, POLYMORPH. Specify frames (60 = 1s).',
    inputSchema: {
      type: 'object',
      properties: {
        effect: { type: 'string' },
        frames: { type: 'integer', description: 'default 600' },
      },
      required: ['effect'],
    },
    handler: (args) => rpc('apply_effect', args),
  },
  {
    name: 'noita_spawn_wand',
    description: 'Create a brand new wand with exactly the attributes and spells you specify (mana, capacity, cast delay, recharge, spread, shuffle, deck). Spawned at the player unless x/y given.',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number' },
        y: { type: 'number' },
        spells: SPELL_SCHEMA,
        sprite_random: { type: 'boolean', description: 'pick a random wand appearance, default true' },
        ...WAND_ATTRS,
      },
    },
    handler: (args) => rpc('spawn_wand', args),
  },
  {
    name: 'noita_edit_wand',
    description: 'Modify an existing wand. Defaults to the wand currently held. Pass attrs (or the attributes directly) to change stats, and/or spells to replace the whole deck.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer', description: 'wand entity id; omit for the held wand' },
        spells: SPELL_SCHEMA,
        ...WAND_ATTRS,
      },
    },
    handler: (args) => {
      const { entity, spells, ...attrs } = args || {};
      const params = { entity, attrs };
      if (spells) params.spells = spells;
      return rpc('edit_wand', params);
    },
  },
  {
    name: 'noita_set_wand_deck',
    description: 'Replace the entire spell layout of a wand (defaults to the held wand). Order in the array is the order in the wand.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer' },
        spells: SPELL_SCHEMA,
      },
      required: ['spells'],
    },
    handler: (args) => rpc('set_wand_deck', args),
  },
  {
    name: 'noita_add_spell_to_wand',
    description: 'Insert one spell into a wand deck (defaults to the held wand) at an optional index.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer' },
        action_id: { type: 'string', description: 'e.g. "LIGHT_BULLET", "HOMING", "DAMAGE" ' },
        index: { type: 'integer', description: '0-based slot, default append' },
      },
      required: ['action_id'],
    },
    handler: (args) => rpc('add_spell_to_wand', args),
  },
  {
    name: 'noita_remove_spell_from_wand',
    description: 'Remove a spell from a wand deck (defaults to the held wand) by action_id or 0-based index.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer' },
        action_id: { type: 'string' },
        index: { type: 'integer' },
      },
    },
    handler: (args) => rpc('remove_spell_from_wand', args),
  },
  {
    name: 'noita_spawn_spell',
    description: 'Spawn a loose spell pickup in the world (defaults to the player position).',
    inputSchema: {
      type: 'object',
      properties: {
        action_id: { type: 'string' },
        x: { type: 'number' },
        y: { type: 'number' },
      },
      required: ['action_id'],
    },
    handler: (args) => rpc('spawn_spell', args),
  },
  {
    name: 'noita_spawn_potion',
    description: 'Spawn a potion filled with the materials you choose, e.g. materials:["water"] or [{"material":"acid","amount":800}].',
    inputSchema: {
      type: 'object',
      properties: {
        materials: {
          anyOf: [
            { type: 'string' },
            {
              type: 'array',
              items: {
                anyOf: [
                  { type: 'string' },
                  {
                    type: 'object',
                    properties: { material: { type: 'string' }, amount: { type: 'number' } },
                    required: ['material'],
                  },
                ],
              },
            },
          ],
        },
        amount: { type: 'number', description: 'default 1000 per material' },
        x: { type: 'number' },
        y: { type: 'number' },
      },
      required: ['materials'],
    },
    handler: (args) => rpc('spawn_potion', args),
  },
  {
    name: 'noita_get_potion',
    description: 'Read the contents (material + amount) of a potion. Defaults to the item currently held.',
    inputSchema: {
      type: 'object',
      properties: { entity: { type: 'integer' } },
    },
    handler: (args) => rpc('get_potion', args),
  },
  {
    name: 'noita_set_potion',
    description: 'Empty a potion and refill it with the materials you choose. Defaults to the item currently held.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer' },
        materials: {
          anyOf: [
            { type: 'string' },
            { type: 'array', items: { type: 'string' } },
          ],
        },
        amount: { type: 'number' },
      },
      required: ['materials'],
    },
    handler: (args) => rpc('set_potion', args),
  },
  {
    name: 'noita_spawn_item',
    description: 'Spawn any entity by its xml path, e.g. data/entities/items/pickup/heart.xml, data/entities/animals/duck.xml, data/entities/items/wands/random_wand.xml.',
    inputSchema: {
      type: 'object',
      properties: {
        filename: { type: 'string' },
        x: { type: 'number' },
        y: { type: 'number' },
      },
      required: ['filename'],
    },
    handler: (args) => rpc('spawn_item', args),
  },
  {
    name: 'noita_entity_info',
    description: 'Inspect one entity id in detail: name, kind, hp, tags, source xml path, position.',
    inputSchema: {
      type: 'object',
      properties: { entity: { type: 'integer' } },
      required: ['entity'],
    },
    handler: (args) => rpc('entity_info', args),
  },
  {
    name: 'noita_list_perks',
    description: 'Catalog of every perk id with its readable name (for use with the game flag APIs / reporting player perks).',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('list_perks'),
  },
  {
    name: 'noita_refresh_spells',
    description: 'Force the game to regenerate the item/spell state on the player. Useful after heavy wand edits if the HUD looks stale.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('refresh_spells'),
  },
  // ---- control experiments (stage 0) -------------------------------------
  // These answer "can a mod drive the player's input?" empirically. They are
  // grouped under noita_experiment so they are easy to retire once the answer
  // is settled and the real control tools are built on top of it.
  {
    name: 'noita_probe_controls',
    description: 'EXPERIMENT: list every player ControlsComponent field the game lets Lua read, ' +
      'including the private button fields and the aiming vector candidates. Read-only.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('probe_controls'),
  },
  // ---- control panel (stage 1) -------------------------------------------
  {
    name: 'noita_get_panel',
    description: 'Read the in-game bridge panel: whether AI control is enabled, read-only mode, the ' +
      'per-category operation switches, which settings backend is active, and the panel log tail. ' +
      'Check this first when a mutation is refused.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('get_panel'),
  },
  {
    name: 'noita_set_panel',
    description: 'Change the bridge panel switches. Turning ai_enabled off stops every mutation but leaves ' +
      'reads working, so the AI can still observe while paused. Switch names: ai_enabled, read_only, ' +
      'operations.{spawn,player,wands,world}, open, verbose.',
    inputSchema: {
      type: 'object',
      properties: {
        ai_enabled: { type: 'boolean', description: 'master switch for all mutations' },
        read_only: { type: 'boolean', description: 'refuse mutations, keep reads' },
        operations: {
          type: 'object',
          description: 'per-category switches',
          properties: {
            spawn: { type: 'boolean', description: 'spawn wands / spells / potions / items' },
            player: { type: 'boolean', description: 'move or modify the player' },
            wands: { type: 'boolean', description: 'rewrite wand stats and decks' },
            world: { type: 'boolean', description: 'unclassified / raw mutations' },
          },
        },
      },
    },
    handler: (args) => rpc('set_panel', args),
  },
  {
    name: 'noita_probe_api',
    description: 'Report which engine APIs the mod sandbox actually exposes (Gui*, ModSetting*, Input*, ' +
      'Globals*). Useful when a feature silently does nothing.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('probe_api'),
  },
  {
    name: 'noita_inspect_component',
    description: 'Read arbitrary component fields from an entity, for values no dedicated tool covers.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer', description: 'defaults to the player' },
        component: { type: 'string', description: 'e.g. CharacterDataComponent' },
        tag: { type: 'string' },
        fields: { type: 'array', items: { type: 'string' } },
      },
      required: ['component'],
    },
    handler: (args) => rpc('inspect_component', args),
  },
  // ---- wand simulation ---------------------------------------------------
  {
    name: 'noita_simulate_wand',
    description: 'PREDICT what a wand will actually do, using the deck model (draw counts, cast blocks, ' +
      'wrap, charge accumulation): casts per second, mana per second, and what each cast produces. ' +
      'Use this to check a design BEFORE creating it, or to explain why a wand underperforms. ' +
      'Reads the wand from the game by default (the held one), or simulates the `spells` you pass. ' +
      'Spells the simulator does not recognise are reported and treated as neutral projectiles, so ' +
      'treat a prediction containing them as approximate.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer', description: 'wand entity id; omit for the held wand' },
        spells: {
          type: 'array', items: { type: 'string' },
          description: 'simulate this layout instead of reading a wand; use "" or "_" for an empty slot',
        },
        always_cast: { type: 'array', items: { type: 'string' }, description: 'always-cast spells' },
        cast_delay: { type: 'number', description: 'seconds; defaults to the game value' },
        recharge: { type: 'number', description: 'seconds; defaults to the game value' },
        mana_max: { type: 'number' },
        mana_charge: { type: 'number', description: 'mana per second' },
        capacity: { type: 'integer' },
        spells_per_cast: { type: 'integer' },
        spread: { type: 'number' },
        shuffle: { type: 'boolean' },
        rounds: { type: 'integer', description: 'how many cast rounds to simulate, default 2' },
      },
    },
    handler: async (args) => {
      const a = args || {};
      const note = [];

      // Start from the game's numbers so the prediction matches the real wand,
      // then let explicit arguments override them.
      let wand = null;
      if (!a.spells) {
        const held = await rpc(a.entity ? 'get_wands' : 'get_held_wand');
        if (a.entity) {
          wand = (held.wands || []).find((w) => w.entity === a.entity) || null;
        } else {
          wand = held.wand || null;
        }
        if (!wand) {
          throw new Error(a.entity
            ? `no wand with entity ${a.entity} is carried by the player`
            : 'no wand held; pass spells[] to simulate a design instead');
        }
      }

      const deck = wand ? (wand.deck || []) : [];
      let spells = a.spells;
      let always = a.always_cast;
      if (!spells && wand) {
        // always-cast cards are attached cards the simulator expects separately
        spells = deck.filter((d) => !d.always_cast).map((d) => d.action_id || '_');
        always = deck.filter((d) => d.always_cast).map((d) => d.action_id);
      }

      const simArgs = {
        '--spells': (spells || []).map((s) => (s === '' ? '_' : s)).join(','),
        '--rounds': a.rounds || 2,
      };
      if (always && always.length) simArgs['--always'] = always.join(',');

      const src = wand || {};
      const pick = (explicitV, wandField, scale) => {
        if (explicitV !== undefined && explicitV !== null) return explicitV;
        const v = src[wandField];
        if (v === undefined || v === null) return undefined;
        return scale ? v * scale : v;
      };
      simArgs['--spells-per-cast'] = pick(a.spells_per_cast, 'actions_per_round');
      simArgs['--capacity'] = pick(a.capacity, 'deck_capacity');
      if (a.shuffle !== undefined) simArgs['--shuffle'] = a.shuffle ? 'yes' : 'no';
      else if (wand) simArgs['--shuffle'] = src.shuffle ? 'yes' : 'no';
      simArgs['--cast-delay'] = pick(a.cast_delay, 'fire_rate_wait', 1 / 60);
      simArgs['--recharge'] = pick(a.recharge, 'reload_time', 1 / 60);
      simArgs['--mana-max'] = pick(a.mana_max, 'mana_max');
      simArgs['--mana-charge'] = pick(a.mana_charge, 'mana_charge_speed');

      const sim = runWandSim(simArgs, ['--json', '--quiet']);
      const unknown = parseSimWarnings(sim.stderr);

      // cross-check against the game's own spell catalogue, which is larger
      if (unknown.length) {
        try {
          const cat = await rpc('list_spells', {});
          const known = new Set((cat.spells || []).map((s) => String(s.id).toUpperCase()));
          const actuallyExists = unknown.filter((u) => known.has(String(u).toUpperCase()));
          if (actuallyExists.length) {
            note.push(`${actuallyExists.join(', ')} exist in the game but are not in the simulator's ` +
              'spell table, so their mana and cast-delay effects were approximated as neutral');
          }
        } catch (_) { /* catalogue lookup is best-effort */ }
      }

      return {
        source: wand ? `wand entity ${wand.entity} (${wand.name})` : 'spells argument',
        inputs: {
          spells, always_cast: always || [],
          spells_per_cast: simArgs['--spells-per-cast'],
          capacity: simArgs['--capacity'],
          cast_delay_s: simArgs['--cast-delay'],
          recharge_s: simArgs['--recharge'],
          mana_max: simArgs['--mana-max'],
          mana_charge: simArgs['--mana-charge'],
          shuffle: simArgs['--shuffle'],
        },
        summary: sim.stdout.replace(/\s*\[[\s\S]*$/, '').trim(),
        rounds: sim.rounds,
        unknown_spells: unknown,
        notes: note,
      };
    },
  },
  // ---- direct player control ("levers") ----------------------------------
  // The official input path cannot be forged, so these act on what the input
  // feeds: velocity, gravity, mass, and the movement gates. Everything is
  // reversible: engage captures the pristine values, disengage puts them back.
  {
    name: 'noita_lever_state',
    description: 'Inspect the direct-control levers available on the player: velocity, gravity, mass, ' +
      'flying energy, and the movement gates (`dont_update_velocity_and_xform` freezes the engine\'s ' +
      'own velocity/position handling). Read this before engaging to see what is available.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('lever_state'),
  },
  {
    name: 'noita_lever_experiment',
    description: 'MEASURE whether a velocity write actually moves the player. Writes a horizontal ' +
      'velocity for N frames with gravity off, then reports how far the player drifted. Any x drift ' +
      'is attributable to us, because the player receives no horizontal input during the test. ' +
      'Reversible; call noita_lever_disengage afterwards.',
    inputSchema: {
      type: 'object',
      properties: {
        vx: { type: 'number', description: 'horizontal velocity to write, default 200' },
        vy: { type: 'number', description: 'vertical velocity to write, default 0' },
        frames: { type: 'integer', description: 'how long to hold, default 30' },
        phase: { type: 'string', enum: ['pre', 'post'], description: 'which hook writes, default pre' },
      },
    },
    handler: async (args) => {
      const started = await rpc('lever_experiment', args || {});
      if (started && started.ok === false) return started;
      await sleep(1200);
      return rpc('lever_experiment_result');
    },
  },
  {
    name: 'noita_lever_engage',
    description: 'Take direct control of player motion for N frames: writes the given component fields ' +
      'every frame. Use names from noita_lever_state. The original values are captured first, so ' +
      'noita_lever_disengage restores the player exactly.',
    inputSchema: {
      type: 'object',
      properties: {
        frames: { type: 'integer', description: 'how long to hold, default 300 (5s)' },
        fields: {
          type: 'object',
          description: 'CharacterDataComponent fields, e.g. ' +
            '{"gravity":{"value":0,"shape":"scalar"},"dont_update_velocity_and_xform":{"value":1,"shape":"scalar"}}',
        },
        velocity_fields: { type: 'object', description: 'VelocityComponent fields' },
        controls_fields: { type: 'object', description: 'ControlsComponent fields (expected to be ineffective)' },
        phase: { type: 'string', enum: ['pre', 'post'], description: 'default pre' },
      },
    },
    handler: (args) => rpc('lever_engage', args || {}),
  },
  {
    name: 'noita_lever_disengage',
    description: 'Release direct control and restore every value captured by noita_lever_engage. ' +
      'Call this when done -- it is what puts the player back the way they were.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('lever_disengage'),
  },
  {
    name: 'noita_lever_status',
    description: 'What the current lever engagement is doing, including samples of the player state ' +
      'taken each frame (to see whether our writes survive the engine\'s own update).',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('lever_status'),
  },
  {
    name: 'noita_probe_ffi',
    description: 'Report whether LuaJIT FFI is usable (require("ffi"), cdef, and loading ws2_32). ' +
      'This is the ceiling on transport options: with FFI a real socket is possible; without it the ' +
      'bridge stays on files.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('probe_ffi'),
  },
  {
    name: 'noita_latency',
    description: 'Measured transport latency: how long the game took to pick up and answer recent ' +
      'requests. Use it to confirm real-time behaviour instead of assuming it.',
    inputSchema: { type: 'object', properties: {} },
    handler: async () => {
      const st = await rpc('status');
      return {
        client: rttReport(),
        polling: st.polling,
        game_side_latency: st.latency,
        frame: st.frame,
        note: 'one frame is 16.7ms; polling every frame is the floor for a file transport',
      };
    },
  },
  {
    name: 'noita_socket',
    description: 'Control and inspect the optional socket transport (localhost HTTP, same methods as the ' +
      'file bridge). The socket is OFF by default; the file bridge is the proven default path. Use ' +
      'action="status" to read the guard report (whether any socket call ever blocked). action="start" ' +
      'also proves a request round-trips before returning.',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['start', 'stop', 'status', 'enable_setting'] },
        port: { type: 'integer', description: '0 or omitted = let the OS choose' },
        value: { type: 'boolean', description: 'for enable_setting: whether to auto-start on next run' },
      },
      required: ['action'],
    },
    handler: async (args) => {
      const res = await rpc('socket_control', args || {});
      if (args && args.action === 'start' && res && res.ok) {
        const portFile = readJson(path.join(RUN_DIR || '', 'port.json'));
        return {
          ...res,
          port_file: portFile,
          hint: 'The socket is faster only for BATCHED calls; a single call is ~33ms vs ~16ms for the ' +
            'file bridge, because the file bridge is already quantised to one 16.7ms frame.',
        };
      }
      return {
        action: args.action,
        ...res,
        port_file: (args.action === 'start' && res && res.ok)
          ? readJson(path.join(RUN_DIR || '', 'port.json')) : undefined,
        transport: transportReport(),
        hint: 'A single call costs one 16.7ms frame on either transport; the socket wins when several ' +
          'methods go out together (see noita_batch).',
      };
    },
  },
  {
    name: 'noita_batch',
    description: 'Run SEVERAL bridge methods in one round trip. This is where the socket transport ' +
      'actually pays off: N calls batched cost one trip instead of N. Use it to refresh a whole ' +
      'picture at once (player + nearby + wands + inventory) without paying a frame per call.',
    inputSchema: {
      type: 'object',
      properties: {
        calls: {
          type: 'array',
          description: 'methods to call together',
          items: {
            type: 'object',
            properties: {
              method: { type: 'string' },
              params: { type: 'object' },
            },
            required: ['method'],
          },
        },
      },
      required: ['calls'],
    },
    handler: async (args) => {
      const calls = (args && args.calls) || [];
      if (!calls.length) throw new Error('calls[] is required');
      const started = Date.now();
      const out = await rpcBatch(calls);
      return {
        transport: out.transport,
        total_ms: Date.now() - started,
        per_call_ms: Math.round((Date.now() - started) / calls.length),
        results: out.results,
      };
    },
  },
  {
    name: 'noita_transport',
    description: 'Show which transport the MCP server is using and why (socket preference, whether the ' +
      'game is listening, recent socket failures), and switch the preference. Switching does not stop ' +
      'the file bridge, so calls keep working either way.',
    inputSchema: {
      type: 'object',
      properties: {
        prefer: { type: 'string', enum: ['socket', 'file'], description: 'omit to just read the state' },
      },
    },
    handler: async (args) => {
      if (args && args.prefer) {
        useSocket = args.prefer === 'socket';
        socketFailures = 0;
        socketDisabledUntil = 0;
      }
      return transportReport();
    },
  },
  // ---- player interaction -------------------------------------------------
  // The mechanisms here were each measured in a live run before being exposed.
  // See noita_capabilities for what is and is not drivable, and why.
  {
    name: 'noita_capabilities',
    description: 'What player interactions can actually be driven, with the measured reason for ' +
      'anything blocked. Read this before promising the user an action: firing the held wand, ' +
      'aiming and the engine\'s own throw are blocked by the same root cause.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('po_capabilities'),
  },
  {
    name: 'noita_inventory',
    description: 'What the player is carrying: every item with its kind, whether it is in the pack ' +
      'or worn equipment, and which one is in hand.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('po_inventory'),
  },
  {
    name: 'noita_switch_item',
    description: 'Put a carried item in the player\'s hand. Verified to persist: the engine\'s own ' +
      'held-item and held-wand lookups follow it. Select by entity, or by kind for convenience.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer', description: 'item entity id (from noita_inventory)' },
        kind: { type: 'string', enum: ['wand', 'potion', 'spell', 'item'], description: 'pick the first of this kind' },
      },
    },
    handler: (args) => rpc('po_switch', args || {}),
  },
  {
    name: 'noita_pickup',
    description: 'Take an entity into the player\'s inventory. Only items carrying an ' +
      'AbilityComponent can be taken this way (potions, wands, spell items). Auto-pickup items ' +
      'like hearts and gold are collected by proximity and will report why they were refused.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer', description: 'entity id to pick up' },
        radius: { type: 'number', description: 'override the pickup radius' },
        effects: { type: 'boolean', description: 'play pickup effects, default true' },
      },
      required: ['entity'],
    },
    handler: (args) => rpc('po_pickup', args || {}),
  },
  {
    name: 'noita_drop_item',
    description: 'Release one carried item into the world with velocity. This is a PHYSICS RELEASE, ' +
      'not the engine\'s throw: the item genuinely flies and can hit things, but there is no throw ' +
      'animation and engine-side on-throw effects may not fire. Omit entity to drop what is held.',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'integer', description: 'item to release; defaults to the held item' },
        speed: { type: 'number', description: 'launch speed, default 300' },
        angle: { type: 'number', description: 'direction in degrees, 0 = right; omit to drop forward' },
      },
    },
    handler: (args) => rpc('po_drop_one', args || {}),
  },
  {
    name: 'noita_drop_all',
    description: 'Empty the pack into the world. Worn equipment (body parts, cape) is left on the ' +
      'player -- measured on a 7-item pack that became 3.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('po_drop_all'),
  },
  {
    name: 'noita_launch_projectile',
    description: 'Fire a projectile into the world from the player, using the engine\'s ' +
      'GameShootProjectile. This is the AI launching something -- it is NOT the player firing ' +
      'their wand, and the response says so. Give tx/ty, or an angle plus distance.',
    inputSchema: {
      type: 'object',
      properties: {
        tx: { type: 'number', description: 'target x' },
        ty: { type: 'number', description: 'target y' },
        angle: { type: 'number', description: 'direction in degrees, 0 = right' },
        distance: { type: 'number', description: 'used with angle, default 200' },
        template: { type: 'string', description: 'projectile entity xml path' },
      },
    },
    handler: (args) => rpc('po_launch', args || {}),
  },
  // ---- input forging: the extension's tools -------------------------------
  // The capabilities pure Lua cannot have. Verified in a live run: left/right
  // movement gives vx = +/-56.6 against a zero baseline, and a forged mouse click
  // advances the engine's own mButtonFrameFire.
  {
    name: 'noita_input_move',
    description: 'Move the player by holding a direction key. Requires the input extension ' +
      '(noita_capabilities reports the mode). Verified: left and right give symmetric ' +
      'velocity against a zero baseline.',
    inputSchema: {
      type: 'object',
      properties: {
        dir: { type: 'string', enum: ['D', 'A', 'W', 'S'], description: 'D=right, A=left, W=up/fly, S=down' },
        frames: { type: 'integer', description: 'how long to hold, default 20 (about 0.3s)' },
      },
      required: ['dir'],
    },
    handler: (args) => rpc('po_input_move', args || {}),
  },
  {
    name: 'noita_input_key',
    description: 'Hold any key for N frames (fly is SPACE, interact is E, hotbar is ' +
      'NUM1..NUM5). Requires the input extension. The hold releases itself when the frames ' +
      'run out.',
    inputSchema: {
      type: 'object',
      properties: {
        key: { type: 'string', description: 'W A S D SPACE SHIFT CTRL E Q R F UP DOWN LEFT RIGHT NUM1..NUM5' },
        frames: { type: 'integer', description: 'default 12' },
      },
      required: ['key'],
    },
    handler: (args) => rpc('hold_key', args || {}),
  },
  {
    name: 'noita_input_fire',
    description: 'Fire the held wand. Requires the input extension. This holds the LEFT MOUSE ' +
      'BUTTON, which is what Noita actually fires on -- SPACE is the fly key and produces no ' +
      'shot. Verified: the engine\'s own mButtonFrameFire advances.',
    inputSchema: {
      type: 'object',
      properties: {
        frames: { type: 'integer', description: 'how long to hold the trigger, default 20' },
      },
    },
    handler: (args) => rpc('hold_mouse', { button: 1, frames: (args && args.frames) || 20 }),
  },
  {
    name: 'noita_input_click',
    description: 'Hold a mouse button at a screen position, which is how aim is controlled: the ' +
      'engine derives its aim vector from the mouse. Requires the input extension.',
    inputSchema: {
      type: 'object',
      properties: {
        button: { type: 'integer', description: '1 = left, 3 = right; default 1' },
        frames: { type: 'integer', description: 'default 12' },
        x: { type: 'number', description: 'screen x' },
        y: { type: 'number', description: 'screen y' },
      },
    },
    handler: (args) => rpc('hold_mouse', args || {}),
  },
  {
    name: 'noita_input_release',
    description: 'Release every held key and mouse button immediately. Safe to call at any ' +
      'time; holds also expire on their own.',
    inputSchema: { type: 'object', properties: {} },
    handler: async () => {
      const a = await rpc('hold_release');
      const b = await rpc('mouse_release');
      return { ok: true, keys: a, mouse: b };
    },
  },
  {
    name: 'noita_input_status',
    description: 'Whether the input extension is loaded and armed, how many events SDL has ' +
      'accepted, and what is currently held. Use it to tell "installed" from "working": ' +
      'queued must grow for input to be reaching the game.',
    inputSchema: { type: 'object', properties: {} },
    handler: async () => {
      const st = await rpc('input_status');
      const push = await rpc('push_stats');
      const hold = await rpc('hold_status');
      return { extension: st, events: push, holding: hold };
    },
  },
  {
    name: 'noita_input_load',
    description: 'Load the input extension into the running game using the mod\'s own FFI (no ' +
      'external injector needed). Loading is INERT: nothing is hooked until ' +
      'noita_input_install. Safe to call when already loaded.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'absolute path to xinput_hook.dll' } },
    },
    handler: (args) => rpc('input_load', args || {}),
  },
  {
    name: 'noita_input_install',
    description: 'Arm the input extension: installs the hooks that let events be fed to the ' +
      'game. All-or-nothing, protected by a heartbeat watchdog, and reversible with ' +
      'noita_input_uninstall.',
    inputSchema: { type: 'object', properties: {} },
    handler: () => rpc('poll_install'),
  },
  {
    name: 'noita_input_uninstall',
    description: 'Remove the input hooks and restore the game to its original behaviour without ' +
      'restarting.',
    inputSchema: { type: 'object', properties: {} },
    handler: async () => {
      await rpc('hold_release');
      await rpc('mouse_release');
      return rpc('poll_remove');
    },
  },
  // ---- entity catalog -----------------------------------------------------
  // The mod can only see entities near the player. The game defines ~3000, and
  // these tools make the rest findable, which is what turns "spawn a big chest"
  // into an executable request instead of a guess.
  {
    name: 'noita_find_entity',
    description: 'Search the game\'s ~3000 entity definitions by name, tag or kind. Use this ' +
      'before spawning anything: `noita_spawn_item` needs a template PATH, and paths are not ' +
      'guessable. Example queries: "chest", "spell_refresher", "wand", kind "enemy".',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'substring match on path, file, tags and name; space-separated terms must all match' },
        kind: {
          type: 'string',
          description: 'restrict to a category',
          enum: ['chest', 'wand', 'potion', 'item', 'enemy', 'building', 'prop', 'projectile', 'misc', 'vegetation', 'player'],
        },
        limit: { type: 'integer', description: 'max results, default 25' },
      },
    },
    handler: (args) => {
      const idx = findEntityIndex();
      if (!idx) {
        throw new Error('entity index not found. Build it with ' +
          'tools/re/build_index.py, or set NOITA_ENTITY_INDEX to its path.');
      }
      const a = args || {};
      const needles = String(a.query || '').toLowerCase().split(/\s+/).filter(Boolean);
      let rows = idx.entities;
      if (a.kind) rows = rows.filter((e) => e.kind === a.kind);
      if (needles.length) {
        rows = rows
          .map((e) => ({ e, s: scoreEntity(e, needles) }))
          .filter((x) => x.s >= 0)
          .sort((x, y) => y.s - x.s)
          .map((x) => x.e);
      }
      const limit = Math.max(1, Math.min(a.limit || 25, 200));
      return {
        total_in_catalog: idx.total,
        kinds: idx.kinds,
        matched: rows.length,
        results: rows.slice(0, limit).map((e) => ({
          path: e.path, kind: e.kind, name: e.name || undefined, tags: e.tags || undefined,
        })),
        hint: 'pass a `path` to noita_spawn_item, or to noita_entity_blueprint to read its stats',
      };
    },
  },
  {
    name: 'noita_entity_blueprint',
    description: 'Read an entity definition from the unpacked game data: its components and their ' +
      'values, which is where enemy stats (hp, damage, abilities), wand templates and chest ' +
      'contents live. Complements noita_entity_info, which reads a LIVE entity in the game.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'e.g. data/entities/animals/acidshooter.xml' },
        components: { type: 'array', items: { type: 'string' }, description: 'only these component names' },
      },
      required: ['path'],
    },
    handler: (args) => {
      const ref = findRefData();
      if (!ref) {
        throw new Error(
          'unpacked game data not found, so entity definitions cannot be read.\n' +
          'The game keeps them packed inside data/data.wak, and they are deliberately ' +
          'not bundled here (the Noita Modding Agreement forbids redistributing the ' +
          'game\'s content).\n' +
          'Fix: run tools/unpak.ps1, which uses the game\'s own switch ' +
          '(`noita.exe -wizard_unpak`) to produce data/entities locally.\n' +
          'If it is already unpacked somewhere else, set NOITA_REF_DATA to that folder.');
      }
      const rel = String((args && args.path) || '').replace(/^data[\\/]/, '');
      const file = path.join(ref, rel.replace(/[\\/]/g, path.sep));
      if (!fs.existsSync(file)) throw new Error(`no such entity file: ${args.path}`);
      const xml = fs.readFileSync(file, 'utf8');

      // pull component blocks with a simple scan: the files are machine-generated
      // and uniformly shaped, so a full XML parser would be overkill here
      const want = args && args.components;
      const comps = [];
      const re = /<([A-Za-z_][\w]*)\b([^>]*?)(\/?)>/g;
      let m;
      while ((m = re.exec(xml)) !== null) {
        const name = m[1];
        if (name === 'Entity') continue;
        if (want && !want.includes(name)) continue;
        const attrs = {};
        const ar = /([\w.]+)\s*=\s*"([^"]*)"/g;
        let am;
        while ((am = ar.exec(m[2])) !== null) attrs[am[1]] = am[2];
        comps.push({ component: name, values: attrs });
      }
      const head = xml.match(/<Entity[^>]*>/);
      const tagMatch = head && head[0].match(/tags="([^"]*)"/);
      return {
        path: args.path,
        bytes: xml.length,
        tags: tagMatch ? tagMatch[1] : undefined,
        components: comps,
      };
    },
  },
  // ---- world and map ------------------------------------------------------
  {
    name: 'noita_world',
    description: 'Where the player is in the world: biome name, depth within the biome, parallel ' +
      'world / sky / hell coordinates, orb progress, the camera rectangle (for converting world ' +
      'to screen when aiming), and a coarse fog-of-war sample showing what is explored. ' +
      'Use noita_get_state for the player\'s own stats; this is about the map.',
    inputSchema: {
      type: 'object',
      properties: {
        radius: { type: 'integer', description: 'fog sample radius in pixels, default 512' },
        nearby: { type: 'boolean', description: 'include a nearby entity count, default true' },
      },
    },
    handler: (args) => rpc('po_world', args || {}),
  },
  {
    name: 'noita_biome_at',
    description: 'The biome name at an arbitrary world position, its vertical position inside that ' +
      'biome, and its parallel-world coordinates. Lets the AI reason about the map without ' +
      'moving the player. Defaults to the player\'s position.',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number', description: 'world x, default player x' },
        y: { type: 'number', description: 'world y, default player y' },
      },
    },
    handler: (args) => rpc('po_biome_at', args || {}),
  },
  // ---- fact database ------------------------------------------------------
  // Identifiers, numbers and relationships extracted from the game data, shipped as
  // one queryable file. This is what makes "which enemy has the most hp", "find a
  // wand with 10+ slots" or "what burns" answerable without the game's own files.
  {
    name: 'noita_db_query',
    description: 'Query the Noita fact database: enemy stats (hp, attack rate and ' +
      'projectile, materials that hurt them, hitbox), wand templates (capacity, fire ' +
      'rate, reload, mana), perks, materials (density, hazards, status effects), biomes ' +
      'and chests. Search is a ranked substring match over every field, so ' +
      '"hp 5 ant" or "danger_fire liquid" work. Use this to plan before acting; use ' +
      'noita_get_nearby / noita_entity_info for what is actually in the world.',
    inputSchema: {
      type: 'object',
      properties: {
        table: {
          type: 'string',
          enum: ['enemies', 'wands', 'chests', 'perks', 'materials', 'biomes', 'entities'],
          description: 'which list to search; default enemies',
        },
        query: { type: 'string', description: 'space-separated terms, all must match' },
        limit: { type: 'integer', description: 'max rows, default 15' },
        sort: { type: 'string', description: 'numeric field to sort by, descending (e.g. hp, deck_capacity)' },
        tags: { type: 'array', items: { type: 'string' }, description: 'for entities: require these tags' },
        kind: { type: 'string', description: 'for entities: require this kind' },
      },
    },
    handler: (args) => {
      const db = findFactDb();
      if (!db) {
        throw new Error('fact database not found. It ships as noita_db.json next to ' +
          'this server; regenerate it with tools/build_db.py if missing.');
      }
      const a = args || {};
      const table = a.table || 'enemies';
      // The stored key for the enemy list is enemy_stats, while counts and the docs
      // call it "enemies"; accept both rather than making the caller guess.
      const TABLE_ALIAS = { enemies: 'enemy_stats', enemy_stats: 'enemy_stats' };
      const rows = db[TABLE_ALIAS[table] || table];
      if (!Array.isArray(rows)) {
        return {
          error: `unknown table '${table}'`,
          available: ['enemies', 'wands', 'chests', 'perks', 'materials', 'biomes', 'entities'],
          counts: db.counts,
        };
      }

      let pool = rows;
      if (a.kind) pool = pool.filter((r) => r.kind === a.kind);
      if (a.tags && a.tags.length) {
        pool = pool.filter((r) => Array.isArray(r.tags) &&
          a.tags.every((t) => r.tags.includes(t)));
      }
      // "enemy" is decided by the mortal+hittable tag pair, which also catches
      // indestructible props such as temple statues (hp 1200) and physics wheels
      // (hp 99999). They are not enemies, and letting them top a "toughest enemy"
      // sort would be actively misleading, so they are held back unless asked for.
      if (table === 'enemies' && !a.include_props) {
        pool = pool.filter((r) => !/\/props\//.test(r.path) && !/physics_/.test(r.path));
      }

      const terms = String(a.query || '').toLowerCase().split(/\s+/).filter(Boolean);
      const keys = table === 'enemies' ? ['path']
        : table === 'materials' ? ['id', 'ui_name_key']
          : table === 'perks' ? ['id']
            : ['path', 'id'];
      const limit = Math.max(1, Math.min(a.limit || 15, 200));
      // a sort field means the caller wants extremes, so the whole pool is considered
      const found = searchRecords(pool, terms, keys, a.sort ? pool.length : limit);

      if (a.sort) {
        found.sort((x, y) => {
          const xv = typeof x[a.sort] === 'number' ? x[a.sort] : -Infinity;
          const yv = typeof y[a.sort] === 'number' ? y[a.sort] : -Infinity;
          return yv - xv;
        });
      }

      const total = (db.entities || []).length;
      return {
        table,
        matched: found.length,
        counts: db.counts,
        note: db.source && db.source.note,
        results: found.slice(0, limit),
        entity_catalog_size: total,
      };
    },
  },
  {
    name: 'noita_raw_rpc',
    description: 'Escape hatch: call a game-side bridge method directly with raw params. Methods: ' +
      'ping, status, get_state, get_player, get_nearby, get_inventory, get_wands, get_held_wand, raycast, ' +
      'set_player, heal, set_max_hp, add_gold, apply_effect, refresh_spells, spawn_wand, edit_wand, ' +
      'set_wand_deck, add_spell_to_wand, remove_spell_from_wand, spawn_spell, spawn_item, spawn_potion, ' +
      'get_potion, set_potion, list_spells, list_materials, get_perks, list_perks, entity_info, drop_item, ' +
      'get_panel, set_panel, probe_api, inspect_component, probe_ffi, probe_controls, control_set, ' +
      'control_set_aim, control_snapshot, control_restore, control_push, control_push_status, ' +
      'control_push_cancel, lever_state, lever_engage, lever_disengage, lever_status, lever_cancel, ' +
      'lever_experiment, lever_experiment_result.',
    inputSchema: {
      type: 'object',
      properties: {
        method: { type: 'string' },
        params: { type: 'object' },
        timeout_ms: { type: 'integer' },
      },
      required: ['method'],
    },
    handler: (args) => rpc(args.method, args.params || {}, { timeoutMs: args.timeout_ms || 8000 }),
  },
];

const TOOL_MAP = new Map(TOOLS.map((t) => [t.name, t]));

// ---------------------------------------------------------------- MCP plumbing

function writeMessage(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id, result) {
  writeMessage({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message, data) {
  writeMessage({ jsonrpc: '2.0', id, error: { code, message, ...(data ? { data } : {}) } });
}

function textResult(value) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: 'text', text }] };
}

async function handleToolCall(params) {
  const name = params && params.name;
  const tool = TOOL_MAP.get(name);
  if (!tool) {
    return { isError: true, content: [{ type: 'text', text: `Unknown tool: ${name}` }] };
  }
  try {
    const value = await tool.handler(params.arguments || {});
    return textResult(value);
  } catch (err) {
    return {
      isError: true,
      content: [{ type: 'text', text: `Tool ${name} failed: ${err.message}` }],
    };
  }
}

async function handleMessage(msg) {
  const { id, method, params } = msg;
  if (method === 'initialize') {
    reply(id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      instructions:
        'Controls a running Noita game through the "Noita AI Agent Bridge" mod. ' +
        'Start with noita_bridge_status, then noita_get_state to observe. ' +
        'Spell ids come from noita_list_spells; material ids from noita_list_materials.',
    });
    return;
  }
  if (method === 'notifications/initialized' || method === 'initialized') return;
  if (method === 'ping') { reply(id, {}); return; }
  if (method === 'tools/list') {
    reply(id, {
      tools: TOOLS.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
      })),
    });
    return;
  }
  if (method === 'tools/call') {
    reply(id, await handleToolCall(params || {}));
    return;
  }
  if (method === 'resources/list') { reply(id, { resources: [] }); return; }
  if (method === 'prompts/list') { reply(id, { prompts: [] }); return; }
  if (id !== undefined) replyError(id, -32601, `Method not found: ${method}`);
}

// ---------------------------------------------------------------- CLI mode

async function cli(argv) {
  const [command, ...rest] = argv;
  if (command === '--list') {
    for (const t of TOOLS) console.log(`${t.name}\t${t.description.split('.')[0]}`);
    return 0;
  }
  if (command === '--status') {
    console.log(JSON.stringify(await bridgeStatus(), null, 2));
    return 0;
  }
  if (command === '--call') {
    const [toolName, jsonArgs] = rest;
    const tool = TOOL_MAP.get(toolName);
    if (!tool) {
      console.error(`unknown tool: ${toolName}`);
      return 2;
    }
    const args = jsonArgs ? JSON.parse(jsonArgs) : {};
    try {
      const value = await tool.handler(args);
      console.log(JSON.stringify(value, null, 2));
      return 0;
    } catch (err) {
      console.error(`error: ${err.message}`);
      return 1;
    }
  }
  console.log(`usage:
  node server.js            # run as an MCP stdio server
  node server.js --list     # list available tools
  node server.js --status   # bridge health
  node server.js --call <tool> '<json args>'`);
  return 0;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.length > 0) {
    process.exitCode = await cli(argv);
    return;
  }

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch (err) {
      replyError(null, -32700, `Parse error: ${err.message}`);
      return;
    }
    handleMessage(msg).catch((err) => {
      if (msg && msg.id !== undefined) replyError(msg.id, -32603, `Internal error: ${err.message}`);
    });
  });
  rl.on('close', () => process.exit(0));
}

main().catch((err) => {
  console.error(`fatal: ${err.stack || err.message}`);
  process.exit(1);
});
