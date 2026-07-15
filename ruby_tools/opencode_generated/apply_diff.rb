#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# apply_diff.rb
# 将 COMMON.TXT 中的译文应用到 processed/ 目录中的文件
#
# 用法: ruby apply_diff.rb [--processed-dir <dir>] <input_file> <fid_start> [fid_end]
#   fid_start/fid_end: 十六进制FID，可选0x前缀。如 2F 或 0x2F
#   若只指定 fid_start，仅处理该 FID
#
# COMMON.TXT 格式:
#   --- Group [left:主人公 next=0023] ---G
#   日文原文行1
#   日文原文行2
#   +[FID:2F, TEXT:02CA] 译文A
#   -[FID:2F, TEXT:02CB] 译文B
#
# 匹配逻辑: 在 processed/ 中按FID范围查找，比对整个group的日文原文
# （每行去除首尾空白后拼接），匹配成功则按译文行顺序逐行替换中文内容，
# 保留原文件的行前缀（+/ - 和 FID:TEXT 标记），只替换后面的译文文本。
# + 和 - 开头的行均为需要应用的译文。
# ============================================================

require "set"

DEFAULT_PROCESSED_DIR = File.join(__dir__, "processed")

# ---- Helpers ----

def parse_fid(str)
  str.sub(/^0x/i, "").to_i(16)
end

def fid_from_filename(filename)
  if filename =~ /_fid([0-9A-Fa-f]{2})\.txt$/
    $1.to_i(16)
  end
end

def japanese_key(lines)
  lines.map { |l| l.strip }.join("\n")
end

TRANSLATION_RE = /^([-+]\[FID:[0-9A-Fa-f]+, TEXT:[0-9A-Fa-f]+\])\s*(.*)$/

def split_translation_line(line)
  if (m = line.match(TRANSLATION_RE))
    [m[1], m[2]]
  else
    [nil, line]
  end
end

# ---- Parsing input file ----

InputGroup = Struct.new(:header, :japanese_lines, :trans_lines) do
  def key
    japanese_key(japanese_lines)
  end
end

def parse_input_groups(filepath)
  groups = []
  current = InputGroup.new(nil, [], [])

  File.readlines(filepath, encoding: "UTF-8").each do |line|
    stripped = line.chomp

    if stripped.start_with?("--- Group")
      current = InputGroup.new(stripped, [], [])
      groups << current
    elsif !current.header.nil?
      if stripped.start_with?("+[FID:") || stripped.start_with?("-[FID:")
        current.trans_lines << stripped
      elsif !stripped.empty?
        current.japanese_lines << stripped
      end
    end
  end

  groups.reject { |g| g.japanese_lines.empty? && g.trans_lines.empty? }
end

# ---- Line-based modification (preserves exact formatting) ----

def apply_to_processed_file(filepath, lookup)
  lines = File.readlines(filepath, encoding: "UTF-8").map(&:chomp)
  original_lines = lines.dup

  i = 0
  total_groups = 0
  updated = 0

  while i < lines.length
    break unless lines[i] && lines[i].strip.start_with?("--- Group")

    total_groups += 1

    # Collect Japanese lines from this group (for key matching)
    jp_lines = []
    trans_indices = []
    j = i + 1

    while j < lines.length && !lines[j].strip.start_with?("--- Group")
      stripped = lines[j]
      if stripped.start_with?("+[FID:") || stripped.start_with?("-[FID:")
        trans_indices << j
      elsif stripped.match?(/\S/)
        jp_lines << stripped
      end
      j += 1
    end

    key = japanese_key(jp_lines)

    if key && !key.empty? && (new_texts = lookup[key])
      # Replace translation text, preserving prefix
      trans_indices.each_with_index do |line_idx, ti|
        new_text = new_texts[ti]
        next if new_text.nil? || new_text.empty?
        prefix, _old_text = split_translation_line(lines[line_idx])
        if prefix
          lines[line_idx] = "#{prefix} #{new_text}"
        end
      end

      updated += 1 if trans_indices.any? { |ti| lines[ti] != original_lines[ti] }
    end

    i = j
  end

  if updated > 0
    File.open(filepath, "w", encoding: "UTF-8") do |f|
      lines.each { |l| f.puts l }
    end
  end

  [total_groups, updated]
