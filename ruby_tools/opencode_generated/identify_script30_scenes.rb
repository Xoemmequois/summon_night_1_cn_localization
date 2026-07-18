# ============================================================
# identify_script30_scenes — 完整提取 script30 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x0411 (sub 0x03D3) —
#   case 0 → 0x03D5: SET_FID 0x74 (主线剧情)
#   case 1 → 0x03F1: SET_FID 0x75 (决战胜利, 22 条)
#   case 2 → 0x0401: SET_FID 0x76 (结局旁白, 844 条)
# 链条: c4[0x95]=1 仅在 0x046E 写入, 由 c4[0x21]==1 守卫
# (0x0005@0x0465, F9=7 handler 0x0456 内)。c4[0x21] 是跨脚本全局
# 旗标, script30 内无写入点 (由引擎/其他脚本设置) → 加入
# external_vars 在比较处 fork。
# FID75 场景 handler 0x0CD1 开头 (0x0CD5) 设 c4[0x95]=2 并重新调用
# 0x03D3 → 顺序衔接 FID 0x76。
# 结局旁白分页: F9=5 handler 0x03BB 在 c4[0x95]==2 时 call 0x2070
# → switch c4[0xC7] at 0x243F 共 25 页 (0x2075..0x2412)。唯一写入
# 是 0x0011 c4[0xC7]=c4[0x19] (拷贝, external fork 对拷贝无效) →
# 把 0xC7 加入 external_vars fork 全部分页。
# TEXT 0x3B/0x3C 由 c8[0x64]!=0 / c8[0x65]!=0 守卫 (0x0003@0x0FE6/
# 0x0FEF, mode=4 引擎旗标, 脚本内无写入) → 预置 c8[0x64]=c8[0x65]=1
# (与 script26 相同处理)。
# TEXT 0x2EA-0x2F1 (8 条) 为死文本: 全脚本无任何 0x2013 引用。
# 注意不要把 0x95 设为 external: handle_0027 的 fork 不固化 case 值,
# 会导致 FID 间完全 crossover。
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 30
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# ---------------------------------------------------------
# Run analysis with 0x21/0xC7 external + c8[0x64]/[0x65] preset
# ---------------------------------------------------------
def run_script30(commands, script_id)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: default + 0x21 (全局事件旗标 → FID75/76 分支)
  #                       + 0xC7 (结局旁白页计数 → fork 25 页)
  # do NOT add 0x95 — let the FID dispatch switch route naturally
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0x21, 0xC7]

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
  # c8[0x64]/c8[0x65] gates at 0x0FE6/0x0FEF guard TEXT 0x3B/0x3C for FID 0x76
  state.tbl_c8[0x64] = 1
  state.tbl_c8[0x65] = 1

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running with external_vars + [0x21, 0xC7], c8[0x64]=c8[0x65]=1..."
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

dialogs = run_script30(commands, SCRIPT_ID)
dialogs.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script30")

# Summary of FID coverage
puts
[0x74, 0x75, 0x76].each do |fid|
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
puts "  (FID 0x76 中 TEXT 0x2EA-0x2F1 共 8 条为死文本, 无任何 0x2013 引用)"
