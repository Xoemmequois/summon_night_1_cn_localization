# ============================================================
# identify_script33_scenes — 完整提取 script33 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x049D —
#   case 0 → 0x044F: SET_FID 0x7E (バノッサ戦 前編)
#   case 1 → 0x046B: SET_FID 0x7F (バノッサ戦 後編)
#   case 2 → 0x047B: SET_FID 0x80 (オルドレイク登場〜真相)
#   case 3 → 0x048B: SET_FID 0x81 (仲間の裏切り〜エルゴの力)
#
# 直接入口: monkey-patch 跳过 c4[0x95]=0 (0x0001@0x03B5, F9=10 handler),
# 然后遍历 c4[0x95]=0,1,2,3, 从 0x012E 标准入口进入。
# c4[0x95]=2,3 原本由 c4[0x21]==1 守卫 (跨脚本全局旗标, VM 看不到),
# 通过直接设定 c4[0x95] 值绕过守卫, 无需 external_vars + [0x21]。
# 每 FID 独立跑一份 visited-state 预算 (200k), 避免多 FID 共享预算
# 导致深部分支被截断。
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

FID_MAP = { 0 => 0x7E, 1 => 0x7F, 2 => 0x80, 3 => 0x81 }

# ---------------------------------------------------------
# Direct entry: monkey-patch skip c4[0x95]=0, iterate c4[0x95]
# ---------------------------------------------------------
def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup

  # Monkey-patch: skip c4[0x95]=0 at 0x03B5 (F9=10 handler init)
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.index == 0x03B5 && cmd.code == 0x0001 && cmd.params[0] == 2 && cmd.params[1] == 0x95
      state.pc += 1
      return true
    end
    old_dispatch.call(state, cmd, cmds)
  end

  fid = FID_MAP[c4_95_value]

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
  state.dialog_file_id = fid

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Direct entry: c4[0x95]=#{c4_95_value} → FID 0x#{sprintf('%02X', fid)}"
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

(0..3).each do |val|
  puts "\n=== Run: c4[0x95]=#{val} (FID 0x#{sprintf('%02X', FID_MAP[val])}) ==="
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
output_results(all_dialogs, commands, "output_full/script33")

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
