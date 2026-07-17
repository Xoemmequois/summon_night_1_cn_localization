# ============================================================
# identify_script28_scenes — 完整提取 script28 所有 FID 场景对话
# ============================================================
# 直接入口: 从 F9=4 handler (0x09A2) 直接进入，跳过大段前期路由
#   switch var[0x95] at 0x09D3:
#     case 0→CALL 0x0BFD(FID 0x6C), case 1→CALL 0x1067(FID 0x6D),
#     case 2→CALL 0x23F1(FID 0x6E), case 3→CALL 0x25D7(FID 0x6F),
#     case 4→CALL 0x274A(FID 0x70), case 5→CALL 0x293A(FID 0x71)
# 0xC8, 0xDC 加入 external_vars 解决内部分支
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 28
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# FID dispatch mapping: c4[0x95] → FID
FID_MAP = { 0 => 0x6C, 1 => 0x6D, 2 => 0x6E, 3 => 0x6F, 4 => 0x70, 5 => 0x71 }

# F9=4 handler entry point
F9_4_ENTRY = 0x09A2

# ---------------------------------------------------------
# Direct entry: start VM from F9=4 handler
# ---------------------------------------------------------
def run_direct_entry(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC8, 0xDC]

  # Monkey-patch: fork regA at JMP_IF_A 0x107C (RPN c4[0x9D] < 8 gate)
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.code == 0x0020 && cmd.index == 0x107C
      fork_state = state.clone
      fork_state.regA = 1
      t = index_to_pc[cmd.params[0]]
      if t
        fork_state.pc = t
        push(fork_state)
      end
      state.regA = 0
      state.pc += 1
      return true
    end
    old_dispatch.call(state, cmd, cmds)
  end

  state = VMState.new(script_id)
  # Standard c4 state (matching analyze_script_static)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 4           # F9=4 — enters F9=4 handler loop
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = c4_95_value
  state.tbl_c4[0x93] = 0
  # Pre-set dialog_file_id
  state.dialog_file_id = FID_MAP[c4_95_value]

  fid = FID_MAP[c4_95_value]
  puts "Running direct entry: c4[0x95]=#{c4_95_value} → FID 0x#{sprintf('%02X', fid)}"

  idx = manager.index_to_pc[F9_4_ENTRY]
  unless idx
    puts "  ERROR: entry point 0x#{sprintf('%04X', F9_4_ENTRY)} not found"
    return {}
  end
  state.pc = idx
  manager.push(state)

  run_manager(manager, commands, script_id)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  manager.dialogs
end

# ---------------------------------------------------------
# Main: iterate all c4[0x95] values
# ---------------------------------------------------------

all_dialogs = {}

  # Extra run for FID 0x6D: F9=0 handler covers texts 564-578 (not in F9=4 handler)
  def run_f9_0_entry(commands, script_id, fid, c4_95_value)
    manager = ExecManager.new
    manager.index_to_pc = {}
    commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
    manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC8, 0xDC]

    state = VMState.new(script_id)
    state.tbl_c4[0xF8] = 3
    state.tbl_c4[0xF9] = 0           # F9=0
    state.tbl_c4[0xFA] = 0x0D
    state.tbl_c4[0xFB] = 0
    state.tbl_c4[0xFC] = 0
    state.tbl_c4[0xC4] = 4
    state.tbl_c4[0xC3] = 4
    state.tbl_c4[0x95] = c4_95_value
    state.tbl_c4[0x93] = 0
    state.dialog_file_id = fid

    idx = manager.index_to_pc[0x051F]  # F9=0 handler entry
    state.pc = idx
    manager.push(state)
    run_manager(manager, commands, script_id)
    manager.dialogs
  end

  result0 = run_f9_0_entry(commands, SCRIPT_ID, 0x6D, 1)
  result0.each { |fid, groups| all_dialogs[fid] ||= Set.new; all_dialogs[fid] += groups }
  puts "F9=0 entry: added #{result0[0x6D]&.size || 0} groups for FID 0x6D"
  puts

  [0, 1, 2, 3, 4, 5].each do |val|
  puts "\n=== Direct entry c4[0x95]=#{val} (FID 0x#{sprintf('%02X', FID_MAP[val])}) ==="
  dialogs = run_direct_entry(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script28")

puts
(0x6C..0x71).each do |fid|
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
    puts "  FID 0x#{sprintf('%02X', fid)}: #{extracted_ids.size}/#{non_empty} texts (#{coverage}), #{extracted&.size || 0} groups"
  end
end
