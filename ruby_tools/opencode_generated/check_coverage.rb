require_relative "../commands_parse_tools"
require "set"

# 检查每个对话文件中哪些字符串被分析出来了，哪些缺失
puts "=" * 70
puts "DIALOG FILE COVERAGE: checking if all strings are in groups"
puts "=" * 70

# 第一步: 收集所有脚本中引用的 (dialog_file_id, text_id) 对
# 通过分析每个脚本的 0x2013 命令和 0x002F 设置

all_script_refs = {}  # dialog_file_id => Set of text_ids from ALL scripts

(1..40).each do |sid|
  fn = "../../exported/CM1100.DAT_#{sid}"
  next unless File.exist?(fn)
  
  commands = parse_commands(fn).to_a
  
  # 模拟执行来收集(text_id, dialog_file_id)引用
  # 简化: 直接遍历命令，跟踪 0x002F，遇到 0x2013 就记录
  current_fid = -1
  commands.each do |c|
    if c.code == 0x002F
      current_fid = c.params[0]
    elsif c.code == 0x002E
      # 0x002E 是动态的，标记为 -1（无法静态确定）
      # 跳过
    elsif c.code == 0x2013 && current_fid >= 0
      all_script_refs[current_fid] ||= Set.new
      all_script_refs[current_fid].add(c.params[0])
    end
    # 注意: 0x2013 在 0x002E 之后 dialog_fid 为 -1，无法静态确定
  end
end

puts "Total dialog files referenced by scripts: #{all_script_refs.size}"
puts

# 第二步: 检查每个被引用的对话文件
total_strings_in_files = 0
total_referenced = 0
total_in_groups = 0
total_missing = 0

all_script_refs.keys.sort.each do |fid|
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  unless File.exist?(dialog_fn)
    puts "  FID #{sprintf('%02X', fid)}: file not found (CM1100.DAT_#{fid + 0x29})"
    next
  end
  
  contents = IO.binread(dialog_fn)
  total_str_count = contents.unpack1("S!<")  # 文件中字符串总数
  indices = contents.unpack("S!<#{total_str_count}")
  
  # 脚本引用的 text_ids
  script_refs = all_script_refs[fid]
  
  # 分析器发现的分组 text_ids (从 output/ 目录读取)
  group_refs = Set.new
  Dir["#{__dir__}/output/script*_fid#{sprintf('%02X', fid)}.txt"].each do |out_fn|
    next unless File.exist?(out_fn)
    text = File.read(out_fn, encoding: "utf-8").split("\n\n").reject { |g| g.strip.empty? }
    text.each do |group|
      lines = group.strip.split("\n")
      lines.each do |line|
        # 在 indices 中查找匹配的文本
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
            decoded = str.force_encoding("shift_jis").encode("utf-8").strip
            if decoded == line
              group_refs.add(ti)
              break
            end
          rescue
          end
        end
      end
    end
  end
  
  # 缺失的: 脚本引用了但分析器没找到的
  script_only = script_refs - group_refs
  
  total_strings_in_files += total_str_count
  total_referenced += script_refs.size
  total_in_groups += group_refs.size
  total_missing += script_only.size
  
  pct_script = (group_refs.size.to_f / script_refs.size * 100).round(1) rescue 0
  pct_total = (group_refs.size.to_f / total_str_count * 100).round(1) rescue 0
  
  flag = ""
  flag = " ⚠ MISSING #{script_only.size}" if script_only.size > 0
  
  puts "  FID #{sprintf('%02X', fid)}: file=#{total_str_count} strs, script_refs=#{script_refs.size}, in_groups=#{group_refs.size} (#{pct_total}% of file, #{pct_script}% of refs)#{flag}"
  
  if script_only.size > 0 && script_only.size <= 10
    script_only.to_a.sort.each do |ti|
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
        puts "    MISS text[#{ti}]: #{str.force_encoding('shift_jis').encode('utf-8')[0..50]}"
      rescue
        puts "    MISS text[#{ti}]: (encoding error)"
      end
    end
  end
end

puts
puts "=" * 70
puts "SUMMARY"
puts "  Total strings in dialog files: #{total_strings_in_files}"
puts "  Total referenced by scripts:   #{total_referenced}"
puts "  Total found in groups:         #{total_in_groups}"
puts "  Total missing:                 #{total_missing}"
puts "  Coverage:                      #{(total_in_groups.to_f/total_referenced*100).round(1)}% of script refs, #{(total_in_groups.to_f/total_strings_in_files*100).round(1)}% of all strings"
