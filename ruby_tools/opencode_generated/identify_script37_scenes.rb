# ============================================================
# identify_script37_scenes — 完整提取 script37 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x04B3 —
#   case 0 → 0x044C: SET_FID 0x87 (初阵对话)
#   case 1 → 0x046B: SET_FID 0x88 (主线剧情, 15角色 routes)
#   case 2 → 0x047B: SET_FID 0x89
#   case 3 → 0x048B: SET_FID 0x8A
#   case 4 → 0x049B: SET_FID 0x8B
#   cases 5-8 → STUB (goto return, no FID)
# Entry: 0x03B5 块 CLEAR c4[0x95] → call 0x043E → switch 0x04B3
# Monkey-patch: skip CLEAR at 0x03B5, iterate c4[0x95]=0..4
# c4[0x95] NOT added to external_vars (避免 handle_0027 不固化 case
# 导致 crossover)。c4[0x1B] 已在 EXTERNAL_VARS 中, 自动 fork 角色路由。
# FID 0x88: Monkey-patch fork regA=1 at 0x10A2 — 攻克 RPN gate
#   (c4[0x9A]==c4[0x14] + c4[0xDC]<0x6C, opcode 0x80/0x89 不透明)
#   → 解锁 sub 0x16B6 内 TEXT 0xE5-0xFC (24条), 达成 449/449 (100%)。
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 37
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

FID_MAP = { 0 => 0x87, 1 => 0x88, 2 => 0x89, 3 => 0x8A, 4 => 0x8B }

# ---------------------------------------------------------
# Run VM with monkey-patched c4[0x95] value
# ---------------------------------------------------------
def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # external_vars: default only — c4[0x1B] already in EXTERNAL_VARS for char routing
  # do NOT add 0x95 — let the FID dispatch switch route naturally
  manager.external_vars = VMState::EXTERNAL_VARS.dup

  # Monkey-patches:
  #   1) skip CLEAR c4[0x95] at 0x03B5 (F9=0xA handler entry)
  #   2) fork regA=1 at 0x10A2 JMP_IF_A gate —
  #      unhandled 0x000A RPN chain: c4[0x9A]==c4[0x14] (0x80) +
  #      c4[0xDC] < 0x6C (0x89). VM handle_000A 仅处理性别模式,
  #      0x80/0x89 不透传导致 regA=0 → 0x0020 永不跳转 →
  #      sub 0x16B6 (TEXT 0xE5-0xFC) 永远不到达。
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.code == 0x0001 && cmd.index == 0x03B5 && cmd.params[0] == 2 && cmd.params[1] == 0x95
      state.pc += 1
      return true
    end
    if cmd.code == 0x0020 && cmd.index == 0x10A2
      fork_state = state.clone
      fork_state.regA = 1
      t = index_to_pc[cmd.params[0]]
      if t
        fork_state.pc = t
        push(fork_state)
      end
      state.regA = 0
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

# ---------------------------------------------------------
# Main: iterate all c4[0x95] values 0..4
# ---------------------------------------------------------

all_dialogs = {}

(0..4).each do |val|
  puts "\n=== Run: c4[0x95]=#{val} ==="
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
output_results(all_dialogs, commands, "output_full/script37")

# Summary of FID coverage
puts
[0x87, 0x88, 0x89, 0x8A, 0x8B].each do |fid|
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
