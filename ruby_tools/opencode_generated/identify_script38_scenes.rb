# ============================================================
# identify_script38_scenes — 完整提取 script38 所有 FID 场景对话
# ============================================================
# FID dispatch: switch c4[0x95] at 0x048C —
#   case 0 → 0x03F9: SET_FID 0x8C (67 texts)
#   case 1 → 0x042C: SET_FID 0x8D (152 texts)
#   case 2 → 0x0461: SET_FID 0x8E (781 texts, 主线)
#   cases 3-4 → STUB
#
# Entry 1 (F9=0xA): 0x03B5 CLEAR c4[0x95]→call 0x03F7→switch 0x048C
#   c4[0x95]=0 → FID 0x8C
#
# Entry 2 (F9=4): c4[0x21]==1 guard at 0x0501→c4[0x95]=2→call 0x03F7
#   c4[0x95]=2 → FID 0x8E
#   c4[0x21] 是跨脚本全局旗标 (script38 内零写入, 孤儿 engine 调用)
#
# Entry 3 (F9=7 handler, off=0x0563): SET c4[0x95]=1 → call dispatch
#   c4[0x95]=1 → FID 0x8D
#
# 策略: 迭代 c4[0x95]=0,1,2, monkey-patch 跳过各入口的 CLEAR/SET.
# c4[0x21] 加入 external_vars 使 F9=4 handler 的 0x0005 fork.
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 38
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

FID_MAP = { 0 => 0x8C, 1 => 0x8D, 2 => 0x8E }

# ---------------------------------------------------------
def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # 0x21 for FID 0x8E gate (F9=4 handler); 0xC6 for internal char routing;
  # 0xE2 guards CALL 0x1B4A (sub containing 44 unclaimed 0x2013 for FID 0x8E)
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0x21, 0xC6, 0xE2]

  # Monkey-patches:
  # 1) skip CLEAR c4[0x95] at 0x03B5 (F9=0xA entry)
  # 2) skip SET c4[0x95]=1 at 0x0563
  # 3) skip SET c4[0x95]=2 at 0x050E
  # 4) fork at dead goto 0x1069: switch c4[0x99] 的所有 case handler 汇总到
  #    goto 0x1069→0x108D, 跳过了 0x106B 处的 c4[0xE2]==0 守卫和 CALL 0x1B4A.
  #    Fork: 保留 goto 跳转路径 + 强制 fall-through 到 0x106B.
  skip_95_writes = [0x03B5, 0x050E, 0x0563]
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if skip_95_writes.include?(cmd.index)
      if cmd.code == 0x0001 && cmd.params[0] == 2 && cmd.params[1] == 0x95
        state.pc += 1
        return true
      elsif cmd.code == 0x0010 && cmd.params[0] == 0x95
        state.pc += 1
        return true
      end
    end
    # Dead goto 0x1069: fork to also reach 0x106B → c4[0xE2] guard → CALL 0x1B4A
    if cmd.code == 0x0023 && cmd.index == 0x1069
      fork_state = state.clone
      t = index_to_pc[cmd.params[0]]
      if t
        fork_state.pc = t  # existing path: goto 0x108D
        push(fork_state)
      end
      state.pc += 1  # new path: fall through to 0x106B
      return true
    end
    # FID 0x8D c4[0xE1]==0x15 gate at 0x07C6: only reached when c4[0xE1]==0x15,
    # but c4[0xE1] defaults to 0 → 0x0021 never jumps → CALL 0x0E4F unreachable.
    # Fork regB bit0=1 at 0x07C6 to take the jump and reach sub 0x0E4F.
    if cmd.code == 0x0021 && cmd.index == 0x07C6
      fork_state = state.clone
      fork_state.regB = fork_state.regB | 1  # force regB bit0=1 → jump
      t = index_to_pc[cmd.params[0]]
      if t
        fork_state.pc = t
        push(fork_state)
      end
      state.regB = state.regB & 0xFE  # regB bit0=0 → fall through (existing)
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
all_dialogs = {}

(0..2).each do |val|
  puts "\n=== Run: c4[0x95]=#{val} ==="
  dialogs = run_with_c4_95(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script38")

puts
[0x8C, 0x8D, 0x8E].each do |fid|
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
