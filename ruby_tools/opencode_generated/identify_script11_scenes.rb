# ============================================================
# identify_script11_scenes — 完整提取 script11 所有 FID 场景对话
# ============================================================
# FIDs 0x2A-0x2B: 默认路径 (c4[0x95]=2→3)
# FIDs 0x2C-0x2E: monkey-patch 跳过 c4[0x95]=2 + 遍历 c4[0x95]=4,5,6
# FID 0x2D TEXT 18-29: fork JMP_IF_A 0x161D (c4[0xA2]<2 RPN 不处理)
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 11
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Skip c4[0x95]=2 hardcode at 0x03B5 (F9=0xA handler)
    if cmd.code == 0x0010 && cmd.index == 0x03B5 && cmd.params[0] == 0x95
      state.pc += 1
      return true
    end
    # 0x000A RPN at 0x1616 checks c4[0xA2] < 2 — not handled by handle_000A.
    # Fork both regA=0 and regA=1 at JMP_IF_A 0x161D to reach switch var[0x99]
    if cmd.index == 0x161D && cmd.code == 0x0020
      fork_state = state.clone
      fork_state.regA = 1
      fork_state.pc = index_to_pc[cmd.params[0]]
      push(fork_state)
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

  puts "Running with c4[0x95]=#{c4_95_value}..."
  run_manager(manager, commands, script_id)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  group_counts = manager.dialogs.map { |fid, groups| "0x#{sprintf('%02X',fid)}(#{groups.size})" }
  puts "  Groups: #{group_counts.join(', ')}"

  manager.dialogs
end

all_dialogs = {}

[2, 4, 5, 6].each do |val|
  puts "\n=== Run c4[0x95]=#{val} ==="
  run_with_c4_95(commands, SCRIPT_ID, val).each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script11")

puts
(0x2A..0x2E).each do |fid|
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
