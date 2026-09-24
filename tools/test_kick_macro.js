// Confirms noita_macro kick end to end, through the permanent controls snapshot.
//
// WHAT THE FIELD ACTUALLY IS -- established by measurement, after two wrong guesses.
//
// `mButtonFrameKick` is the FRAME NUMBER the kick last happened on, not a count of kicks.
// Sampled immediately after the macro: frame 8757, kick 8757, mButtonDownKick true -- a
// difference of zero. A few frames later the field is frozen and the difference grows. So the
// test is not "did the number go up" -- time passing satisfies that on its own -- but "is the
// number close to NOW", which is only true if a kick just happened.
//
// The two earlier versions of this check got that wrong and both reported nonsense: the first
// compared raw differences and called a 2405-frame gap a pass, the second called the same gap a
// failure. Neither was measuring the macro.
//
// The baseline check still matters, for a different reason: it proves nothing else was pressing
// kick while the macro ran.
const path = require('path'), fs = require('fs');
const RUN = process.env.NOITA_AGENT_RUN_DIR;
if (!RUN) { console.error('NOITA_AGENT_RUN_DIR is not set'); process.exit(1); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return null; } };

async function rpc(method, params, t = 20000) {
  const q = path.join(RUN, 'request.json'), s = path.join(RUN, 'response.json');
  const id = Math.floor(Math.random() * 1e9);
  try { fs.unlinkSync(s); } catch (_) {}
  fs.writeFileSync(q + '.tmp', JSON.stringify({ id, method, params: params || {}, ts: Date.now() }), 'utf8');
  fs.renameSync(q + '.tmp', q);
  const d = Date.now() + t;
  while (Date.now() < d) { const r = readJson(s); if (r && r.id === id) return r; await sleep(5); }
  return null;
}

const kick = (r) => (r && typeof r.mButtonFrameKick === 'number') ? r.mButtonFrameKick : null;

(async () => {
  await rpc('input_load');
  await rpc('poll_install');
  await sleep(1500);

  // ---- baseline: the field must be STILL. If it moves on its own, something else is pressing
  // kick and the result below cannot be credited to the macro.
  const b1 = await rpc('controls_snapshot');
  await sleep(500);
  const b2 = await rpc('controls_snapshot');
  const k1 = kick(b1), k2 = kick(b2);
  if (k1 === null || k2 === null) {
    console.log('  FAIL: the snapshot does not report mButtonFrameKick');
    process.exit(1);
  }
  console.log(`  baseline    : kick=${k1}, still over ${b2.frame - b1.frame} frames`);
  if (k1 !== k2) {
    console.log(`  INCONCLUSIVE: it moved to ${k2} with no macro running, so something else is`);
    console.log('                pressing kick. Press nothing and retry.');
    process.exit(2);
  }

  // ---- the macro, then poll fast enough to catch the kick frame while it is still recent
  const m = await rpc('macro_start', { name: 'kick' });
  if (m && m.ok !== true) {
    console.log('  FAIL: the macro was refused: ' + (m.error || ''));
    process.exit(1);
  }

  let best = null;
  for (let i = 0; i < 12; i++) {
    const s = await rpc('controls_snapshot');
    const k = kick(s);
    if (k !== null && k !== k2) {
      const gap = s.frame - k;
      if (best === null || gap < best.gap) best = { gap, frame: s.frame, k, down: s.mButtonDownKick };
    }
    await sleep(40);
  }

  console.log(`  macro_start : ok=${m.ok}  method=${m.method}  frames=${m.total_frames}`);
  if (!best) {
    console.log('  FAIL: the field never changed, so the game did not kick.');
    process.exit(1);
  }
  console.log(`  after       : kick=${best.k} at frame ${best.frame} (gap ${best.gap}), down=${best.down}`);
  console.log('');

  // A kick that just happened has a gap of a few frames -- the sampling interval plus the round
  // trip. A stale value from an earlier kick has a gap of hundreds, and time passing alone
  // cannot make a gap small.
  if (best.gap <= 45) {
    console.log(`  PASS: the kick frame is ${best.gap} frames old, so the game kicked just now.`);
    console.log('        A pushed-but-unhandled key would have left the field unchanged.');
  } else {
    console.log(`  FAIL: the newest kick frame is ${best.gap} frames old, which is not this`);
    console.log('        macro -- so the game did not kick on it.');
    process.exit(1);
  }
})();
