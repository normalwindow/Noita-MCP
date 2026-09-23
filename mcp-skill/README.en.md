# Noita MCP Skill

`SKILL.md` is an agent Skill for the Noita MCP server. It teaches an AI agent how to drive the
`noita_*` tools correctly: what to call first, which tier it is in and therefore what it may
promise, which actions are verified in a live game, and which are impossible.

The skill provides knowledge, not capability. Every tool it describes comes from the MCP
server; the skill adds no code and no permissions of its own.

Chinese documentation: [README.md](README.md). Main readme: [../README.en.md](../README.en.md).

## What it is for

Without it, an agent tends to guess. Two failures in particular are common and both are
addressed directly:

- Assuming it can forge input. In base mode it cannot, and the skill requires the agent to
  check `noita_capabilities` before promising anything.
- Claiming an action it did not verify, for example saying "the player pressed W" when what
  actually happened was a direct velocity write. The skill states the distinction and the
  measured evidence behind it.

## Install

Copy the file into the skills directory your agent loads. For a dsh project that is
`<project>\.dsh\skills\`, one folder per skill:

```text
mcp-skill\SKILL.md   ->   <project>\.dsh\skills\noita-mcp\SKILL.md
```

```powershell
New-Item -ItemType Directory -Force "$project\.dsh\skills\noita-mcp" | Out-Null
Copy-Item .\mcp-skill\SKILL.md "$project\.dsh\skills\noita-mcp\SKILL.md"
```

Then start a new agent session, or reload the skill catalog, so the skill is discovered. An
agent runtime without a skill loader can be given the same file as part of its system prompt or
project instructions; the content is a plain Markdown document with a small YAML header.

`base\install.ps1` calls a skill installer when one is present; it is optional, and the copy
above always works.

## What it contains

| Section | Covers |
| --- | --- |
| Start every session like this | `noita_bridge_status`, `noita_capabilities`, `noita_get_panel`, `noita_get_state` — and stopping to ask the human when the bridge is not live |
| Two modes | Base versus full, why input tools refuse in base mode, and `unlocked_by_extension` |
| Hard rules | Do not claim unverified actions; read a refusal instead of working around it; `ok: false` is a normal answer, not a broken tool; confirm destructive intent; resolve spell and material ids before use |
| Direct motion | `noita_lever_*` as heavy machinery: read the state first, disengage when done, warn the human |
| The player's gear | Reading and changing what is held, pickup, drop, launch |
| Forging input | The extension's tools, and when to release |
| Managing the extension | Load, install, uninstall, status |
| Spawning | Look up what exists before spawning anything |
| World and map, catalogs | Biome and map reads; the game's own spell, material and entity lists |
| Standard workflows | Look around, read gear, give an item, rewrite a wand, simulate a wand, move/heal/buff |
| What is NOT possible | The verified-impossible table, all four rows sharing one root cause, plus what the engine exposes about its own controls |
| Panel and permissions | The switches, and preferring to ask the human to change them |
| Troubleshooting | Symptom-to-action table, including the MCP server's own CLI |
| Answering style | Report what the game returned; correct the expectation instead of substituting a different action |

## Notes

- Keep the skill and the server in the same release. Tool names and refusal messages are
  version-specific; an old skill against a new server will describe tools that no longer exist.
- Installing the skill does not grant anything. If the human has switched the mod's permission
  panel off, the same calls are refused with the skill installed.
- The skill is written for an agent, not for a person. For setup and limits, read
  [../base/README.en.md](../base/README.en.md) and [../full/README.en.md](../full/README.en.md).
