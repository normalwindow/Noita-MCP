-- Reads a wand's deck including the LIVE remaining-charge counter.
--
-- `max_uses` alone is useless for gameplay decisions: it is the static limit from
-- gun_actions.lua and never changes. Whether a limited spell is about to run out is
-- ItemActionComponent.uses_remaining on the card entity, which is what this reports.
-- Convention in the game data: -1 means unlimited.
local fixture = {}

function fixture.run(params)
  params = params or {}
  local wid = tonumber(params.wand)
  if not wid then return { ok = false, error = "wand entity id required" } end

  local out = { ok = true, wand = wid, deck = {} }
  local deck = ser.deck(wid)
  for i = 1, #deck do
    local d = deck[i]
    out.deck[#out.deck + 1] = {
      slot = d.slot,
      action_id = d.action_id,
      name = d.name,
      uses_remaining = d.uses_remaining,
      max_uses = d.max_uses,
      unlimited = d.unlimited,
    }
  end
  return out
end

return fixture
