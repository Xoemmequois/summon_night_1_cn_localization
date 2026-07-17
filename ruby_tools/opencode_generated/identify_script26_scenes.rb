# ============================================================
# identify_script26_scenes — 完整提取 script26 所有 FID 场景对话
# ============================================================
# FID 0x62: switch var[0xC8] at 0x03D1 case 1 → SET_FID 0x62
# FID 0x65: switch var[0x95] at 0x04A9 case 3
# FID 0x66: switch var[0x95] at 0x04A9 case 4
# FID 0x67: switch var[0x95] at 0x04A9 case 5
# 0xC8 加入 external_vars 解决 FID 0x62 分配 switch 的 forking
# 0xC7 加入 external_vars 解决内部剧情 switch 的 forking
# Monkey-patch 跳过 c4[0x95]=3 写入 (0x03B7) + 遍历 c4[0x95]=3,4,5
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 26
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# ---------------------------------------------------------
# Run analysis with monkey-patched c4[0x95] value
# ---------------------------------------------------------
def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: default + 0xC8 (FID 0x62 dispatch) + 0xC7 (routing switch at 0x216A)
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC8, 0xC7]

  # Monkey-patch: skip the c4[0x95]=3 hardcode at 0x03B7 (var[0xC8] case 0)
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.code == 0x0010 && cmd.index == 0x03B7 && cmd.params[0] == 0x95
      state.pc += 1
      return true
    end
    old_dispatch.call(state, cmd, cmds)
  end

  # Initialize state
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
  state.tbl_c4[0xC8] = 0
  # c8[0x64]/c8[0x65] gates at 0x0ED9/0x0EE2 guard TEXT 37,38 for FID 0x67
  state.tbl_c8[0x64] = 1
  state.tbl_c8[0x65] = 1

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running with c4[0x95]=#{c4_95_value}..."
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

[3, 4, 5].each do |val|
  fid_target = 0x65 + val - 3
  puts "\n=== Run c4[0x95]=#{val} (targeting FID 0x#{sprintf('%02X', fid_target)}) ==="
  dialogs = run_with_c4_95(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

# Special run for FID 0x62: set c4[0xC8]=1 to force case 1 of the 0x03D1 switch
puts "\n=== Run c4[0xC8]=1 (targeting FID 0x62) ==="
run_fid62 = -> {
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

  state = VMState.new(SCRIPT_ID)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = 0
  state.tbl_c4[0x93] = 0
  state.tbl_c4[0xC8] = 1

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running with c4[0xC8]=1..."
  run_manager(manager, commands, SCRIPT_ID)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  manager.dialogs
}.call

run_fid62.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script26")

# Summary
puts
[0x62, 0x65, 0x66, 0x67].each do |fid|
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
