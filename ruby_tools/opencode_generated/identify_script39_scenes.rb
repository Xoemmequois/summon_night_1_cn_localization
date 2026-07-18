# ============================================================
# identify_script39_scenes — 完整提取 script39 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x041C —
#   case 0 → 0x03F8: SET_FID 0x8F
#   case 1 → 0x0408: SET_FID 0x90 (116 texts)
#   cases 2-3 → STUB
#
# Entry 1 (F9=0xA): 0x03B5 CLEAR c4[0x95]→call 0x03F6→switch 0x041C
#   c4[0x95]=0 → FID 0x8F
# Entry 2 (F9=4 handler): c4[0x21]==1 guard at 0x0475→c4[0x95]=1
#   →call 0x03F6→FID 0x90
#   c4[0x21] 跨脚本全局旗标, script39 内写入在孤儿子程序 0x04C2 (engine 回调)
#
# 修复: external_vars + [0x21], 迭代 c4[0x95]=0,1, 跳过 CLEAR at 0x03B5.
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 39
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

FID_MAP = { 0 => 0x8F, 1 => 0x90 }

def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # 0x21 for FID 0x90 entry gate (F9=4 handler);
  # 0xC6 for internal routing test c4[0xC6]==3 at 0x03C5 → CALL 0x09AC
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0x21, 0xC6]

  # Monkey-patch: skip CLEAR c4[0x95] at 0x03B5
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.code == 0x0001 && cmd.index == 0x03B5 && cmd.params[0] == 2 && cmd.params[1] == 0x95
      state.pc += 1
      return true
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

  fid = FID_MAP[c4_95_value] || c4_95_value
  puts "Running with c4[0x95]=#{c4_95_value} (expect FID 0x#{sprintf('%02X', fid)})..."
  run_manager(manager, commands, script_id)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  manager.dialogs
end

all_dialogs = {}

(0..1).each do |val|
  puts "\n=== Run: c4[0x95]=#{val} ==="
  dialogs = run_with_c4_95(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script39")

puts
[0x8F, 0x90].each do |fid|
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
