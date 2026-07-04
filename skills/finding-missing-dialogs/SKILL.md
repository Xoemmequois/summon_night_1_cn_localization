---
name: finding-missing-dialogs
description: Use when the user asks to identify or extract previously unrecognized dialogue texts for a specific FID in Summon Night. Traces 0x2013 instructions through XREF call chains to find blocking switch variables or conditional guards. Adds them to EXTERNAL_VARS or uses direct entry to extract hidden scenes.
---

# Finding Missing Dialogue Texts

## Workflow

### Step 1: Confirm the gap

Compare already-extracted texts against the full dialog file contents.

Extract the TEXT indices already present from the processed output files:

```ruby
# Read from ruby_tools/opencode_generated/processed/script{N}_fid{XX}.txt
# Extract all "TEXT:XXXX" references from lines like:
#   +[FID:18, TEXT:0001] 译文
extracted = processed_file.scan(/TEXT:([0-9A-F]{4})/).map { |m| m[0].to_i(16) }.to_set
```

Get all non-empty string indices from the dialog file (CM1100.DAT subcontent `fid + 0x29`), subtract the extracted set. The diff is the missing texts.

### Step 2: Find the 0x2013 instructions

Search the extracted command script (`CM1100.DAT_{sid}`) for `0x2013` instructions with the missing TEXT index:

```ruby
commands.each_with_index do |c, i|
  if c.code == 0x2013 && missing_texts.include?(c.params[0])
    # Found at byte offset c.index, array position i
  end
end
```

### Step 3: Build XREF and trace call chain

Build a cross-reference map:
- `xref_targets[idx]` → list of target offsets (jumps/calls/switch cases from this instruction)
- `xref_incoming[offset]` → list of source indices (who jumps/calls here)

Trace backward from the 0x2013:
1. **Containing subroutine**: walk backward to previous `0x0026`, forward to next matching `0x0026`
2. **Call sites**: search for `0x0025 call <entry_offset>` that call into this sub
3. **Dispatch switch**: find the enclosing `0x0027` switch that routes to the call site
4. **Switch variable**: identify `var[0xXX]` used in the dispatch

### Step 4: Check the switch variable

| Status | Action |
|--------|--------|
| **In `EXTERNAL_VARS`** | Path exists but may be starved by visited-state dedup (Step 6) |
| **NOT in `EXTERNAL_VARS`** | Add it: `manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xXX]` |

### Step 5: Check for conditional guards

Pattern:

```
test c4[0xXX] == 0     → sets regB bit0
jmp_if_NOT_regB → ENTER  (0x0022: jump if regB&1 == 0)
goto → SKIP                (falls through when c4[0xXX]==0)
```

Logic: `c4[0xXX] == 0` → skip subroutine; `c4[0xXX] != 0` → enter.

Search for all writes (`0x0010`, `0x0011`, `0x0001`, `0x0008`, `0x0009`) to that variable. **Verify** the write and read are in the same FID execution path — they may be in mutually exclusive `switch var[0x95]` branches.

### Step 6: Direct entry (when visited-state budget is saturated)

Start the VM directly from the call site to bypass full traversal:

```ruby
state = VMState.new(script_id)
state.dialog_file_id = target_fid
state.pc = idx_of_call_instruction
manager.push(state)
run_manager(manager, commands, script_id)
```

### Step 7: Verify

Compare new extraction against the dialog file. Expected: all non-empty strings covered.

## Key patterns

| Pattern | Example | Fix |
|---------|---------|-----|
| Switch variable not external | `switch var[0x22]` in sub 0x2ADD | Add to `EXTERNAL_VARS` |
| Conditional guard | `test c4[0x9D]==0` before sub | Add to `EXTERNAL_VARS` |
| Write unreachable from this FID | `inc c4[0x9D]` only in case0, read in case2 | That path never triggers for this FID |
| Switch IS external but starved | `switch var[0x93]` with 21 cases | Use direct entry (Step 6) |

## Pitfalls

- **Linear FID tracking is unreliable**: control flow matters, not file layout
- **`var[0x95]` changes runtime but FID stays**: the loop iterates through cases, but `dialog_file_id` is set once at entry
- **200k visited state limit** can starve correct forks when a high-case-count switch dominates
