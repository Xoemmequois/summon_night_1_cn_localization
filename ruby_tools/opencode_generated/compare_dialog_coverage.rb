require "set"

def usage
  puts "Usage: ruby compare_dialog_coverage.rb <FID>"
  puts "  FID: hex dialog file ID, e.g. 02, 0A, 1F, 91"
  puts "Compares processed/ files for the given FID against the CM1100.DAT dialog subcontent,"
  puts "and reports text present in CM1100.DAT but missing from processed/."
  exit 1
end

usage unless ARGV.size == 1

fid_str = ARGV[0].sub(/^0x/i, "")
fid = fid_str.to_i(16)

if fid < 0 || fid > 0xFF
  puts "Error: invalid FID '#{ARGV[0]}'"
  exit 1
end

dialog_subcontent_id = fid + 0x29
exported_dir = File.expand_path("../../exported", __dir__)
processed_dir = File.join(__dir__, "processed")
dialog_fn = File.join(exported_dir, "CM1100.DAT_#{dialog_subcontent_id}")

unless File.exist?(dialog_fn)
  puts "Error: dialog file CM1100.DAT_#{dialog_subcontent_id} not found (FID=#{sprintf('%02X', fid)})"
  puts "  path: #{dialog_fn}"
  exit 1
end

# ---- Parse CM1100.DAT dialog subcontent ----
contents = IO.binread(dialog_fn)
total_str_count = contents.unpack1("S!<")

if total_str_count == 0
  puts "FID #{sprintf('%02X', fid)}: dialog file is empty (0 strings)"
  exit 0
end

indices = contents.unpack("S!<#{total_str_count}")
# indices[0] = total string count (in offset-table convention)
# For actual strings, iterate text indices 0..total_str_count-1

dialog_strings = {}   # text_index => decoded UTF-8 string
(0...total_str_count).each do |ti|
  next if ti >= indices.size
  s = indices[ti]
  str = +""
  p = 0
  loop do
    break if contents[s * 2 + p] == "\x0" && contents[s * 2 + p + 1] == "\x0"
    str << contents[s * 2 + p] << contents[s * 2 + p + 1]
    p += 2
    break if p > 200
  end
  decoded = begin
    str.force_encoding("shift_jis").encode("utf-8").strip
  rescue
    str.force_encoding("utf-8").strip
  end
  dialog_strings[ti] = decoded unless decoded.empty?
end

# ---- Collect covered TEXT indices from processed files ----
# Matches lines like: +[FID:02, TEXT:0001] or -[FID:02, TEXT:006A]
processed_pattern = /\A[+-]\[FID:#{sprintf('%02X', fid)}, TEXT:([0-9A-F]{4})\]/
covered_indices = Set.new

# Find all processed files for this FID across all scripts
glob_pattern = File.join(processed_dir, "script*_fid#{sprintf('%02X', fid)}.txt")
processed_files = Dir[glob_pattern]

if processed_files.empty?
  puts "Warning: no files found under processed/ for FID=#{sprintf('%02X', fid)}"
end

processed_files.each do |fn|
  File.foreach(fn, encoding: "utf-8") do |line|
    line = line.strip
    if m = line.match(processed_pattern)
      text_index = m[1].to_i(16)
      covered_indices.add(text_index)
    end
  end
end

# ---- Compare and report ----
puts "=" * 70
puts "Dialog coverage: FID #{sprintf('%02X (%d)', fid, fid)} <- CM1100.DAT_#{dialog_subcontent_id}"
puts "=" * 70
puts "  Non-empty strings in dialog file: #{dialog_strings.size}"
puts "  Processed files:                  #{processed_files.size}"
puts "  Covered text indices:             #{covered_indices.size}"

missing_indices = dialog_strings.keys.to_set - covered_indices

if missing_indices.empty?
  puts
  puts "Result: fully covered - all text in CM1100.DAT has a match in processed/"
  puts
  exit 0
end

puts "  Missing text indices:             #{missing_indices.size}"
puts

# Report each missing string
missing_indices.sort.each do |ti|
  text = dialog_strings[ti]
  # Truncate long strings for display
  display = text.length > 70 ? "#{text[0..69]}..." : text
  puts "  TEXT:#{sprintf('%04X', ti)} -> #{display}"
end

puts
puts "=" * 70
puts "  Missing: #{missing_indices.size}, Covered: #{covered_indices.size}, Total: #{dialog_strings.size}"
puts "  Coverage: #{(covered_indices.size.to_f / dialog_strings.size * 100).round(1)}%"
puts "=" * 70
