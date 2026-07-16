---
name: finding-missing-dialogs
description: Use when the user asks to identify or extract previously unrecognized dialogue texts for a specific FID in Summon Night. Traces 0x2013 instructions through XREF call chains to find blocking switch variables or conditional guards. Adds them to EXTERNAL_VARS or uses direct entry to extract hidden scenes.
---

# Finding Missing Dialogue Texts

## Workflow

### Step 1: Confirm the gap

Use the ready-made tool `compare_dialog_coverage.rb` — it automates the whole comparison:

```powershell
# CWD: ruby_tools/opencode_generated/
ruby compare_dialog_coverage.rb <FID>    # FID in hex, e.g. 02, 0A, 1F, 91
```

It parses the dialog file (CM1100.DAT subcontent `fid + 0x29`), collects covered TEXT indices from all `processed/script*_fid{XX}.txt` files, and prints every string present in the dialog file but missing from `processed/`, plus a coverage percentage. If it prints "Result: fully covered" there is no gap.

**Under the hood** (if you need to do it manually):

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

### Step 7: Verify completeness and crossover

Re-run `ruby compare_dialog_coverage.rb <FID>` (Step 1) to confirm coverage is now 100% — note it reads from `processed/`, so merge new extraction there first. Expected: all non-empty strings covered AND no cross-FID contamination (crossover must still be checked manually below).

**Crossover detection**: After extraction, verify that each FID's output ONLY contains TEXT indices that exist in that FID's own dialog file.

```ruby
require "set"
fid = 0x1E
dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
contents = IO.binread(dialog_fn)
len = contents.unpack1("S!<")
indices = contents.unpack("S!<#{len}")

# Get valid TEXT indices from this FID's dialog file
valid_texts = Set.new
(0...len).each do |ti|
  next if ti >= indices.size
  s = indices[ti]
  str = ""; p = 0
  loop do
    break if contents[s * 2 + p] == "\x0" && contents[s * 2 + p + 1] == "\x0"
    str += contents[s * 2 + p] + contents[s * 2 + p + 1]
    p += 2
    break if p > 200
  end
  valid_texts.add(ti) unless str.strip.empty?
end

# Check output file
fn = "output_full/script06_fid1E.txt"
extracted = File.read(fn).scan(/TEXT:([0-9A-F]{4})/).map { |m| m[0].to_i(16) }.to_set

crossover = extracted - valid_texts
missing   = valid_texts - extracted

puts "Crossover (from other FIDs): #{crossover.size}"  # should be 0 or near 0
puts "Missing (not extracted):    #{missing.size}"      # should be 0
```

**Crossover symptoms**: lines like `[FID:1C, TEXT:0000]` or `[FID:1C, TEXT:000B]` in a FID file where those TEXT indices don't exist — this means dialogs from other FIDs are leaking in.

**Common causes of crossover**:
- FID set AFTER the dialog dispatch runs (0x4B8 runs before 0x002F at idx 479)
- 0x002E handler in VM sets `dialog_file_id = -1`, but the real game computes it from a variable
- `c4[0x95]` hardcoded to a fixed value (`0x0010` at entry), overriding per-FID init

### Step 8: Fix crossover with monkey-patches (script-specific)

When the script's FID dispatch runs AFTER dialog playback, monkey-patch the VM to set FID at the correct point:

```ruby
old_dispatch = manager.method(:dispatch)
manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
  # Skip hardcoded c4[0x95]=N that overrides our per-FID init value
  if cmd.code == 0x0010 && cmd.index == OFFSET && cmd.params[0] == 0x95
    state.pc += 1
    return true
  end
  # Override 0x002E to set FID from c4[0x95] instead of -1
  if cmd.code == 0x002E && cmd.index == OFFSET
    state.dialog_file_id = FID_MAP[state.read_c4(0x95)]
  end
  old_dispatch.call(state, cmd, cmds)
end
```

Then iterate per-FID with dedicated `c4[0x95]` values:

```ruby
FID_MAP = { 3 => 0x19, 4 => 0x1A, 5 => 0x1B, ... }
FID_MAP.each do |val, fid|
  state.tbl_c4[0x95] = val
  # run VM, dialogs will be attributed to correct FID
end
```

### Step 9: Trace never-executed 0x2013 with VM instrumentation

When texts are missing within a single FID despite correct switch routing, the gap may be caused by an **unhandled opcode** that silently routes execution away from the target dialog. Instrument the VM to log every 0x2013 execution, then cross-reference against the script to isolate the blocking instruction.

#### 9.1: Instrument the dispatch loop

