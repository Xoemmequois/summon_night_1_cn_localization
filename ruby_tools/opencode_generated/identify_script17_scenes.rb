# identify_script17_scenes.rb
# Identifies missing dialogue scenes in script 17 (CM1100.DAT_17),
# specifically the ramen scene blocked by c4[0xCA] guard at idx=1177.
#
# Root cause: handle_0005 compares c4[0xCA] == 1 but 0xCA is not in EXTERNAL_VARS,
# so the VM never forks into the branch that calls sub 0x14C7 (TEXT 0x100-0x143).
#
# Usage: ruby identify_script17_scenes.rb

$LOAD_PATH.unshift(__dir__)
require_relative "../commands_parse_tools"
require "set"
require "fileutils"

# Load the VM analysis framework
load "#{__dir__}/analyze_script3.rb"

EXPORTED_DIR = File.expand_path("../../exported", __dir__)
PROCESSED_DIR = File.join(__dir__, "processed")
OUTPUT_DIR = File.join(__dir__, "output_full")
FileUtils.mkdir_p(OUTPUT_DIR)

SCRIPT_ID = 17
TARGET_FID = 0x44

puts "=" * 70
puts "Script 17 Missing Scene Identification"
puts "=" * 70
puts
puts "Target FID: 0x#{sprintf('%02X', TARGET_FID)}"
puts "Dialog subcontent: CM1100.DAT_#{TARGET_FID + 0x29}"
puts "Root cause: c4[0xCA] not in EXTERNAL_VARS (guard at idx=1177)"
puts

# ---- Load dialog file for FID 44 ----
def load_dialog_strings(fid)
  dialog_fn = File.join(EXPORTED_DIR, "CM1100.DAT_#{fid + 0x29}")
  return {} unless File.exist?(dialog_fn)

  contents = IO.binread(dialog_fn)
  total_str_count = contents[0, 2].unpack1("S!<")
  indices = contents[0, total_str_count * 2].unpack("S!<#{total_str_count}")

  strings = {}
  (0...total_str_count).each do |ti|
    next if ti >= indices.size
    s = indices[ti]
    next if s == 0
    str = +""
    p = 0
    loop do
      break if p >= contents.length
      b1 = contents[s * 2 + p]
      b2 = contents[s * 2 + p + 1]
      break if (b1.nil? || b1 == "\x00") && (b2.nil? || b2 == "\x00")
      str << b1 if b1
      str << b2 if b2
      p += 2
      break if p > 500
    end
    decoded = begin
      str.force_encoding("shift_jis").encode("utf-8").strip
    rescue
      str.force_encoding("utf-8").strip
    end
    strings[ti] = decoded unless decoded.empty?
  end
  strings
end

