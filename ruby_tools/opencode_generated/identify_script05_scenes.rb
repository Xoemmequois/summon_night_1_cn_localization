require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

SCRIPT_ID = 5
TARGET_FID = 0x18
OUT_DIR = File.join(__dir__, "output_full")
Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)

# ============================================================
# Extended external vars that unlock hidden scenes in script 05
#  0x9D -> bread scene  (test at idx 3757)
#  0xA1 -> candy scene  (test at idx 3772)
#  0x22 -> fishing scene (switch at idx 4511 in sub 0x2ADD)
# ============================================================
EXTRA_EXTERNAL = [0x9D, 0xA1, 0x22]

def analyze_script05_fid18(extra_external)
  fn = "../../exported/CM1100.DAT_#{SCRIPT_ID}"
  return {} unless File.exist?(fn)

  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup + extra_external

  state = VMState.new(SCRIPT_ID)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = 2 # force FID=0x18 path

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)
  run_manager(manager, commands, SCRIPT_ID)
  manager.dialogs
end

def load_dialog_strings(fid)
  fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  return {} unless File.exist?(fn)

  contents = IO.binread(fn)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")

  strs = {}
  (0...len).each do |ti|
    next if ti >= indices.size
    s = indices[ti]
    str = ""
    p = 0
    loop do
      break if contents[s * 2 + p] == "\x0" && contents[s * 2 + p + 1] == "\x0"
      str += contents[s * 2 + p] + contents[s * 2 + p + 1]
      p += 2
      break if p > 200
    end
    next if str.strip.empty?
    begin
      strs[ti] = str.force_encoding("shift_jis").encode("utf-8")
    rescue
      strs[ti] = "(encoding error)"
    end
  end
  strs
end

# ============================================================
# Run: baseline (no extra) vs extended (with forks)
# ============================================================

puts "=" * 70
puts "Script 05 FID=0x18: scene extraction with extended forks"
puts "=" * 70

baseline = analyze_script05_fid18([])
extended = analyze_script05_fid18(EXTRA_EXTERNAL)

all_strings = load_dialog_strings(TARGET_FID)
baseline_texts = (baseline[TARGET_FID] || []).flat_map { |g| g[:texts] }.uniq.to_set
extended_texts = (extended[TARGET_FID] || []).flat_map { |g| g[:texts] }.uniq.to_set
new_texts = (extended_texts - baseline_texts).sort

puts "Baseline (no forks): #{baseline_texts.size} texts"
puts "Extended (+#{EXTRA_EXTERNAL.map { |v| "0x#{v.to_s(16).upcase}" }.join(', ')}): #{extended_texts.size} texts"
puts "Newly discovered: #{new_texts.size}"
puts

# ============================================================
# Write full dialog output for FID=0x18
# ============================================================

groups = extended[TARGET_FID]
if groups
  groups = groups.to_a.sort_by { |g| g[:texts].first || 0 }
  out_fn = File.join(OUT_DIR, "script05_fid18.txt")

  File.open(out_fn, "w") do |f|
    group_no = 0
    groups.each do |g|
      group_no += 1
      left = g[:left_face] || -1
      right = g[:right_face] || -1
      side = g[:speaker_side] || 0
      speaker_id = side == 0 ? left : right
      speaker_str = speaker_id >= 0 ? sprintf("char_%04X", speaker_id) : "none"
      side_str = side == 0 ? "left" : "right"
      nc = g[:next_cmd] || 0
      f.puts "--- Group #{group_no} [#{side_str}:#{speaker_str} next=#{sprintf('%04X', nc)}] ---"

      g[:texts].each do |ti|
        str = all_strings[ti]
        next unless str
        f.puts "[FID:#{sprintf('%02X', TARGET_FID)}, TEXT:#{sprintf('%04X', ti)}] #{str}"
      end
      f.puts ""
    end
  end

  puts "Output: #{out_fn}"
  puts "  #{groups.size} dialog groups, #{extended_texts.size} unique texts"
end

# ============================================================
# Coverage summary for all FIDs touched by script 05
# ============================================================
puts
puts "=" * 70
puts "Script 05 coverage (all FIDs)"
puts "=" * 70

extended.each do |fid, grps|
  txts = grps.flat_map { |g| g[:texts] }.uniq
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  total = 0
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    len = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{len}")
    total = (0...len).count { |ti| ti < indices.size && !indices[ti].nil? }
    non_empty = (0...len).count do |ti|
      next false if ti >= indices.size
      s = indices[ti]
      str = ""
      pp = 0
      loop do
        break if contents[s * 2 + pp] == "\x0" && contents[s * 2 + pp + 1] == "\x0"
        str += contents[s * 2 + pp] + contents[s * 2 + pp + 1]
        pp += 2
        break if pp > 200
      end
      !str.strip.empty?
    end
    pct = non_empty > 0 ? (txts.size.to_f / non_empty * 100).round(1) : 0
    marker = (fid == TARGET_FID) ? " <== TARGET" : ""
    puts "  FID 0x#{fid.to_s(16).upcase.rjust(2, '0')}: #{txts.size}/#{non_empty} (#{pct}%) #{grps.size} groups#{marker}"
  end
end

puts
puts "Done."
