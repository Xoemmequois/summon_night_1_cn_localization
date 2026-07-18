# ============================================================
# identify_script31_scenes — 完整提取 script31 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x0531 —
#   case 0 → FID 0x77, case 1 → FID 0x78, case 2 → FID 0x79,
#   case 3 → FID 0x7A, case 4 → FID 0x7B
#
# c8[0x64]/c8[0x65] gates block variant text paths in FID-specific
# text subs (mode=4 tests not forked by handle_0003).
# Monkey-patch: fork c8[0x64]/c8[0x65] tests + skip all
# c4[0x95] writes. Iterate c4[0x95]=0..4.
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 31
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# All c4[0x95] writes in script31 — skip to preserve injected value
SKIP_95_WRITES = [0x03C3, 0x03D3, 0x0C0E, 0x0E6B, 0x0E83, 0x0E9B,
                  0x1AFA, 0x209F, 0x25E1]

# ---------------------------------------------------------
# Run analysis with monkey-patched c4[0x95] value
# ---------------------------------------------------------
def run_script31(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Fork c8[0x64] and c8[0x65] tests (mode=4, not forked by external_vars)
    if cmd.code == 0x0003 && cmd.params[0] == 4 && [0x64, 0x65].include?(cmd.params[1])
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

    # Skip c4[0x95] writes to keep injected value
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
# Main: iterate c4[0x95]=0..4
# ---------------------------------------------------------

all_dialogs = {}

[0, 1, 2, 3, 4].each do |val|
  puts "\n=== c4[0x95]=#{val} (FID 0x#{sprintf('%02X', [0x77,0x78,0x79,0x7A,0x7B][val])}) ==="
  dialogs = run_script31(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script31")

puts
puts "=== Coverage Summary ==="
[0x77, 0x78, 0x79, 0x7A, 0x7B].each do |fid|
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
