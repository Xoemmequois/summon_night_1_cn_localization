# ============================================================
# identify_script13_scenes — 完整提取 script13 所有 FID 场景对话
# ============================================================
# FIDs 0x33-0x34: 默认路径 (c4[0x95]=4→5)
# FIDs 0x35-0x37: monkey-patch 跳过 c4[0x95]=4 写入 + 遍历 c4[0x95]=6
# FID  0x2F:     var[0xC8] 加入 external_vars (case 1 → FID 0x2F)
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 13
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# ---------------------------------------------------------
# Run analysis with optional monkey-patch for c4[0x95]
# ---------------------------------------------------------
def run_script13(commands, script_id, c4_95_value, skip_95_write, extra_vars = {})
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  # Add 0xC8 (for FID 0x2F dispatch at 0x03D4) and 0xC7 (for FID 0x37 routing at 0x39A2)
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7, 0xC8]

  # Monkey-patch: skip the c4[0x95]=4 write at 0x03B7 (var[0xC8] case 0)
  if skip_95_write
    old_dispatch = manager.method(:dispatch)
    manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
      if cmd.code == 0x0010 && cmd.index == 0x03B7 && cmd.params[0] == 0x95
        state.pc += 1
        return true
      end
      old_dispatch.call(state, cmd, cmds)
    end
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
  extra_vars.each { |k, v| state.tbl_c4[k] = v }

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  puts "Running with c4[0x95]=#{c4_95_value}#{skip_95_write ? ' (skip 0x03B7 write)' : ''}..."
  run_manager(manager, commands, script_id)

  # Report
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

# Run 1: default c4[0x95]=4 (no skip) → FIDs 0x33, 0x34, 0x2F
puts "\n=== Run 1: Default (c4[0x95]=4, no skip) ==="
dialogs1 = run_script13(commands, SCRIPT_ID, 4, false)
dialogs1.each { |fid, groups| (all_dialogs[fid] ||= Set.new).merge(groups) }

# Run 2: c4[0x95]=6 (skip write) → FIDs 0x35, 0x36, 0x37, 0x2F
puts "\n=== Run 2: c4[0x95]=6 (skip write, → 0x35,0x36,0x37) ==="
dialogs2 = run_script13(commands, SCRIPT_ID, 6, true)
dialogs2.each { |fid, groups| (all_dialogs[fid] ||= Set.new).merge(groups) }

# Run 3: c4[0x95]=7 (skip write) → remaining FID 0x36 paths
puts "\n=== Run 3: c4[0x95]=7 (skip write, → 0x36,0x37) ==="
dialogs3 = run_script13(commands, SCRIPT_ID, 7, true)
dialogs3.each { |fid, groups| (all_dialogs[fid] ||= Set.new).merge(groups) }

# Run 4: c4[0x95]=8 (skip write) → remaining FID 0x37 paths
puts "\n=== Run 4: c4[0x95]=8 (skip write, → 0x37) ==="
dialogs4 = run_script13(commands, SCRIPT_ID, 8, true)
dialogs4.each { |fid, groups| (all_dialogs[fid] ||= Set.new).merge(groups) }

# Run 5: Dedicated FID 0x2F run — c4[0xC8]=1, NO external_vars forking on 0xC8
puts "\n=== Run 5: Dedicated FID 0x2F (c4[0xC8]=1, no forking) ==="
manager5 = ExecManager.new
manager5.index_to_pc = {}
commands.each_with_index { |c, i| manager5.index_to_pc[c.index] = i }
# Only keep 0xC7 for FID 0x37, do NOT add 0xC8 (let the switch dispatch naturally)
manager5.external_vars = VMState::EXTERNAL_VARS.dup + [0xC7]
state5 = VMState.new(SCRIPT_ID)
state5.tbl_c4[0xF8] = 3
state5.tbl_c4[0xF9] = 0xA
state5.tbl_c4[0xFA] = 0x0D
state5.tbl_c4[0xFB] = 0
state5.tbl_c4[0xFC] = 0
state5.tbl_c4[0xC4] = 4
state5.tbl_c4[0xC3] = 4
state5.tbl_c4[0x95] = 0
state5.tbl_c4[0x93] = 0
state5.tbl_c4[0xC8] = 1  # Direct: case 1 → FID 0x2F
idx5 = manager5.index_to_pc[0x012E]
state5.pc = idx5 || 127
manager5.push(state5)
puts "Running dedicated FID 0x2F..."
run_manager(manager5, commands, SCRIPT_ID)
fid_list5 = manager5.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
puts "  Found FIDs: #{fid_list5.join(', ')}"
manager5.dialogs.each { |fid, groups| (all_dialogs[fid] ||= Set.new).merge(groups) }

# ---------------------------------------------------------
# Output
# ---------------------------------------------------------
puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script13")

# Summary of FID coverage
puts
fids = [0x2F, 0x33, 0x34, 0x35, 0x36, 0x37]
fids.each do |fid|
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
