# ============================================================
# identify_script19_scenes — 完整提取 script19 所有 FID 场景对话
# ============================================================
# FIDs 0x4A-0x4D: 默认路径 (analyze_script_static)
# FIDs 0x4E-0x4F: monkey-patch 跳过所有 c4[0x95] 写入 + 遍历 c4[0x95]=4,5
#   根因: c4[0x95] 被多处写入覆盖 (CLEAR at 0x03B5, SET at 0x0ACC/0x0D04)，
#         同时 0xC7 未在 EXTERNAL_VARS 导致内部分支 switch 无法 fork
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 19
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

  # 0xC7 gates 12-branch switch at 0x38A9 (TEXT 360+ for FID 0x4F)
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

  # Monkey-patch: skip ALL writes to c4[0x95] to preserve our target value
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Skip SET c4[0x95]=N (0x0010) at 0x0ACC, 0x0D04, etc.
    if cmd.code == 0x0010 && cmd.params[0] == 0x95
      state.pc += 1
      return true
    end
    # Skip CLEAR c4[0x95] (0x0001) at 0x03B5
    if cmd.code == 0x0001 && cmd.params[0] == 0x0002 && cmd.params[1] == 0x0095
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

# Run 1: default path (c4[0x95]=0) for FIDs 0x4A-0x4D
puts "\n=== Run 1: Default (c4[0x95]=0) ==="
default_dialogs = analyze_script_static(SCRIPT_ID)
fid_list = default_dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
puts "  Found FIDs: #{fid_list.join(', ')}"
default_dialogs.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# Run 2: c4[0x95]=4 for FID 0x4E
puts "\n=== Run 2: c4[0x95]=4 (targeting 0x4E) ==="
dialogs4 = run_with_c4_95(commands, SCRIPT_ID, 4)
dialogs4.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# Run 3: c4[0x95]=5 for FID 0x4F
puts "\n=== Run 3: c4[0x95]=5 (targeting 0x4F) ==="
dialogs5 = run_with_c4_95(commands, SCRIPT_ID, 5)
dialogs5.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script19")

# Summary of FID coverage
puts
(0x4A..0x4F).each do |fid|
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
