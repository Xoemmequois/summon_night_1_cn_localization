# ============================================================
# identify_script36_scenes — 完整提取 script36 (终章) 所有 FID 场景对话
# ============================================================
# FID dispatch at 0x03E3: only FID 0x86 (终章收尾)
#
# 缺失文本分析 (原 batch_analyze 仅得 1183/1275):
#
# 1. 角色名 0x004F-0x0051 (斯旺/艾尔卡/希昂)
#    — c8[0x64/0x65/0x66] gates at idx 946/950/954, 与 script35 相同模式。
#    修复: tbl_c8[0x64/0x65/0x66]=1
#
# 2. 性别差异主角台词 0x045A-0x04B7 (90条)
#    — 入口链: F8=3, F9=0xA → F9=5 → 0x03BB → 0x24C1 → goto 0x28EC
#      → switch c4[0xC7] (27 cases) → case N → gender switch c4[0x1D]
#      → 4路分支各自产生不同台词。
#    c4[0xC7] 跨脚本场景段旗标,不在 EXTERNAL_VARS 默认列表,
#    且 switch handler 在内部 0x24C1 sub 中,普通执行走不到。
#    修复: 添加 0xC7 到 external_vars,VM 在 0x28EC 处分叉全 27 路。
#    (27×4=108 并发状态,实测 2000 步内收敛,200k 预算充足)
#
# 3. 1 crossover (TEXT 0x000B) — 对话文件内看似非空,实际与已提取
#    文本重复,属于源数据边界 case,忽略。
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 36
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# ---------------------------------------------------------
# Run analysis with c4[0xC7] external + c8 gates
# ---------------------------------------------------------
def run_script36(commands, script_id)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: default + 0xC7 (0x28EC switch, 27-case text segment dispatch)
  # 0x1D is already in default external_vars — handles gender forks
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

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

  # Gate-opening: c8 flags for character names + Gibson branches
  state.tbl_c8[0x64] = 1
  state.tbl_c8[0x65] = 1
  state.tbl_c8[0x66] = 1

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running with external_vars + [0xC7]..."
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

dialogs = run_script36(commands, SCRIPT_ID)
dialogs.each do |fid, groups|
  all_dialogs[fid] ||= Set.new
  all_dialogs[fid] += groups
end

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script36")

# Summary of FID coverage
puts
[0x86].each do |fid|
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
