#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# apply_diff.rb
# 将翻译 diff 输入文件中的变更应用到 processed/ 目录中的文件
#
# 用法: ruby apply_diff.rb <input_file> <fid_start> [fid_end]
#   fid_start/fid_end: 十六进制FID，可选0x前缀。如 2F 或 0x2F
#   若只指定 fid_start，仅处理该 FID
#
# 输入文件格式:
#   --- Group [left:主人公 next=0023] ---G
#   日文原文行1
#   日文原文行2
#   -[FID:2F, TEXT:02CA] 旧译文（参考用，不应用）
#   +[FID:2F, TEXT:02CB] 新译文行1
#   +[FID:2F, TEXT:02CC] 新译文行2
#
# 匹配逻辑: 在 processed/ 中按FID范围查找，比对群组的日文原文
# （每行去除首尾空白后拼接），匹配成功则替换为该群的+行译文。
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

def translation_line?(s)
  s.start_with?("+[FID:") || s.start_with?("-[FID:")
end

# ---- Data types ----

InputGroup = Struct.new(:header, :japanese_lines, :plus_lines, :minus_lines) do
  def key
    japanese_key(japanese_lines)
  end
end

ProcGroup = Struct.new(:header, :japanese_lines, :plus_lines, :minus_lines) do
  def key
    japanese_key(japanese_lines)
  end
end

# ---- Parsing ----

def parse_input_groups(filepath)
  groups = []
  current = InputGroup.new(nil, [], [], [])

  File.readlines(filepath, encoding: "UTF-8").each do |line|
    stripped = line.chomp

    if stripped.start_with?("--- Group")
      current = InputGroup.new(stripped, [], [], [])
      groups << current
    elsif !current.header.nil?
      if stripped.start_with?("+[FID:")
        current.plus_lines << stripped
      elsif stripped.start_with?("-[FID:")
        current.minus_lines << stripped
      elsif !stripped.empty?
        current.japanese_lines << stripped
      end
    end
  end

  groups.reject { |g| g.japanese_lines.empty? && g.plus_lines.empty? }
end

def parse_processed_file(filepath)
  groups = []
  current = ProcGroup.new(nil, [], [], [])

  File.readlines(filepath, encoding: "UTF-8").each do |line|
    stripped = line.chomp

    if stripped.strip.start_with?("--- Group")
      current = ProcGroup.new(stripped, [], [], [])
      groups << current
    elsif !current.header.nil?
      if stripped.start_with?("+[FID:") || stripped.start_with?("-[FID:")
        (stripped.start_with?("+") ? current.plus_lines : current.minus_lines) << stripped
      elsif stripped.match?(/\S/)
        current.japanese_lines << stripped
      end
      # empty lines are group separators, skip them
    end
  end

  groups.reject { |g| g.japanese_lines.empty? && g.plus_lines.empty? && g.minus_lines.empty? }
end

# ---- Output ----

def write_processed_file(filepath, groups)
  File.open(filepath, "w", encoding: "UTF-8") do |f|
    groups.each_with_index do |g, i|
      f.puts g.header
      g.japanese_lines.each { |l| f.puts l }
      g.plus_lines.each  { |l| f.puts l }
      g.minus_lines.each  { |l| f.puts l }
      f.puts
    end
  end
end

# ---- Core ----

def apply_diff(input_path, fid_start, fid_end, processed_dir)
  input_groups = parse_input_groups(input_path)
  puts "Input: #{input_groups.length} groups parsed"

  # Build lookup: key => [plus_lines, header]
  lookup = {}
  unmatched_input = []
  input_groups.each do |g|
    key = g.key
    if g.plus_lines.empty?
      unmatched_input << g if g.minus_lines.empty?
      next
    end
    lookup[key] = g
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

    groups = parse_processed_file(filepath)
    total_groups += groups.length

    updated = 0
    groups.each do |g|
      key = g.key
      next if key.empty?

      if (input_g = lookup[key])
        g.plus_lines = input_g.plus_lines.dup
        g.minus_lines = []  # replace all translations with new ones
        updated += 1
        matched_keys << key
      end
    end

    if updated > 0
      write_processed_file(filepath, groups)
      puts "  #{File.basename(filepath)}: #{updated}/#{groups.length} groups updated"
      total_updated += updated
    end
  end

  # Report unmatched input groups
  unmatched = lookup.keys.reject { |k| matched_keys.include?(k) }
  if unmatched.any?
    puts "\n=== #{unmatched.length} input groups NOT matched in processed/ ==="
    unmatched.each do |key|
      g = lookup[key]
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

  # Parse --processed-dir option
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