In the monkey-patched `dispatch` method, log every 0x2013 instruction that falls within the missing TEXT range:

```ruby
# In the monkey-patch block (inside define_singleton_method(:dispatch)):
if cmd.code == 0x2013 && cmd.params[0] >= LO && cmd.params[0] <= HI
  $trace << {
    fid: state.dialog_file_id,
    text: cmd.params[0],
    cmd_idx: cmds.index(cmd),
    cmd_offset: cmd.index
  }
end
```

Run the analysis for each target `c4[0x95]` value. This produces a list of every 0x2013 execution with its FID attribution.

#### 9.2: Identify never-executed commands

Compare the trace against ALL 0x2013 instructions in the parsed command script:

```ruby
all_executed_idx = Set.new($trace.map { |t| t[:cmd_idx] })
commands.each_with_index do |c, i|
  if c.code == 0x2013 && c.params[0] >= LO && c.params[0] <= HI
    unless all_executed_idx.include?(i)
      puts "  idx=#{i} off=0x#{sprintf('%04X',c.index)}: TEXT=0x#{sprintf('%02X',c.params[0])} — NEVER EXECUTED"
    end
  end
end
```

Commands that appear in the script but never in the trace are gated by an undiscovered condition.

#### 9.3: Trace the blocking gate

From the never-executed instruction's index, walk backward to find the nearest conditional branch (`0x0020`/`0x0021`/`0x0022`) or RPN expression (`0x000A`) that controls the flow:

```ruby
# Walk backward from never-executed index
(idx).downto([idx - 200, 0].max) do |j|
  c = commands[j]
  if [0x0020, 0x0021, 0x0022, 0x000A].include?(c.code)
    puts "  Gate at idx=#{j} off=0x#{sprintf('%04X',c.index)}: 0x#{sprintf('%04X',c.code)}"
    # Found the gate
  end
end
```

Common patterns:
- `0x000A` RPN + `0x0020 JMP_IF_A` — the VM's `handle_000A` only handles the gender pattern (`0x001D`+`0x0088`). Any other RPN (e.g. `c4[0xA2] < 2` with `0x0089`) leaves `regA` at 0, so `JMP_IF_A` never jumps.
- `0x0003 TEST_EQ0` + `0x0022 JMP_NOT_B1` — a conditional guard on a variable not in `EXTERNAL_VARS`.

#### 9.4: Fix with a targeted fork at the gate

For an unhandled RPN → JMP_IF_A chain, fork both `regA` values at the `JMP_IF_A` instruction:

```ruby
# c4[0xA2] < 2 check at 0x1616, not handled by handle_000A
# Fork both regA=0 and regA=1 at JMP_IF_A 0x161D
if cmd.index == 0x161D && cmd.code == 0x0020
  fork_state = state.clone
  fork_state.regA = 1
  fork_state.pc = index_to_pc[cmd.params[0]]  # jump target
  push(fork_state)
  state.regA = 0
  state.pc += 1  # fall through
  return true
end
```

This creates two execution states: one that takes the jump (reaching the hidden dialogs) and one that falls through (keeping the existing behavior).

## Key patterns

| Pattern | Example | Fix |
|---------|---------|-----|
| Switch variable not external | `switch var[0x22]` in sub 0x2ADD | Add to `EXTERNAL_VARS` |
| Conditional guard | `test c4[0x9D]==0` before sub | Add to `EXTERNAL_VARS` |
| Write unreachable from this FID | `inc c4[0x9D]` in case0, read in case2 | That path never triggers for this FID |
| Switch IS external but starved | `switch var[0x93]` with 21 cases | Use direct entry (Step 6) |
| FID set after dispatch (crossover) | `0x002E` sets -1, 0x4B8 plays, switch sets FID too late | Monkey-patch 0x002E + skip c4[0x95] hardcode |
| Missing on different entry path | sub 0x3449 only reached from F8=0 | Direct entry with `dialog_file_id` set manually |
| RPN gate unhandled by VM | `0x000A c4[0xA2] < 2` → `JMP_IF_A` never jumps | Instrument VM to trace 0x2013, fork both regA values at JMP_IF_A (Step 9) |

## Pitfalls

- **Linear FID tracking is unreliable**: control flow matters, not file layout
- **`var[0x95]` changes runtime but FID stays**: the loop iterates through cases, but `dialog_file_id` is set once at entry
- **200k visited state limit** can starve correct forks when a high-case-count switch dominates
- **Always verify crossover after extraction**: run the validation check in Step 7. A file showing 100% coverage with crossover is still wrong.
