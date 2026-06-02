require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

puts "="*60
puts "COMPARISON: OLD (group_dialogs.rb) vs NEW (analyze_script3.rb)"
puts "="*60

[1, 2].each do |id|
  puts
  puts "--- Script #{id} ---"
  
  # Old output
  old_fn = "dialog#{id}.txt"
  old_lines = 0
  old_lines = File.read(old_fn, encoding: "utf-8").split("\n").count { |l| !l.strip.empty? } if File.exist?(old_fn)
  
  commands = parse_commands("../../exported/CM1100.DAT_#{id}").to_a
  total_2013 = commands.count { |c| c.code == 0x2013 }
  
  # New output: with default external vars
  dialogs_default = analyze_script_static(id)
  
  # New output: with extended external vars (0x95 for script 2)
  dialogs_extended = analyze_script_static(id, {}, [0x95])
  
  # Pick the better coverage
  def count_text_ids(dialogs)
    total = 0
    dialogs.each { |_, groups| ids = Set.new; groups.each { |g| g.each { |t| ids.add(t) } }; total += ids.size }
    total
  end
  def count_groups(dialogs)
    dialogs.values.sum { |g| g.size }
  end
  def count_lines(dialogs)
    dialogs.values.sum { |groups| groups.sum { |g| g.size } }
  end
  
  default_ids = count_text_ids(dialogs_default)
  extended_ids = count_text_ids(dialogs_extended)
  
  if extended_ids > default_ids
    dialogs = dialogs_extended
    tag = "with 0x95 external"
  else
    dialogs = dialogs_default
    tag = "default"
  end
  
  new_ids = count_text_ids(dialogs)
  new_groups = count_groups(dialogs)
  new_lines = count_lines(dialogs)
  
  puts "  Total 0x2013 in script: #{total_2013}"
  puts "  Old output lines: #{old_lines}"
  puts "  New (#{tag}): #{new_ids} unique text IDs, #{new_groups} groups, #{new_lines} lines"
  puts "  Dialog files found: #{dialogs.keys.sort.map{|k| sprintf('%02X',k)}.join(', ')}"
  puts "  Coverage: #{new_ids}/#{total_2013} = #{(new_ids.to_f/total_2013*100).round(1)}%"
  
  # Comparison: text-level
  if File.exist?(old_fn)
    old_set = Set.new(File.read(old_fn, encoding: "utf-8").split("\n").map(&:strip).reject(&:empty?))
    new_set = Set.new
    dialogs.each do |fid, groups|
      dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
      next unless File.exist?(dialog_fn)
      contents = IO.binread(dialog_fn)
      len = contents.unpack1("S!<")
      indices = contents.unpack("S!<#{len}")
      groups.each do |text_ids|
        text_ids.each do |ti|
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
            new_set.add(str.force_encoding("shift_jis").encode("utf-8").strip)
          rescue
          end
        end
      end
    end
    common = old_set.intersection(new_set)
    old_only = old_set - new_set
    new_only = new_set - old_set
    puts "  Text comparison:"
    puts "    Old unique lines: #{old_set.size}"
    puts "    New unique lines: #{new_set.size}"
    puts "    Common: #{common.size}"
    puts "    Old-only (false paths): #{old_only.size}"
    puts "    New-only (old missed): #{new_only.size}"
    
    if old_only.size > 0 && old_only.size <= 3
      puts "    Old-only samples:"
      old_only.to_a[0..2].each { |l| puts "      #{l[0..60]}" }
    end
    if new_only.size > 0 && new_only.size <= 3
      puts "    New-only samples:"
      new_only.to_a[0..2].each { |l| puts "      #{l[0..60]}" }
    end
  end
end
