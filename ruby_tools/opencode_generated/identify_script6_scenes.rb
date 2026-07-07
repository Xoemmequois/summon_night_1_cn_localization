require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

# ============================================================
# Script 06 场景识别器 (v2 - per-FID dedicated runs)
# ============================================================
# Script06: FID mapping from c4[0x95] values at switch idx 479:
#   3->0x19, 4->0x1A, 5->0x1B, 6->0x1C, 7->0x1D, 8->0x1E
#
# Issue: 0x002E @ idx 377 sets FID=-1 in VM, then 0x4B8 dispatch
# plays dialogs under FID=-1. The switch @ idx 479 sets FID AFTER
# dialogs are done, so all dialogs bleed into every FID.
#
# Fix: monkey-patch 0x002E at offset 0x3A6 to set FID from c4[0x95].
# Run each c4[0x95] value separately with dedicated FID.
# ============================================================

SID = 6
OUT_DIR = File.join(__dir__, "output_full")
Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)

FID_MAP = { 3 => 0x19, 4 => 0x1A, 5 => 0x1B, 6 => 0x1C, 7 => 0x1D, 8 => 0x1E }
C4_95_VALUES = [3, 4, 5, 6, 7, 8]

def analyze(target_id, init_95)
  fn = "../../exported/CM1100.DAT_#{target_id}"
  raise "missing #{fn}" unless File.exist?(fn)
  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup + [0x99]

  # Monkey-patch:
  # 1. Skip c4[0x95]=3 at idx 386 -> keep our initial value
  # 2. 0x002E at offset 0x3A6 -> set FID from c4[0x95]
  # 3. 0x000A at 0x25FD -> (c4[0x99]==2) OR (c4[0x99]==3), fork regA=1/0
  old_dispatch = manager.method(:dispatch)
  manager.define_singleton_method(:dispatch) do |state, cmd, cmds|
    # Skip hardcoded c4[0x95]=3 at idx 386 (offset 0x3B5)
    if cmd.code == 0x0010 && cmd.index == 0x3B5 && cmd.params[0] == 0x95
      state.pc += 1
      return true
    end
    # 0x002E at offset 0x3A6 -> set FID from c4[0x95]
    if cmd.code == 0x002E && cmd.index == 0x3A6
      c95 = state.read_c4(0x95)
      fid = FID_MAP[c95] || 0x19
      state.dialog_file_id = fid
    end
    # 0x000A at 0x25FD: (c4[0x99]==2) OR (c4[0x99]==3) -> regA
    # regA=1 -> 0x260E call 0x26C3 (TEXT:12-15 male companion path)
    # regA=0 -> 0x2610 goto -> c4[0x95]=8 -> FID 0x1E transition
    if cmd.code == 0x000A && cmd.index == 0x25FD
      f = state.clone
      f.regA = 1    # male companion path: 0x0020 jumps to call 0x26C3
      f.pc = state.pc + 1
      manager.push(f)
      state.regA = 0  # female companion path: falls through
      state.pc += 1
      return true
    end
    old_dispatch.call(state, cmd, cmds)
  end

  state = VMState.new(target_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = init_95

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)
  run_manager(manager, commands, target_id)
  manager.dialogs
end

def analyze_sub(target_id, entry_offset, dialog_fid, extra_vars)
  fn = "../../exported/CM1100.DAT_#{target_id}"
  return {} unless File.exist?(fn)
  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup + extra_vars

  state = VMState.new(target_id)
  state.dialog_file_id = dialog_fid
  idx = manager.index_to_pc[entry_offset]
  return {} unless idx
  state.pc = idx
  manager.push(state)
  run_manager(manager, commands, target_id)
  manager.dialogs
end

def merge_dialogs(all_results)
  merged = {}
  all_results.each do |dialogs|
    dialogs.each do |fid, groups|
      merged[fid] ||= Set.new
      groups.each { |g| merged[fid].add(g) }
    end
  end
  merged
