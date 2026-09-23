#!/usr/bin/env node
/**
 * Sends one RPC to a RUNNING Noita and waits for the game's answer.
 *
 * This is the live counterpart to mcp_e2e_test.js: it talks to the real Lua
 * bridge instead of a stub, so it is the quickest way to confirm the in-game
 * half of the bridge after a restart.
 *
 *   node live_probe.js                          # ping + status
 *   node live_probe.js get_state                # one method
 *   node live_probe.js spawn_wand '{"mana_max":900,"spells":["LIGHT_BULLET"]}'
 *   node live_probe.js --watch                  # keep pinging until the bridge answers
 */
'use strict';

const fs = require('fs');
const path = require('path');

function findRunDir() {
  if (process.env.NOITA_AGENT_RUN_DIR) return process.env.NOITA_AGENT_RUN_DIR;
  const roots = [
    process.env.NOITA_DIR,
    'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Noita',
    'D:\\Steam\\steamapps\\common\\Noita',
    'D:\\Sware\\Steam\\steamapps\\common\\Noita',
  ].filter(Boolean);
  for (const r of roots) {
    const dir = path.join(r, 'mods', 'noita_agent', 'run');
    if (fs.existsSync(dir)) return dir;
  }
  return null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

async function rpc(runDir, method, params, timeoutMs = 4000) {
  const request = path.join(runDir, 'request.json');
  const response = path.join(runDir, 'response.json');
  const id = Date.now() % 1000000;

  try { fs.unlinkSync(response); } catch (_) { /* ignore */ }
  const tmp = request + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify({ id, method, params: params || {} }), 'utf8');
  fs.renameSync(tmp, request);

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = readJson(response);
    if (res && res.id === id) return res;
    await sleep(30);
  }
  return null;
}

function bridgeInfo(runDir) {
  const ready = readJson(path.join(runDir, 'ready.json'));
  const status = readJson(path.join(runDir, 'status.json'));
  const stateFile = path.join(runDir, 'state.json');
  let ageMs = null;
  try { ageMs = Date.now() - fs.statSync(stateFile).mtimeMs; } catch (_) { /* ignore */ }
  return { ready, status, ageMs };
}

async function main() {
  const argv = process.argv.slice(2);
  const runDir = findRunDir();
  if (!runDir) {
    console.error('Could not locate mods/noita_agent/run. Set NOITA_AGENT_RUN_DIR or NOITA_DIR.');
    process.exit(2);
  }
  console.log(`run dir: ${runDir}`);

  const watch = argv[0] === '--watch';
  const method = watch ? 'ping' : (argv[0] || 'ping');
  const params = argv[1] ? JSON.parse(argv[1]) : {};

  const info = bridgeInfo(runDir);
  console.log(`ready.json : ${info.ready ? JSON.stringify(info.ready) : '(missing)'}`);
  console.log(`state age  : ${info.ageMs === null ? '(no state.json)' : Math.round(info.ageMs) + ' ms'}`);
  if (info.status) {
    console.log(`status     : frame=${info.status.frame} has_player=${info.status.has_player} io=${info.status.io} ffi=${info.status.ffi}`);
    if (info.status.env) console.log(`env        : ${info.status.env}`);
  }
  console.log('');

  if (watch) {
    for (let i = 0; i < 40; i++) {
      const res = await rpc(runDir, 'ping', {}, 3000);
      if (res && res.ok) {
        console.log(`bridge answered on attempt ${i + 1}: ${JSON.stringify(res)}`);
        process.exit(0);
      }
      process.stdout.write('.');
      await sleep(1500);
    }
    console.log('\nno answer after 60s. Is a run in progress with the mod enabled?');
    process.exit(1);
  }

  const res = await rpc(runDir, method, params);
  if (!res) {
    console.error(`no answer for "${method}" within 4s.`);
    console.error('Check: the game is running, a run is in progress, and mod_config.xml has noita_agent enabled.');
    console.error('Then read mods/noita_agent/run/bridge.log and the game\'s logger.txt.');
    process.exit(1);
  }
  console.log(JSON.stringify(res, null, 2));
  process.exit(res.ok === false ? 1 : 0);
}

main().catch((err) => { console.error('fatal: ' + (err.stack || err.message)); process.exit(1); });
