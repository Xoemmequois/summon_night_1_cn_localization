# ============================================================
# identify_script16_scenes — 完整提取 script16 所有 FID 场景对话
# ============================================================
# FIDs 0x3F-0x40: 默认路径 (c4[0x95]=3→4)
# FIDs 0x41-0x43: monkey-patch 跳过 c4[0x95]=3 写入 + 遍历 c4[0x95]=5,6,7
# 0xC7 加入 external_vars 解决内部剧情 switch 的 forking
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 16
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

  # external_vars: keep default + add 0xC7 for internal routing switch
  # do NOT add 0x95 — let the FID dispatch switch route naturally
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

  # Monkey-patches:
  #   1) skip c4[0x95]=3 at 0x03B5 (F9=0xA handler)
  #   2) fork regA=1 at 0x1B80 RPN (c4[0x99] < 2) to reach TEXT 0xCD/0xCF
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.code == 0x0010 && cmd.index == 0x03B5 && cmd.params[0] == 0x95
      state.pc += 1
      return true
    end
    # 0x000A at 0x1B80: c4[0x99] comparison → fork regA=1 path to 0x1B91 (TEXT 0xCD/0xCF)
    if cmd.code == 0x000A && cmd.index == 0x1B80
      old_pc = state.pc
      # Let default handler execute first (regA stays 0 → else branch)
      result = old_dispatch.call(state, cmd, cmds)
      # Fork: regA=1 → take the JMP_IF_A branch to 0x1B91
      fork_state = state.clone
      fork_state.pc = old_pc + 1  # past the 0x000A
      fork_state.regA = 1
      push(fork_state)
      return result
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
c4_95_values = [3, 5, 6, 7]  # 3→0x3F+0x40, 5→0x41, 6→0x42, 7→0x43

c4_95_values.each do |val|
  puts "\n=== Run: c4[0x95]=#{val} ==="
  dialogs = run_with_c4_95(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script16")

# Summary of FID coverage
puts
dialog_ids = (0x3F..0x43).to_a
dialog_ids.each do |fid|
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