end

# ---- Core ----

def apply_diff(input_path, fid_start, fid_end, processed_dir)
  input_groups = parse_input_groups(input_path)
  puts "Input: #{input_groups.length} groups parsed"

  # Build lookup: japanese_key => ordered list of translation texts
  lookup = {}
  input_groups.each do |g|
    key = g.key
    next if key.empty? || g.trans_lines.empty?
    lookup[key] = g.trans_lines.map { |l| split_translation_line(l)[1] }
  end
  puts "  with translations: #{lookup.length}"

  # Scan processed files in FID range
  total_updated = 0
  total_groups = 0
  matched_keys = Set.new

  Dir.glob(File.join(processed_dir, "script*_fid*.txt")).sort.each do |filepath|
    fid = fid_from_filename(File.basename(filepath))
    next if fid.nil?
    next unless fid >= fid_start && fid <= fid_end

    ngroups, nupdated = apply_to_processed_file(filepath, lookup)
    total_groups += ngroups

    if nupdated > 0
      puts "  #{File.basename(filepath)}: #{nupdated}/#{ngroups} groups updated"
      total_updated += nupdated
    end
  end

  # Report unmatched input groups
  matched = Set.new
  Dir.glob(File.join(processed_dir, "script*_fid*.txt")).sort.each do |filepath|
    fid = fid_from_filename(File.basename(filepath))
    next if fid.nil? || fid < fid_start || fid > fid_end
    content = File.read(filepath, encoding: "UTF-8")
    lookup.each_key do |key|
      matched << key if content.include?(key.split("\n").first || "")
    end
  end

  unmatched = lookup.keys.reject { |k| matched.include?(k) }
  if unmatched.any?
    puts "\n=== #{unmatched.length} input groups may NOT be matched ==="
    input_groups.each do |g|
      next unless unmatched.include?(g.key)
      puts "  #{g.header}"
      g.japanese_lines.each { |l| puts "    #{l}" }
      puts
    end
  end

  puts "\nDone. Updated #{total_updated} groups across #{total_groups} scanned groups."
end

# ---- Main ----

if __FILE__ == $PROGRAM_NAME
  processed_dir = DEFAULT_PROCESSED_DIR
  args = ARGV.dup

  if (idx = args.index("--processed-dir"))
    processed_dir = args[idx + 1]
    args.delete_at(idx)
    args.delete_at(idx)
  end

  if args.length < 2
    puts "用法: ruby apply_diff.rb [--processed-dir <dir>] <input_file> <fid_start> [fid_end]"
    puts "  --processed-dir:  processed/ 目录路径（默认: #{DEFAULT_PROCESSED_DIR}）"
    puts "  fid_start/fid_end: 十六进制FID，可选0x前缀。如 2F 或 0x2F"
    puts "  若只指定 fid_start，仅处理该 FID"
    exit 1
  end

  input_path = args[0]
  fid_start = parse_fid(args[1])
  fid_end   = args.length >= 3 ? parse_fid(args[2]) : fid_start

  unless File.exist?(input_path)
    puts "错误: 输入文件不存在: #{input_path}"
    exit 1
  end

  unless Dir.exist?(processed_dir)
    puts "错误: processed/ 目录不存在: #{processed_dir}"
    exit 1
  end

  if fid_start > fid_end
    puts "错误: fid_start (#{sprintf('0x%02X', fid_start)}) > fid_end (#{sprintf('0x%02X', fid_end)})"
    exit 1
  end

  puts "FID range: 0x#{fid_start.to_s(16).upcase} - 0x#{fid_end.to_s(16).upcase}"
  apply_diff(input_path, fid_start, fid_end, processed_dir)
end
