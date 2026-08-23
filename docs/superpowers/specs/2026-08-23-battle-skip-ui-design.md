# Battle Skip UI — Design

Date: 2026-08-23
Status: Approved

## Goal

Add a new ImGui window to the PCSX-Redux Lua tooling (`pcsx-redux-lua/`) with a button that skips the current battle in Summon Night (SLPS_025.42), mirroring the proven logic of the BizHawk C# tool (`summon_night_bizhawk/src/BattleSkipper.cs`).

## Background / Mechanism

- Battle unit data array starts at RAM `0x8009D3A8`; each unit occupies `0x30` bytes.
- Unit byte at `+0x7` = faction; `1` = enemy.
- Writing `1` to unit byte at `+0xC` sets the death flag; all faction-1 units die when any NPC next acts, ending the battle.
- PCSX-Redux Lua: `PCSX.getMemPtr()` returns a writable `uint8_t*` over up to 8MB WRAM; byte offset = address − 0x80000000.

## Scope (user-selected)

Button-only window: one Skip Battle button + kill-count result line. No NPC list, no auto-skip toggle.

## Approach (user-selected: A)

PCSX-Redux calls exactly one global `DrawImguiFrame()` per frame (currently owned by `extra_ui.lua`). The new feature is a self-contained module that chains onto it:

- New file: `pcsx-redux-lua/lua/battle_skip.lua`
- `pcsx.lua` appends:
  - `dofile("lua/battle_skip.lua")`
  - `startBattleSkip()`

Rejected alternatives:
- B: put window inside `extra_ui.lua`'s frame — mixes unrelated domains into one file.
- C: register extra draw callbacks via events engine — not supported; only one global draw hook exists.

## Component Design

```lua
-- Constants (mirror MemoryMap.cs)
NPC_BASE       = 0x9D3A8   -- memPtr offset for 0x8009D3A8
NPC_STRIDE     = 0x30
FACTION_OFFSET = 0x7
DEATH_FLAG_OFF = 0xC
NPC_COUNT      = 64
```

- `skipBattle()` — iterate i = 0..NPC_COUNT−1: base = NPC_BASE + i×NPC_STRIDE;
  if `mem[base + FACTION_OFFSET] == 1` then `mem[base + DEATH_FLAG_OFF] = 1`;
  return number killed.
- `startBattleSkip()` — capture existing global `DrawImguiFrame` as `prev`, install new global that calls `prev()` then draws the Battle Skip window. Must be dofile'd after `extra_ui.lua`.

## UI

Window title: `Battle Skip`

- Button `Skip Battle`: runs `skipBattle()`, stores result in `lastKilled`.
- Status text:
  - Before first click: `Click to kill all enemy units`
  - After click: `Killed N enemy units`

## Error Handling

Per PCSX-Redux docs, an exception thrown inside `DrawImguiFrame` disables the function until scripts are reloaded — which would also break `extra_ui.lua`'s windows via the chain. Therefore:

- All window content and skip logic run inside `pcall` within our section.
- On failure, display the error message inside the Battle Skip window instead of propagating.
- Guard against nil memory pointer (no game loaded).

## Known Behavior (accepted, same as BizHawk tool)

- Clicking outside battle writes flags to stale/unused memory; harmless but count is meaningless.
- In battle, deaths settle when any NPC next acts (not instantaneous).

## Testing

Manual verification in PCSX-Redux:

1. Load Summon Night ISO with `pcsx.lua`; both existing windows and the new `Battle Skip` window render.
2. Enter a battle; click Skip Battle; status shows the enemy count.
3. After any NPC acts, all enemies die and battle ends.
4. Kill count equals number of faction-1 units observed.
5. Click outside battle: no crash, UI keeps working, other windows unaffected.
