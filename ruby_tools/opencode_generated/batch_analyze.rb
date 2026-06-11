require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"

# 批量分析所有可达脚本 (1-40)
puts "=" * 70
puts "BATCH ANALYSIS: Scripts 1-40 (with speaker + next_cmd tracking)"
puts "=" * 70

results = []
total_start = Time.now
global_next_cmd = Hash.new(0)

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
  
  # 用默认外部变量分析
  dialogs = analyze_script_static(id)
  
  # 如果覆盖率低(未达40%的2013)，尝试加入0x95
  all_ids = Set.new
  dialogs.each { |_, groups| groups.each { |g| g[:texts].each { |t| all_ids.add(t) } } }
  
  if count_2013 > 0 && all_ids.size < count_2013 * 0.4
    dialogs2 = analyze_script_static(id, {}, [0x95])
    ids2 = Set.new
    dialogs2.each { |_, groups| groups.each { |g| g[:texts].each { |t| ids2.add(t) } } }
    if ids2.size > all_ids.size
      dialogs = dialogs2
      all_ids = ids2
    end
  end
  
  elapsed = (Time.now - t0).round(1)
  groups = dialogs.values.sum { |g| g.size }
  files = dialogs.keys.sort
  
  # 统计 next_cmd 和 speaker
  local_next_cmd = Hash.new(0)
  speaker_chars = Set.new
  dialogs.each do |_, groups|
    groups.each do |g|
      nc = g[:next_cmd] || 0
      local_next_cmd[nc] += 1
      global_next_cmd[nc] += 1
      
      left = g[:left_face] || -1
      right = g[:right_face] || -1
      side = g[:speaker_side] || 0
      speaker_id = side == 0 ? left : right
      speaker_chars.add(speaker_id) if speaker_id >= 0
    end
  end
  
  puts "done (#{elapsed}s) → #{groups} groups, #{all_ids.size} text IDs, files: #{files.map{|f|sprintf('%02X',f)}.join(',')}"
  if local_next_cmd.size > 0
    cmd_summary = local_next_cmd.sort.map{|cmd,c| "#{sprintf('%04X',cmd)}(#{c})"}.join(' ')
    puts "         next_cmds: #{cmd_summary}"
    puts "         speakers: #{speaker_chars.sort.map{|c| sprintf('%04X',c)}.join(', ')}" if speaker_chars.size > 0
  end
  
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
puts "=" * 70
puts "GLOBAL next_cmd statistics (all scripts):"
global_next_cmd.sort.each do |cmd, count|
  desc = case cmd
  when 0x2012 then "2012 (normal dialog advance)"
  when 0x2015 then "2015 (waiting for player choice)"
  when 0x201D then "201D (black screen / cutscene)"
  when 0x0023 then "0023 (unconditional jump)"
  when 0x0025 then "0025 (call)"
  when 0x0026 then "0026 (return)"
  when 0xFFFF then "FFFF (script end)"
  when 0 then "0 (execution path end)"
  else sprintf('%04X', cmd)
  end
  puts "  #{sprintf('%04X', cmd)}: #{count} groups  — #{desc}"
end
puts
puts "Total wall time: #{(Time.now - total_start).round(1)}s"