end

def write_fid(sid, fid, groups)
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  return false unless File.exist?(dialog_fn)
  contents = IO.binread(dialog_fn)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  groups = groups.to_a.sort_by { |g| g[:texts].first || 0 }

  File.open("#{OUT_DIR}/script#{sprintf('%02d', sid)}_fid#{sprintf('%02X', fid)}.txt", "w") do |f|
    group_no = 0
    groups.each do |g|
      group_no += 1
      left  = g[:left_face]  || -1
      right = g[:right_face] || -1
      side  = g[:speaker_side] || 0
      speaker_id = side == 0 ? left : right
      speaker_str = speaker_id >= 0 ? sprintf('char_%04X', speaker_id) : 'none'
      side_str = side == 0 ? 'left' : 'right'
      nc = g[:next_cmd] || 0
      f.puts "--- Group #{group_no} [#{side_str}:#{speaker_str} next=#{sprintf('%04X', nc)}] ---"
      g[:texts].each do |ti|
        next if ti >= indices.size
        s = indices[ti]
        str = ""; p = 0
        loop do
          break if contents[s * 2 + p] == "\x0" && contents[s * 2 + p + 1] == "\x0"
          str += contents[s * 2 + p] + contents[s * 2 + p + 1]
          p += 2
          break if p > 200
        end
        begin
          str = str.force_encoding("shift_jis").encode("utf-8")
        rescue
          str = "(encoding error)"
        end
        f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', ti)}] #{str}"
      end
      f.puts ""
    end
  end
  true
end

puts "Script 06: per-FID runs with 0x002E monkey-patch (c4[0x95] -> FID)"
puts "  #{FID_MAP.map { |k, v| "#{k}->0x#{v.to_s(16).upcase}" }.join(', ')}"
puts

all_results = []
C4_95_VALUES.each do |val|
  fid = FID_MAP[val]
  $stderr.puts "  c4[0x95]=#{val} -> FID=0x#{fid.to_s(16).upcase}..."
  dialogs = analyze(SID, val)
  fids = dialogs.keys.sort
  $stderr.puts "    fids: #{fids.map{|x| sprintf('%02X',x)}.join(', ')} (#{dialogs.values.sum{|g| g.size}} groups)"
  all_results << dialogs
end

# Direct entry to sub 0x3449 for FID=0x1E hidden texts
sub_dialogs = analyze_sub(SID, 0x3449, 0x1E, [0x99, 0xC7])
$stderr.puts "  sub 0x3449 (FID=0x1E): #{(sub_dialogs[0x1E]||[]).size} groups"
all_results << sub_dialogs

dialogs = merge_dialogs(all_results)
fids = dialogs.keys.sort
puts
puts "FIDs found: #{fids.map{|x| sprintf('%02X', x)}.join(', ')}"

fids.each do |fid|
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  total = 0
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    len = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{len}")
    non_empty = (0...len).count do |ti|
      next false if ti >= indices.size
      s = indices[ti]
      str = ""; pp = 0
      loop do
        break if contents[s * 2 + pp] == "\x0" && contents[s * 2 + pp + 1] == "\x0"
        str += contents[s * 2 + pp] + contents[s * 2 + pp + 1]
        pp += 2
        break if pp > 200
      end
      !str.strip.empty?
    end
    txts = dialogs[fid].flat_map { |g| g[:texts] }.uniq.size
    pct = non_empty > 0 ? (txts.to_f / non_empty * 100).round(1) : 0
    puts "  FID #{sprintf('%02X', fid)}: #{txts}/#{non_empty} (#{pct}%) #{dialogs[fid].size} groups"
  end
end

written = []
fids.each { |fid| written << fid if write_fid(SID, fid, dialogs[fid]) }
puts "Wrote: #{written.map{|x| sprintf('%02X', x)}.join(', ')} -> #{OUT_DIR}/"
