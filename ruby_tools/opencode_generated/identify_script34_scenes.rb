# ============================================================
# identify_script34_scenes — 完整提取 script34 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x03F0 —
#   case 0 → FID 0x82, case 1 → FID 0x83
# State machine loops through c4[0x95]=0..1 naturally.
#
# Missing texts in FID 0x82 are gated by c8[0x64]/c8[0x65]/c8[0x66]
# tests (0x0003 mode=4) in text sub 0x04A2 (copy 0).
#
# Gate map (sub 0x04A2):
#   c8[0x64] at 0x058B → TEXT:001F
#   c8[0x65] at 0x0701 → TEXT:0040, 0041, 0042
#   c8[0x66] at 0x0778 → TEXT:0052, 0053, 0054
# Text sub 0x1481 (copy 1) has no c8 gates → these texts
# already covered in that variant, but only copy 0 has the
# specific attribution to FID 0x82 when it's active.
#
# FID 0x83 is already 100% covered.
#
# Fix: monkey-patch c8[0x64]/c8[0x65]/c8[0x66] tests + skip
# c4[0x95] writes at 0x03B5 and 0x0493. Iterate c4[0x95]=0..1.
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 34
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

SKIP_95_WRITES = [0x03B5, 0x0493]

# ---------------------------------------------------------
def run_script34(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Fork c8[0x64]/c8[0x65]/c8[0x66] tests (mode=4)
    if cmd.code == 0x0003 && cmd.params[0] == 4 && [0x64, 0x65, 0x66].include?(cmd.params[1])
      old_pc = state.pc
      val = state.read_c8(cmd.params[1])
      result = (val == 0)
      state.regB = state.regB & 0xFE
      state.regB |= 1 if result

      fork_state = state.clone
      fork_state.pc = old_pc + 1
      fork_state.regB = fork_state.regB & 0xFE
      fork_state.regB |= (result ? 0 : 1)
      push(fork_state)

      state.pc += 1
      return true
    end

    # Skip c4[0x95] writes
    if SKIP_95_WRITES.include?(cmd.index)
      if cmd.code == 0x0001 && cmd.params[0] == 2 && cmd.params[1] == 0x95
        state.pc += 1; return true
      elsif cmd.code == 0x0010 && cmd.params[0] == 0x95
        state.pc += 1; return true
      end
    end

    old_dispatch.call(state, cmd, cmds)
  end

  state = VMState.new(script_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = c4_95_value
  state.tbl_c4[0x93] = 0

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  run_manager(manager, commands, script_id)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  manager.dialogs
end

# ---------------------------------------------------------
# Main: iterate c4[0x95]=0..1
# ---------------------------------------------------------

all_dialogs = {}

[0, 1].each do |val|
  puts "\n=== c4[0x95]=#{val} (FID 0x#{sprintf('%02X', [0x82, 0x83][val])}) ==="
  dialogs = run_script34(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script34")

puts
puts "=== Coverage Summary ==="
[0x82, 0x83].each do |fid|
  sub_id = fid + 0x29
  dialog_fn = "../../exported/CM1100.DAT_#{sub_id}"
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    total_strings = contents.unpack1("S!<")
    non_empty = 0
    indices = contents.unpack("S!<#{total_strings}")
    (0...total_strings).each do |ti|
      next if ti >= indices.size
      s = indices[ti]
      str_start = s * 2
      next if str_start + 1 >= contents.size
      if contents[str_start] != "\x0" || contents[str_start + 1] != "\x0"
        non_empty += 1
      end
    end
    extracted = all_dialogs[fid]
    extracted_ids = Set.new
    extracted&.each { |g| g[:texts].each { |t| extracted_ids.add(t) } }
    coverage = non_empty > 0 ? "%.1f%%" % (extracted_ids.size * 100.0 / non_empty) : "N/A"
    puts "  FID 0x#{sprintf('%02X', fid)}: #{extracted_ids.size}/#{non_empty} texts extracted (#{coverage}), #{extracted&.size || 0} groups"
  end
end
