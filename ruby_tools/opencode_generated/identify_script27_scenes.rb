# ============================================================
# identify_script27_scenes — 完整提取 script27 所有 FID 场景对话
# ============================================================
# ALL var[0x95] switches in script27 use case_base=1, but the stock
# handle_0027 ignores params[2]. This affects both FID dispatch
# (0x0415) AND F9-handler internal routing switches.
# Monkey-patch fixes ALL var[0x95] switches while leaving entry
# routing (F8/F9/FA) alone (they work with F8=3/F9=0xA by accident).
#
# All writes to c4[0x95] are skipped for clean per-value iteration.
#
# FID dispatch (0x0415): case 1→0x68, 2→0x69, 3→0x6A, 4→0x6B
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 27
FN = "../../exported/CM1100.DAT_#{SCRIPT_ID}"

unless File.exist?(FN)
  puts "File not found: #{FN}"
  exit 1
end

commands = parse_commands(FN).to_a
puts "Loaded #{commands.size} commands from #{FN}"

# Collect all addresses of var[0x95] switches (case_base != 0)
VAR95_SWITCHES = commands.select { |c|
  c.code == 0x0027 && c.params[1] == 0x95 && c.params[2] != 0
}.map(&:index).to_set
puts "  var[0x95] switches with case_base=1: #{VAR95_SWITCHES.size} instances"

def run_with_c4_95(commands, script_id, c4_95_value, var95_switches, start_offset = 0x012E, dialog_file_id = nil, external_vars = VMState::EXTERNAL_VARS, initial_c4 = {}, end_offset = nil)
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = external_vars.dup

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Direct-entry analysis stops after its final dialogue flush.
    return false if end_offset && cmd.index == end_offset

    # Fix case_base for ALL var[0x95] switches
    if cmd.code == 0x0027 && var95_switches.include?(cmd.index)
      mode = cmd.params[0]
      var_id = cmd.params[1]
      case_base = cmd.params[2]
      case_val = (mode == 4) ? state.read_c8(var_id) : state.read_c4(var_id)
      idx = case_val - case_base
      if idx >= 0 && (4 + idx) < cmd.params.size - 1
        target = cmd.params[4 + idx]
        if target && target != 0
          t = self.index_to_pc[target]
          if t
            state.pc = t
            return true
          end
        end
      end
      state.pc += 1
      return true
    end

    # Skip ALL writes to c4[0x95] — keep our iterated value
    if cmd.code == 0x0010 && cmd.params[0] == 0x95
      state.pc += 1
      return true
    end

    old_dispatch.call(state, cmd, cmds)
  end

  init_state = VMState.new(script_id)
  init_state.tbl_c4[0xF8] = 3
  init_state.tbl_c4[0xF9] = 0xA
  init_state.tbl_c4[0xFA] = 0x0D
  init_state.tbl_c4[0xFB] = 0
  init_state.tbl_c4[0xFC] = 0
  init_state.tbl_c4[0xC4] = 4
  init_state.tbl_c4[0xC3] = 4
  init_state.tbl_c4[0x95] = c4_95_value
  init_state.tbl_c4[0x93] = 0
  initial_c4.each { |var_id, value| init_state.tbl_c4[var_id] = value }
  init_state.dialog_file_id = dialog_file_id unless dialog_file_id.nil?

  idx = manager.index_to_pc[start_offset]
  init_state.pc = idx || 127
  manager.push(init_state)

  puts "Running with c4[0x95]=#{c4_95_value}..."
  run_manager(manager, commands, script_id)

  fid_list = manager.dialogs.keys.sort.map { |f| sprintf("0x%02X", f) }
  puts "  Found FIDs: #{fid_list.join(', ')}"
  manager.dialogs
end

all_dialogs = {}

[1, 2, 3, 4].each do |val|
  puts "\n=== Run c4[0x95]=#{val} ==="
  dialogs = run_with_c4_95(commands, SCRIPT_ID, val, VAR95_SWITCHES)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

# FID 68's selection path only assigns the FID then returns.  Its dialogue
# bodies are entered later at 0x08AB, 0x0991, and 0x09FC, so analyze each directly.
[0x08AB, 0x0991, 0x09FC].each do |entry_offset|
  (0..3).each do |choice|
    puts "\n=== Direct FID 0x68 at 0x#{sprintf('%04X', entry_offset)}, c4[0x1D]=#{choice} ==="
    dialogs = run_with_c4_95(
      commands, SCRIPT_ID, 1, VAR95_SWITCHES, entry_offset, 0x68,
      VMState::EXTERNAL_VARS - [0x1D], { 0x1D => choice },
      entry_offset == 0x09FC ? 0x0A1E : nil
    )
    dialogs.each do |fid, groups|
      all_dialogs[fid] ||= Set.new
      all_dialogs[fid] += groups
    end
  end
end


#关于 FID 68的说明：
#script27 中可能真的没有 FID68，FID68的1E和1F应该是同一句话，但是在代码中找不到连续的2013 001E 和 2013 001F的组合。
#这里我们直接使用GPT生成的FID68的组合
# FID 68 stores several complete sentences as consecutive text indices even
# though script27 reaches their pieces through the same branches used by FID 69.
FID68_SEMANTIC_GROUPS = [
  [0x01, 0x02, 0x03], [0x04, 0x05], [0x06, 0x07], [0x08, 0x09, 0x0A],
  [0x0B, 0x0C], [0x0D, 0x0E], [0x0F, 0x10], [0x11, 0x12, 0x13],
  [0x14, 0x15], [0x16], [0x17, 0x18], [0x19, 0x1A, 0x1B], [0x1C],
  [0x1D, 0x1E, 0x1F], [0x20, 0x21, 0x22, 0x23], [0x24], [0x25],
  [0x26], [0x27], [0x28], [0x29], [0x2A, 0x2B], [0x2C, 0x2D],
  [0x2E, 0x2F], [0x30, 0x31], [0x32], [0x33], [0x34, 0x35]
].freeze

if (fid68_groups = all_dialogs[0x68])
  all_dialogs[0x68] = FID68_SEMANTIC_GROUPS.map do |texts|
    source = fid68_groups.find { |group| group[:texts].include?(texts.first) } || {}
    source.merge(texts: texts)
  end.to_set
end

puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script27")

puts
(0x68..0x6B).each do |fid|
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
