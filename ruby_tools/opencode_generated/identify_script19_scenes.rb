# ============================================================
# identify_script19_scenes — 完整提取 script19 所有 FID 场景对话
# ============================================================
# FIDs 0x4A-0x4D: 默认路径 (c4[0x95]=0→1→2→3)
# FIDs 0x4E-0x4F: monkey-patch 跳过所有 c4[0x95] 写入 + 遍历 c4[0x95]=4,5
#   根因: c4[0x95]=4 在 idx=1035 被写入但被 idx=1255 覆写为 1，
#         导致 FID dispatch switch(idx=494) 永远看不到值 4/5
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
# Run analysis — force FID dispatch switch to target case
# ---------------------------------------------------------
def run_targeting_fid(commands, script_id, target_c4_95, fid_dispatch_off, case_targets)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup

  # Monkey-patch: force the FID dispatch switch (0x04D5) to route to our target case
  # Also set c4[0x95] to the target value so internal dialog routing uses the right branches
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.index == fid_dispatch_off && cmd.code == 0x0027
      state.tbl_c4[0x95] = target_c4_95
      target_off = case_targets[target_c4_95]
      if target_off
        t = @index_to_pc[target_off]
        if t
          state.pc = t
          return true
        end
      end
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
  state.tbl_c4[0x93] = 0

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running targeting FID via c4[0x95]=#{target_c4_95}..."
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

# FID dispatch switch at offset 0x04D5 (idx=494), var=0x95
# Case targets: 0:0x045F, 1:0x0481, 2:0x0491, 3:0x04A1, 4:0x04B1, 5:0x04C1
FID_DISPATCH_OFF = 0x04D5
CASE_TARGETS = { 4 => 0x04B1, 5 => 0x04C1 }  # c4[0x95] value => case entry offset

# Run 1: default (existing output covers FIDs 0x4A-0x4D)
puts "\n=== Run 1: SKIP (existing output covers FIDs 0x4A-0x4D) ==="

# Run 2: force FID dispatch → case 4 → FID 0x4E
puts "\n=== Run 2: targeting FID 0x4E ==="
dialogs4e = run_targeting_fid(commands, SCRIPT_ID, 4, FID_DISPATCH_OFF, CASE_TARGETS)

# Run 3: force FID dispatch → case 5 → FID 0x4F
puts "\n=== Run 3: targeting FID 0x4F ==="
dialogs4f = run_targeting_fid(commands, SCRIPT_ID, 5, FID_DISPATCH_OFF, CASE_TARGETS)

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
new_dialogs = {}
dialogs4e.each { |fid, groups| new_dialogs[fid] = groups }
dialogs4f.each { |fid, groups| new_dialogs[fid] = groups }

puts "\n=== Results ==="
# Only output the FIDs we targeted
target_fids = new_dialogs.keys
target_fids.each do |fid|
  groups = new_dialogs[fid]
  all_ids = Set.new
  groups.each { |g| g[:texts].each { |t| all_ids.add(t) } }
  puts "  FID 0x#{sprintf('%02X', fid)}: #{groups.size} groups, #{all_ids.size} unique texts"
end

# Write output files for new FIDs
output_results(new_dialogs, commands, "output_full/script19")

# Summary of coverage vs dialog files
puts
target_fids.sort.each do |fid|
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
    puts "  FID 0x#{sprintf('%02X', fid)}: #{extracted_ids.size}/#{non_empty} texts extracted (#{coverage}), #{new_dialogs[fid]&.size || 0} groups"
  end
end
