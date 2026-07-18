# ============================================================
# identify_script33_scenes — 完整提取 script33 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x049D —
#   case 0 → 0x044F: SET_FID 0x7E (バノッサ戦 前編)
#   case 1 → 0x046B: SET_FID 0x7F (バノッサ戦 後編)
#   case 2 → 0x047B: SET_FID 0x80 (オルドレイク登場〜真相)
#   case 3 → 0x048B: SET_FID 0x81 (仲間の裏切り〜エルゴの力)
#
# c4[0x95]=2 写入在 0x0A44, 由 c4[0x21]==1 守卫 (0x0005@0x0A3B)
# c4[0x95]=3 写入在 0x0AB0, 由 c4[0x21]==1 守卫 (0x0005@0x0AA7)
# c4[0x21] 是跨脚本全局旗标 (同 script29), 引擎回调在 0x0B13 子程序
# 写入, 脚本内被 0x0005 读取但 VM 看不到写入 → 永远走 case 0/1 路径。
#
# 修复: 把 0x21 加入 external_vars, 在比较处 fork 两侧,
# regB=1 分支自然进入 case 2/3 的 0x95 写入流程。
# 不需要 monkey-patch 或直接入口 — analyze_script_static 足够。
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 33
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# ---------------------------------------------------------
# Run analysis with 0x21 as external var
# ---------------------------------------------------------
def run_script33(commands, script_id)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: default + 0x21 (全局事件旗标, 控制 FID 0x80/0x81 分支)
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0x21]

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

  puts "Running with external_vars + [0x21]..."
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

dialogs = run_script33(commands, SCRIPT_ID)
dialogs.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script33")

# Summary of FID coverage
puts
[0x7E, 0x7F, 0x80, 0x81].each do |fid|
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
