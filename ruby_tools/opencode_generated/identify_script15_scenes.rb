# ============================================================
# identify_script15_scenes — 完整提取 script15 所有 FID 场景对话
# ============================================================
# 问题: FID 0x3C 有 58 个文本未提取 (TEXT 211-268)
# 根因: idx=1242 TEST_EQ0 c4[0xA5] → 条件守卫, c4[0xA5] 恒为 0
#       c4[0xA5] 不在 EXTERNAL_VARS, VM 只走跳过路径
# 修复: 加入 0xA5 到 external_vars, forking 到 CALL 0x148E
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 15
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"
puts "0x2013 count: #{commands.count { |c| c.code == 0x2013 }}"
puts "0x002F count: #{commands.count { |c| c.code == 0x002F }}"

# Run analysis with 0xA5 in external_vars
manager = ExecManager.new
manager.index_to_pc = {}
commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
# 0xA5: grd@idx=1242 → 0x148E; 0xA8: grd@idx=1278 → 0x1CAA
manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xA5, 0xA8]

state = VMState.new(SCRIPT_ID)
state.tbl_c4[0xF8] = 3
state.tbl_c4[0xF9] = 0xA
state.tbl_c4[0xFA] = 0x0D
state.tbl_c4[0xFB] = 0
state.tbl_c4[0xFC] = 0
state.tbl_c4[0xC4] = 4
state.tbl_c4[0xC3] = 4

idx = manager.index_to_pc[0x012E]
state.pc = idx || 127
manager.push(state)

puts "Running with external_vars: #{manager.external_vars.map { |v| sprintf('0x%02X', v) }.join(', ')}..."
run_manager(manager, commands, SCRIPT_ID)

all_dialogs = manager.dialogs

# Output
puts "\n=== Results ==="
output_results(all_dialogs, commands, "output_full/script15")

# Summary of FID coverage
puts
fid_list = all_dialogs.keys.sort
fid_list.each do |fid|
  sub_id = fid + 0x29
  dialog_fn = "../../exported/CM1100.DAT_#{sub_id}"
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    total_strings = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{total_strings}")
    non_empty = 0
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
