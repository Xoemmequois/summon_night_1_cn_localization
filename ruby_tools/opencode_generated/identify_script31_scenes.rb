# ============================================================
# identify_script31_scenes — 完整提取 script31 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x0531 —
#   case 0 → FID 0x77, case 1 → FID 0x78, case 2 → FID 0x79,
#   case 3 → FID 0x7A, case 4 → FID 0x7B
# State machine loops through c4[0x95]=0..4 naturally.
#
# Missing texts are gated by c8[0x64]/c8[0x65] tests (0x0003 mode=4)
# that the VM's handle_0003 only forks for c4 (mode=2) external_vars,
# NOT for c8 (mode=4). Since nothing writes to c8[0x64]/c8[0x65]
# in script31 (the values are set by sub-scripts 0x002C), they stay
# at 0 and these gates always skip the variant text paths.
#
# c8[0x64] gates → TEXT:0002/0003, 0051, 0071 (FID 0x7B)
# c8[0x65] gates → TEXT:0026 (FID 0x77), 0011 (FID 0x79),
#                   0010 (FID 0x7A)
# FID 0x78 has no c8 gate in its text sub → 100% covered.
#
# Fix: monkey-patch 0x0003 mode=4 to fork both regB outcomes when
# testing c8[0x64] or c8[0x65].
#
# Results: FID 0x77 100%, FID 0x78 100%, FID 0x7B 100%,
# FID 0x79 99.5% (TEXT:004D still missing), FID 0x7A 96.9%
# (TEXT:002A/2B/2C/004D/4E/4F still missing).
#
# Remaining gap: 7 texts in a shared text hub at 0x0D32, gated
# behind the unhandled RPN expression c4[0xDC]<2 at 0x0472.
# The VM's handle_000A only evaluates c4[0x1D]<2 (gender) and
# can't handle this pattern. Direct entry into the hub fails
# due to complex initialization requirements.
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

# ---------------------------------------------------------
# Run analysis with c8[0x64]/c8[0x65] fork
# ---------------------------------------------------------
def run_script31(commands, script_id)
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
      state.regB |= 1 if result  # regB bit0 = 1 when val == 0

      # Fork: regB bit0 = 0 (val != 0 path)
      fork_state = state.clone
      fork_state.pc = old_pc + 1
      fork_state.regB = fork_state.regB & 0xFE
      fork_state.regB |= (result ? 0 : 1)  # opposite of result
      push(fork_state)

      state.pc += 1
      return true
    end

    old_dispatch.call(state, cmd, cmds)
  end

  # Initialize state (matching analyze_script_static)
  state = VMState.new(script_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
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
# Main
# ---------------------------------------------------------

all_dialogs = {}

dialogs = run_script31(commands, SCRIPT_ID)
dialogs.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script31")

# Summary of FID coverage
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
