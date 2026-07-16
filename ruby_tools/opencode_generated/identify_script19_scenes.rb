# ============================================================
# identify_script19_scenes — 完整提取 script19 所有 FID 场景对话
# ============================================================
# FIDs 0x4A-0x4D: 默认路径 (c4[0x95]=0→1→2→3)
# FIDs 0x4E-0x4F: 三层 monkey-patch:
#   1. switch var[0x95] @0x04D5 — 强制 FID dispatch 路由
#   2. switch var[0x95] @0x091E — F9=4 handler 路由（c4[0x95] 被中间写入覆盖）
#   3. switch var[0xC7] @0x38A9 — 加入 external_vars, fork 12 路剧情分支
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
# Targeted analysis for a specific c4[0x95] → FID
# ---------------------------------------------------------
def run_targeting_fid(commands, script_id, target_c4_95)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Force FID dispatch switch (0x04D5) to target case
    if cmd.index == 0x04D5 && cmd.code == 0x0027
      state.tbl_c4[0x95] = target_c4_95
      t_off = CASE_MAP[target_c4_95][:fid_dispatch]
      t = @index_to_pc[t_off]
      if t then state.pc = t; return true end
    end
    # Force F9=4 handler switch (0x091E) — c4[0x95] may have been overwritten
    if cmd.index == 0x091E && cmd.code == 0x0027
      state.tbl_c4[0x95] = target_c4_95
      t_off = CASE_MAP[target_c4_95][:f9_handler]
      t = @index_to_pc[t_off]
      if t then state.pc = t; return true end
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
  state.tbl_c4[0x93] = 0

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running c4[0x95]=#{target_c4_95}..."
  run_manager(manager, commands, script_id)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  manager.dialogs
end

# c4[0x95] → FID dispatch target → F9=4 handler target
CASE_MAP = {
  4 => { fid_dispatch: 0x04B1, f9_handler: 0x0912 },  # FID 0x4E
  5 => { fid_dispatch: 0x04C1, f9_handler: 0x0916 },  # FID 0x4F
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

# FIDs 0x4A-0x4D: already in existing output_full/ files, skip
puts "\n=== EXISTING: FIDs 0x4A-0x4D (output_full/script19_fid4A.txt..4D.txt) ==="

# FID 0x4E
puts "\n=== FID 0x4E (c4[0x95]=4) ==="
dialogs4e = run_targeting_fid(commands, SCRIPT_ID, 4)

# FID 0x4F
puts "\n=== FID 0x4F (c4[0x95]=5) ==="
dialogs4f = run_targeting_fid(commands, SCRIPT_ID, 5)

# Output
puts "\n=== Output ==="
new_dialogs = {}
dialogs4e.each { |fid, groups| new_dialogs[fid] = groups }
dialogs4f.each { |fid, groups| new_dialogs[fid] = groups }
output_results(new_dialogs, commands, "output_full/script19")

# Coverage summary
puts
new_dialogs.keys.sort.each do |fid|
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
    extracted_ids = Set.new
    new_dialogs[fid]&.each { |g| g[:texts].each { |t| extracted_ids.add(t) } }
    coverage = non_empty > 0 ? "%.1f%%" % (extracted_ids.size * 100.0 / non_empty) : "N/A"
    puts "  FID 0x#{sprintf('%02X', fid)}: #{extracted_ids.size}/#{non_empty} texts (#{coverage}), #{new_dialogs[fid]&.size || 0} groups"
  end
end
