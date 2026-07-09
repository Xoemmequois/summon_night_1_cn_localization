# ============================================================
# identify_script9_scenes — 完整提取 script09 所有 FID 场景对话
# ============================================================
# FIDs 0x22-0x24: 默认路径 (c4[0x95]=3→4→5)
# FIDs 0x25-0x27: monkey-patch 跳过 c4[0x95]=3 写入 + 遍历 c4[0x95]=6,7,8
# 0xC7 加入 external_vars 解决内部剧情 switch 的 forking
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 9
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
def run_with_c4_95(commands, script_id, c4_95_value, tag)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: keep default + add 0xC7 for the end-game routing switch at 0x2EAF
  # do NOT add 0x95 — let the FID dispatch switch route naturally
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

  # Monkey-patch: skip the c4[0x95]=3 hardcode at 0x03B5 (F9=0xA handler)
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.code == 0x0010 && cmd.index == 0x03B5 && cmd.params[0] == 0x95
      # puts "  [SKIP] c4[0x95]=3 at 0x03B5 (keeping c4[0x95]=#{c4_95_value})"
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

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running with c4[0x95]=#{c4_95_value}..."
  run_manager(manager, commands, script_id)

  # Report
  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  { dialogs: manager.dialogs, tag: tag }
end

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

all_dialogs = {}

# Run 1: default path (c4[0x95]=3) for FIDs 0x22-0x24
puts "\n=== Run 1: Default (c4[0x95]=3) ==="
result1 = run_with_c4_95(commands, SCRIPT_ID, 3, nil)
result1[:dialogs].each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# Run 2: c4[0x95]=6 for FIDs 0x25-0x27 (case 6 of 0x093A)
puts "\n=== Run 2: c4[0x95]=6 (targeting 0x25-0x27) ==="
result2 = run_with_c4_95(commands, SCRIPT_ID, 6, nil)
result2[:dialogs].each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# Run 3: c4[0x95]=7 (case 7 of 0x093A → CALL 0x217B) for missing FID 0x26 paths
puts "\n=== Run 3: c4[0x95]=7 (targeting remaining 0x26 paths) ==="
result3 = run_with_c4_95(commands, SCRIPT_ID, 7, nil)
result3[:dialogs].each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# Run 4: c4[0x95]=8 (case 8 of 0x093A → CALL 0x244A) for missing FID 0x27 paths
puts "\n=== Run 4: c4[0x95]=8 (targeting remaining 0x27 paths) ==="
result4 = run_with_c4_95(commands, SCRIPT_ID, 8, nil)
result4[:dialogs].each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script09")

# Summary of FID coverage
puts
dialog_ids = (0x22..0x27).to_a
dialog_ids.each do |fid|
  sub_id = fid + 0x29
  dialog_fn = "../../exported/CM1100.DAT_#{sub_id}"
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    total_strings = contents.unpack1("S!<")
    # Count non-empty strings
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
