require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

# 批量分析所有可达脚本 (1-40)
puts "=" * 70
puts "BATCH ANALYSIS: Scripts 1-40"
puts "=" * 70

results = []
total_start = Time.now

(1..40).each do |id|
  fn = "../../exported/CM1100.DAT_#{id}"
  unless File.exist?(fn)
    puts "  SKIP #{id}: file not found"
    next
  end

  commands = parse_commands(fn).to_a
  count_2013 = commands.count { |c| c.code == 0x2013 }
  count_002f = commands.count { |c| c.code == 0x002F }
  
  if count_2013 == 0 && count_002f == 0
    puts "  SKIP #{id}: no dialogs (0x2013=#{count_2013}, 0x002F=#{count_002f})"
    results << { id: id, dialogs: 0, groups: 0, text_ids: 0, files: [], time: 0, cmd_count: commands.size }
    next
  end

  puts
  print "  Script #{id}: #{commands.size} cmds, #{count_2013}×2013, #{count_002f}×002F ... "
  STDOUT.flush
  
  t0 = Time.now
  
  # 先用默认外部变量分析
  dialogs = analyze_script_static(id)
  
  # 如果覆盖率低(未达40%的2013)，尝试加入0x95
  all_ids = Set.new
  dialogs.each { |_, groups| groups.each { |g| g.each { |t| all_ids.add(t) } } }
  
  if count_2013 > 0 && all_ids.size < count_2013 * 0.4
    dialogs2 = analyze_script_static(id, {}, [0x95])
    ids2 = Set.new
    dialogs2.each { |_, groups| groups.each { |g| g.each { |t| ids2.add(t) } } }
    if ids2.size > all_ids.size
      dialogs = dialogs2
      all_ids = ids2
    end
  end
  
  elapsed = (Time.now - t0).round(1)
  groups = dialogs.values.sum { |g| g.size }
  files = dialogs.keys.sort
  
  puts "done (#{elapsed}s) → #{groups} groups, #{all_ids.size} text IDs, files: #{files.map{|f|sprintf('%02X',f)}.join(',')}"
  
  results << {
    id: id,
    dialogs: count_2013,
    groups: groups,
    text_ids: all_ids.size,
    files: files,
    time: elapsed,
    cmd_count: commands.size
  }
end

puts
puts "=" * 70
puts "SUMMARY"
puts "=" * 70
puts " ID  Cmds   2013  Groups  TextIDs  Files        Time"
puts "---  -----  ----  ------  -------  -------      ----"

total_groups = 0
total_ids = 0
total_2013 = 0
total_time = 0

results.each do |r|
  file_str = r[:files].map { |f| sprintf('%02X', f) }.join(',')
  file_str = "(none)" if file_str.empty?
  puts " %3d  %5d  %4d  %6d  %7d  %-12s %5.1fs" % [r[:id], r[:cmd_count], r[:dialogs], r[:groups], r[:text_ids], file_str, r[:time]]
  total_groups += r[:groups]
  total_ids += r[:text_ids]
  total_2013 += r[:dialogs]
  total_time += r[:time]
end

puts "---  -----  ----  ------  -------  -------      ----"
puts " TOT        %4d  %6d  %7d               %5.1fs" % [total_2013, total_groups, total_ids, total_time]
puts
puts "Total wall time: #{(Time.now - total_start).round(1)}s"
