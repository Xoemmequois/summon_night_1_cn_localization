# ============================================================
# identify_script22_scenes — 完整提取 script22 所有 FID 场景对话
# ============================================================
# FID dispatch: switch var[0x95] at 0x04C4 — 8 cases
#   case 0=0x045F→FID 0x56, case 1=0x047B→FID 0x57,
#   case 2=0x048E→FID 0x58, case 3=0x049E→FID 0x59,
#   case 4=0x04AE→FID 0x5A
# Monkey-patch 跳过 c4[0x95]=0 清零 (0x0001 at 0x03B5) + 遍历 c4[0x95]=0~4
# 0xC7 加入 external_vars 解决 0x34AA 处的内部剧情 switch forking
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 22
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# ---------------------------------------------------------
# Run analysis with monkey-patched c4[0x95] value
# ---------------------------------------------------------
def run_with_c4_95(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

  # Monkey-patch: skip c4[0x95] clear (0x0001, var is params[1]) or set (0x0010, var is params[0]) at 0x03B5
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if cmd.index == 0x03B5
      if (cmd.code == 0x0010 && cmd.params[0] == 0x95) ||
         (cmd.code == 0x0001 && cmd.params[1] == 0x95)
        state.pc += 1
        return true
      end
    end
    old_dispatch.call(state, cmd, cmds)
  end

  # Initialize state
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

# ---------------------------------------------------------
# Main: iterate c4[0x95]=0,1,2,3,4 for FIDs 0x56-0x5A
# ---------------------------------------------------------

all_dialogs = {}

[0, 1, 2, 3, 4].each do |val|
  fid = 0x56 + val
  puts "\n=== Run c4[0x95]=#{val} (targeting FID 0x#{sprintf('%02X', fid)}) ==="
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
output_results(all_dialogs, commands, "output_full/script22")

puts
(0x56..0x5A).each do |fid|
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
