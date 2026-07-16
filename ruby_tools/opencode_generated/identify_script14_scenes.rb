# ============================================================
# identify_script14_scenes — 完整提取 script14 所有 FID 场景对话
# ============================================================
# FID dispatch at 0x05C0: c4[0x95]=0→0x38, 1→0x39, 2→0x3A, 3→0x3B
# Just iterate c4[0x95] values; no monkey-patch needed.
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 14
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

def run_script14(commands, script_id, c4_95_value)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup

  # Monkey-patch: skip CLEAR c4[0x95] at 0x03B5 (F9=10 handler entry)
  # and SET c4[0x95]=N writes that would override our target value
  skip_writes = [0x03B5, 0x0AC3, 0x0AF5, 0x0FAA]
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    if skip_writes.include?(cmd.index)
      if cmd.code == 0x0001 && cmd.params[0] == 2 && cmd.params[1] == 0x95
        # CLEAR c4[0x95]
        state.pc += 1
        return true
      elsif cmd.code == 0x0010 && cmd.params[0] == 0x95
        # SET c4[0x95]=N
        state.pc += 1
        return true
      end
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

(0..3).each do |val|
  puts "\n=== Run: c4[0x95]=#{val} ==="
  dialogs = run_script14(commands, SCRIPT_ID, val)
  dialogs.each { |fid, groups| (all_dialogs[fid] ||= Set.new).merge(groups) }
end

puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script14")

puts
[0x38, 0x39, 0x3A, 0x3B].each do |fid|
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
