-- Determines what ComponentObjectSetValue2 actually accepts for the
-- gun_config boolean member `shuffle_deck_when_empty`.
--
-- The existing encode helper assumed strings were accepted and that assumption is
-- WRONG at runtime: the game logs
--   "ComponentObjectSetValue2 - 'boolean' expected for 'shuffle_deck_when_empty'
--    but 'string' given"
-- Read-back, meanwhile, comes back tolerant (the decoder already handles "0"/"1"
-- and real booleans). So the read and write contracts differ and must be measured
-- separately rather than assumed to be symmetric.
--
-- This tries each representation, reads the value back after each attempt, and
-- reports which one actually changes the stored state. Everything is restored.

local fixture = {}

function fixture.run()
  local p = ser.player()
  local w = ser.held_wand(p)
  if not w then return { ok = false, error = "no wand held" } end

  local c = ser.comp(w, "AbilityComponent")
  if not c then return { ok = false, error = "wand has no AbilityComponent" } end

  local function raw()
    local ok, v = pcall(ComponentObjectGetValue2, c, "gun_config", "shuffle_deck_when_empty")
    if not ok then return "READ_ERROR" end
    return v
  end

  local original = raw()
  local out = { ok = true, wand = w, original = original,
                original_type = type(original), attempts = {} }

  -- Each candidate is written, read back, and judged by whether the STORED value
  -- changed to reflect it. Acceptance is not the same as effect.
  local candidates = {
    { label = "boolean true",  value = true },
    { label = "boolean false", value = false },
    { label = "number 1",      value = 1 },
    { label = "number 0",      value = 0 },
    { label = "string \"1\"",  value = "1" },
    { label = "string \"0\"",  value = "0" },
  }

  for _, cand in ipairs(candidates) do
    -- set to the opposite first, so a no-op write is detectable
    local opposite = (tobool_probe(cand.value)) and false or true
    pcall(ComponentObjectSetValue2, c, "gun_config", "shuffle_deck_when_empty", opposite)
    local before = raw()

    local ok_write, err = pcall(ComponentObjectSetValue2, c, "gun_config",
                                "shuffle_deck_when_empty", cand.value)
    local after = raw()

    out.attempts[#out.attempts + 1] = {
      label = cand.label,
      value_type = type(cand.value),
      write_ok = ok_write,
      write_error = (not ok_write) and tostring(err) or nil,
      stored_before = tostring(before) .. " (" .. type(before) .. ")",
      stored_after = tostring(after) .. " (" .. type(after) .. ")",
      changed = (tostring(before) ~= tostring(after)),
      matches_intent = (tobool_probe(after) == tobool_probe(cand.value)),
    }
  end

  -- restore
  pcall(ComponentObjectSetValue2, c, "gun_config", "shuffle_deck_when_empty", original)
  out.restored_to = tostring(raw())

  local working = {}
  for _, a in ipairs(out.attempts) do
    if a.write_ok and a.changed and a.matches_intent then working[#working + 1] = a.label end
  end
  out.accepted_representations = working
  out.verdict = (#working > 0)
    and ("these representations actually change the stored value: " ..
         table.concat(working, ", "))
    or "none of the tried representations changed the stored value"
  return out
end

-- local helper: interpret any representation as a boolean
function tobool_probe(v)
  if v == true then return true end
  if v == 1 then return true end
  if v == "1" or v == "true" then return true end
  return false
end

return fixture
