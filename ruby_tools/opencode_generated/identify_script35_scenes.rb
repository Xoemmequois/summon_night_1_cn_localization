# ============================================================
# identify_script35_scenes — 完整提取 script35 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x03EB —
#   case 2 → 0x03C9: SET_FID 0x84 (默认剧情)
#   case 3 → 0x03D9: SET_FID 0x85 (后续剧情: 格拉姆斯放行)
# c4[0x95]=2 硬编码在 0x03B5 (F9=1 handler 内)。
# c4[0x95]=3 仅在 0x045A 写入, 由 c4[0x21]==1 守卫 (0x0005@0x0451 +
# 0x0021@0x0456, 状态机 F9=4 handler 0x0436 内, 通过 switch c4[0x95]
# at 0x0474 case 2→0x0443 到达)。
# c4[0x21] 是跨脚本全局旗标: script35 内唯一写入点位于孤儿子程序
# 0x049D (引擎回调, 脚本内零引用), 故 VM 从 0x012E 起跑永远走不到
# c4[0x21]=1 → 只提取 FID 0x84。
# 修复: 把 0x21 加入 external_vars — 在 0x0005 比较处 fork 两侧,
# regB=1 分支设 c4[0x95]=3 → F9=8 → 0x0274 路径 → 0x03C3 → FID 0x85。
# 注意不要把 0x95 设为 external: handle_0027 的 fork 不固化 case 值,
# 会导致两个 FID 各得相同的文本 (完全 crossover)。
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 35
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
def run_script35(commands, script_id)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: default + 0x21 (全局事件旗标, 控制 FID 0x85 分支)
  # do NOT add 0x95 — let the FID dispatch switch route naturally
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0x21]

  # Initialize state (matching analyze_script_static)
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

dialogs = run_script35(commands, SCRIPT_ID)
dialogs.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script35")

# Summary of FID coverage
puts
[0x84, 0x85].each do |fid|
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