# ---- Run analysis with specified external vars ----
def run_analysis(script_id, extra_external)
  fn = File.join(EXPORTED_DIR, "CM1100.DAT_#{script_id}")
  return {} unless File.exist?(fn)

  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }

  manager.external_vars = VMState::EXTERNAL_VARS.dup
  manager.external_vars += extra_external if extra_external

  state = VMState.new(script_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  run_manager(manager, commands, script_id)
  [manager.dialogs, manager.instance_variable_get(:@visited).size]
end

# ---- Output dialog groups to file ----
def write_dialogs(fid, dialogs, output_dir)
  groups = dialogs[fid]
  return 0 unless groups

  groups = groups.to_a
  dialog_fn = File.join(EXPORTED_DIR, "CM1100.DAT_#{fid + 0x29}")
  return 0 unless File.exist?(dialog_fn)

  contents = IO.binread(dialog_fn)
  len = contents[0, 2].unpack1("S!<")
  indices = contents[0, len * 2].unpack("S!<#{len}")

  out_fn = File.join(output_dir, "script#{SCRIPT_ID}_fid#{sprintf('%02X', fid)}.txt")
  File.open(out_fn, "w", encoding: "utf-8") do |f|
    sorted_groups = groups.sort_by { |g| g[:texts].first || 0 }
    group_no = 0
    sorted_groups.each do |g|
      group_no += 1
      nc = g[:next_cmd] || 0
      left = g[:left_face] || -1
      right = g[:right_face] || -1
      side = g[:speaker_side] || 0
      speaker_id = side == 0 ? left : right
      speaker_str = speaker_id >= 0 ? sprintf("char_%04X", speaker_id) : "none"
      side_str = side == 0 ? "left" : "right"
      next_cmd_str = sprintf("next=%04X", nc)

      f.puts "--- Group #{group_no} [#{side_str}:#{speaker_str} #{next_cmd_str}] ---"

      g[:texts].each do |text_idx|
        next unless text_idx < indices.size
        start_offset = indices[text_idx]
        str = +""
        pos = 0
        loop do
          break if contents[start_offset * 2 + pos] == "\x00" && contents[start_offset * 2 + pos + 1] == "\x00"
          str << contents[start_offset * 2 + pos] << contents[start_offset * 2 + pos + 1]
          pos += 2
          break if pos > 200
        end
        begin
          decoded = str.force_encoding("shift_jis").encode("utf-8")
          f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', text_idx)}] #{decoded}"
        rescue
          f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', text_idx)}] (encoding error)"
        end
      end
      f.puts ""
    end
  end
  groups.size
end

# ---- Collect TEXT indices from dialog groups ----
def collect_text_indices(dialogs, fid)
  ids = Set.new
  groups = dialogs[fid]
  return ids unless groups
  groups.each { |g| g[:texts].each { |t| ids.add(t) } }
  ids
end

# ===== RUN =====

# Step 1: Standard analysis (without 0xCA - replicates existing coverage)
puts "Step 1: Standard analysis (EXTERNAL_VARS without 0xCA)..."
dialogs_std, visited_std = run_analysis(SCRIPT_ID, nil)
texts_std = collect_text_indices(dialogs_std, TARGET_FID)
puts "  FID #{sprintf('%02X', TARGET_FID)}: #{texts_std.size} unique TEXT indices, visited=#{visited_std}"
puts

# Step 2: Augmented analysis (with 0xCA in EXTERNAL_VARS)
puts "Step 2: Augmented analysis (EXTERNAL_VARS + 0xCA)..."
dialogs_aug, visited_aug = run_analysis(SCRIPT_ID, [0xCA])
texts_aug = collect_text_indices(dialogs_aug, TARGET_FID)
puts "  FID #{sprintf('%02X', TARGET_FID)}: #{texts_aug.size} unique TEXT indices, visited=#{visited_aug}"
puts

# Step 3: Compare and identify newly discovered TEXT
newly_found = texts_aug - texts_std
still_missing = texts_std - texts_aug

puts "=" * 70
puts "Coverage Comparison for FID 0x#{sprintf('%02X', TARGET_FID)}"
puts "=" * 70
puts "  Standard analysis TEXT count: #{texts_std.size}"
puts "  Augmented analysis TEXT count: #{texts_aug.size}"
puts "  Newly discovered TEXT: #{newly_found.size}"
puts "  Still missing (in standard only): #{still_missing.size}"
puts
puts "  Visited states: #{visited_std} (std) → #{visited_aug} (aug)"
puts

# Step 4: Show the newly discovered TEXT ranges
if newly_found.any?
  puts "New TEXT indices discovered:"
  ranges = []
  sorted = newly_found.sort
  range_start = sorted.first
  sorted.each_cons(2) do |a, b|
    if b != a + 1
      ranges << (range_start == a ? "0x#{sprintf('%04X', a)}" : "0x#{sprintf('%04X', range_start)}-0x#{sprintf('%04X', a)}")
      range_start = b
    end
  end
  last = sorted.last
  ranges << (range_start == last ? "0x#{sprintf('%04X', last)}" : "0x#{sprintf('%04X', range_start)}-0x#{sprintf('%04X', last)}")
  puts "  #{ranges.join(', ')}"
  puts
end

# Step 5: Compare against dialog file to calculate actual coverage
all_dialog_strings = load_dialog_strings(TARGET_FID)
covered_by_aug = texts_aug & all_dialog_strings.keys.to_set
missing_in_aug = all_dialog_strings.keys.to_set - texts_aug

puts "Dialog file (CM1100.DAT_#{TARGET_FID + 0x29}) comparison:"
puts "  Non-empty strings in file: #{all_dialog_strings.size}"
puts "  Covered by augmented run:  #{covered_by_aug.size}"
puts "  Still missing:             #{missing_in_aug.size}"
puts "  Coverage: #{((covered_by_aug.size.to_f / all_dialog_strings.size) * 100).round(1)}%"

if missing_in_aug.any?
  puts
  puts "Still missing TEXT indices:"
  missing_in_aug.sort.each do |ti|
    text = all_dialog_strings[ti]
    display = text.length > 70 ? "#{text[0..69]}..." : text
    puts "  TEXT:#{sprintf('%04X', ti)} -> #{display}"
  end
end
puts

# Step 6: Write augmented results
if dialogs_aug.any?
  puts "=" * 70
  puts "Writing dialog files to #{OUTPUT_DIR}/"
  puts "=" * 70

  dialogs_aug.each_key do |fid|
    count = write_dialogs(fid, dialogs_aug, OUTPUT_DIR)
    next if count == 0
    fid_hex = sprintf('%02X', fid)
    texts = collect_text_indices(dialogs_aug, fid).size
    std_texts = collect_text_indices(dialogs_std, fid).size
    diff = texts - std_texts
    diff_str = diff > 0 ? " (+#{diff} new)" : ""
    puts "  FID 0x#{fid_hex}: #{count} groups, #{texts} texts#{diff_str} → script#{SCRIPT_ID}_fid#{fid_hex}.txt"
  end
  puts
  puts "Files written to: #{OUTPUT_DIR}"
else
  puts "WARNING: No dialogs found in augmented analysis."
end
puts
puts "Done."
