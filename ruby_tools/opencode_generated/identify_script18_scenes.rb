# ============================================================
# identify_script18_scenes — 完整提取 script18 所有 FID 场景对话
# ============================================================
# FIDs 0x46-0x47: 默认路径 (c4[0x95]=2→3)
# FIDs 0x48-0x49: monkey-patch 跳过 c4[0x95]=2 写入 + 遍历 c4[0x95]=4,5
# FID dispatch: switch var[0x95] at offset 0x0498
#   case 2→0x46, case 3→0x47, case 4→0x48, case 5→0x49
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 18
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
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]

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

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |s, cmd, cmds|
    if cmd.code == 0x0010 && cmd.index == 0x03B5 && cmd.params[0] == 0x95
      s.pc += 1
      return true
    end
    old_dispatch.call(s, cmd, cmds)
  end

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

# Main
all_dialogs = {}

# Run 1: default (c4[0x95]=2 from 0x03B5, no monkey) for high-coverage FIDs 0x46-0x47
puts "\n=== Run 1: Default (c4[0x95] init via 0x03B5) ==="
m1 = ExecManager.new
m1.index_to_pc = {}
commands.each_with_index { |c, i| m1.index_to_pc[c.index] = i }
m1.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]
s1 = VMState.new(SCRIPT_ID)
s1.tbl_c4[0xF8] = 3; s1.tbl_c4[0xF9] = 0xA; s1.tbl_c4[0xFA] = 0x0D
s1.tbl_c4[0xFB] = 0; s1.tbl_c4[0xFC] = 0; s1.tbl_c4[0xC4] = 4; s1.tbl_c4[0xC3] = 4
s1.tbl_c4[0x93] = 0
idx1 = m1.index_to_pc[0x012E]; s1.pc = idx1 || 127
m1.push(s1)
run_manager(m1, commands, SCRIPT_ID)
m1.dialogs.each { |fid, g| all_dialogs[fid] ||= Set.new; all_dialogs[fid] += g }
puts "  Default FIDs: #{m1.dialogs.keys.sort.map{|f| sprintf('0x%02X',f)}.join(',')}"

# Run 2: c4[0x95]=4 → FID 0x48
puts "\n=== Run 2: c4[0x95]=4 (FID 0x48) ==="
d2 = run_with_c4_95(commands, SCRIPT_ID, 4)
d2.each { |fid, g| all_dialogs[fid] ||= Set.new; all_dialogs[fid] += g }

# Run 3: c4[0x95]=5 → FID 0x49
puts "\n=== Run 3: c4[0x95]=5 (FID 0x49) ==="
d3 = run_with_c4_95(commands, SCRIPT_ID, 5)
d3.each { |fid, g| all_dialogs[fid] ||= Set.new; all_dialogs[fid] += g }

# Run 4: c4[0x95]=2 with monkey-patch for alternate paths
puts "\n=== Run 4: c4[0x95]=2 (monkey-patched) ==="
d4 = run_with_c4_95(commands, SCRIPT_ID, 2)
d4.each { |fid, g| all_dialogs[fid] ||= Set.new; all_dialogs[fid] += g }

# Output
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script18")

# Summary of FID coverage
puts
(0x46..0x49).each do |fid|
  sub_id = fid + 0x29
  dialog_fn = "../../exported/CM1100.DAT_#{sub_id}"
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    len = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{len}")
    non_empty = 0
    (0...len).each do |ti|
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
