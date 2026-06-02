require "set"

puts "=" * 70
puts "COVERAGE: strings in dialog files vs strings in analysis groups"
puts "=" * 70

# 读取所有 output 目录下的文件，提取文本内容
output_dir = File.join(__dir__, "output")
output_texts = {}  # dialog_file_id => Set of text strings found

Dir["#{output_dir}/script*_fid*.txt"].each do |fn|
  next unless fn =~ /fid([0-9A-F]{2})\.txt$/
  fid = $1.to_i(16)
  output_texts[fid] ||= Set.new
  
  text = File.read(fn, encoding: "utf-8")
  text.split("\n").each do |line|
    line = line.strip
    output_texts[fid].add(line) unless line.empty?
  end
end

puts "Dialog files with output: #{output_texts.size}"
puts

total_file_strings = 0
total_covered = 0
total_files = 0

output_texts.keys.sort.each do |fid|
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  unless File.exist?(dialog_fn)
    puts "  FID #{sprintf('%02X', fid)}: dialog file not found"
    next
  end
  
  contents = IO.binread(dialog_fn)
  total_str_count = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{total_str_count}")
  
  # 提取对话文件中的所有字符串
  all_file_strings = Set.new
  (0...total_str_count).each do |ti|
    next if ti >= indices.size
    s = indices[ti]
    str = ""
    p = 0
    loop do
      break if contents[s*2+p] == "\x0" && contents[s*2+p+1] == "\x0"
      str += contents[s*2+p] + contents[s*2+p+1]
      p += 2
      break if p > 200
    end
    begin
      all_file_strings.add(str.force_encoding("shift_jis").encode("utf-8").strip)
    rescue
    end
  end
  
  found = output_texts[fid]
  common = all_file_strings.intersection(found)
  missing = all_file_strings - found
  
  pct = (common.size.to_f / all_file_strings.size * 100).round(1)
  
  total_file_strings += all_file_strings.size
  total_covered += common.size
  total_files += 1
  
  flag = missing.size > 0 ? " ⚠ #{missing.size} missing" : " ✓ COMPLETE"
  puts "  FID #{sprintf('%02X', fid)}: #{all_file_strings.size} strs in file, #{common.size} in groups (#{pct}%)#{flag}"
  
  if missing.size > 0 && missing.size <= 8
    missing.to_a.sort.each do |m|
      puts "    MISS: #{m[0..60]}"
    end
  end
end

puts
puts "=" * 70
puts "SUMMARY"
puts "  Dialog files analyzed:     #{total_files}"
puts "  Total strings in files:    #{total_file_strings}"
puts "  Total strings in groups:   #{total_covered}"
puts "  Overall coverage:          #{(total_covered.to_f/total_file_strings*100).round(1)}%"
full_cov = output_texts.keys.count do |fid|
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  next false unless File.exist?(dialog_fn)
  contents = IO.binread(dialog_fn)
  total = contents.unpack1("S!<")
  # count unique non-empty strings
  indices = contents.unpack("S!<#{total}")
  strs = Set.new
  (0...total).each do |ti|
    s = indices[ti] rescue next
    p = 0
    str = ""
    loop do
      break if contents[s*2+p] == "\x0" && contents[s*2+p+1] == "\x0"
      str += contents[s*2+p] + contents[s*2+p+1]
      p += 2
      break if p > 200
    end
    begin
      strs.add(str.force_encoding("shift_jis").encode("utf-8").strip)
    rescue
    end
  end
  output_texts[fid].size >= strs.size
end
puts "  Files with 100% coverage:  #{full_cov}"
