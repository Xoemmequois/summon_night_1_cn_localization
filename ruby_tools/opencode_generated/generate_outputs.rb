require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

out_dir = File.join(__dir__, "output")
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

puts "=" * 70
puts "Generating dialog text files for all scripts..."
puts "=" * 70

(1..40).each do |id|
  fn = "../../exported/CM1100.DAT_#{id}"
  unless File.exist?(fn)
    puts "  SKIP #{id}: no file"
    next
  end

  commands = parse_commands(fn).to_a
  count_2013 = commands.count { |c| c.code == 0x2013 }
  next if count_2013 == 0

  puts "  Script #{id}... "
  
  # 分析
  dialogs = analyze_script_static(id)
  
  # 输出每个对话文件
  dialogs.each do |fid, groups|
    groups = groups.to_a.sort_by { |g| g.first || 0 }
    
    dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
    next unless File.exist?(dialog_fn)
    
    contents = IO.binread(dialog_fn)
    len = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{len}")
    
    File.open("#{out_dir}/script#{sprintf('%02d', id)}_fid#{sprintf('%02X', fid)}.txt", "w") do |f|
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
            f.puts str.force_encoding("shift_jis").encode("utf-8")
          rescue
          end
        end
        f.puts ""
      end
    end
  end
end

puts
puts "Done. Files in #{out_dir}/"
puts "Count: #{Dir["#{out_dir}/*.txt"].size}"
