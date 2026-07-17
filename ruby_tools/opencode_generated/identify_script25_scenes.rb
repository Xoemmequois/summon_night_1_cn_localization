# ============================================================
# identify_script25_scenes — 完整提取 script25 所有 FID 场景对话
# ============================================================
# FID dispatch: switch var[0x95] at 0x990 — 8 cases
#   case 0→FID 0x62, case 1→FID 0x63, case 2→FID 0x64
# Monkey-patch: skip c4[0x95]=0 clear (0x0001 at 0x03C6/0x03D3)
#   + c4[0xCD], c4[0xB1] in external_vars for conditional guards
#   + fork JMP_IF_A at 0x3098 for unhandled RPN (c4[0x1D]>=3)
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

SCRIPT_ID = 25
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

  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0xCD, 0xB1]

  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Skip c4[0x95] clear at 0x03C6/0x03D3
    if (cmd.index == 0x03C6 || cmd.index == 0x03D3)
      if cmd.code == 0x0001 && cmd.params[1] == 0x95
        state.pc += 1; return true
      end
      if cmd.code == 0x0010 && cmd.params[0] == 0x95
        state.pc += 1; return true
      end
    end
    # Fork JMP_IF_A at 0x3098 (RPN c4[0x1D]>=3 at 0x3091 not handled by handle_000A)
    if cmd.index == 0x3098 && cmd.code == 0x0020
      fork_state = state.clone
      t = index_to_pc[cmd.params[0]]
      fork_state.regA = 1
      fork_state.pc = t if t
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
  manager.dialogs
end

all_dialogs = {}

[0, 1, 2].each do |val|
  puts "\n=== Run c4[0x95]=#{val} ==="
  dialogs = run_with_c4_95(commands, SCRIPT_ID, val)
  dialogs.each do |fid, groups|
    all_dialogs[fid] ||= Set.new
    all_dialogs[fid] += groups
  end
end

puts "\n=== Combined Results ==="
output_results(all_dialogs, commands, "output_full/script25")

puts
(0x62..0x64).each do |fid|
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
    ids = Set.new
    extracted&.each { |g| g[:texts].each { |t| ids.add(t) } }
    puts "  FID 0x#{sprintf('%02X', fid)}: #{ids.size}/#{non_empty}"
  end
end
