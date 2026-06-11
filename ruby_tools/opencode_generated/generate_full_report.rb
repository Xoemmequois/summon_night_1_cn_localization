require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

# ============================================================
# 全量分析 + 带元数据的输出 + 覆盖率报告
# ============================================================

def analyze_with_metadata(target_id)
  fn = "../../exported/CM1100.DAT_#{target_id}"
  return {} unless File.exist?(fn)
  
  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup
  
  state = VMState.new(target_id)
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
  run_manager(manager, commands, target_id)
  manager.dialogs
end

# ============================================================
# 主流程
# ============================================================

out_dir = File.join(__dir__, "output_full")
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

all_fid_strings = {}   # fid => { text_idx => "string" }
all_fid_covered = {}   # fid => Set of text_idx covered
all_fid_missing = {}   # fid => Set of text_idx missing

puts "=" * 70
puts "FULL REPORT: dialog groups with metadata + coverage"
puts "=" * 70

(1..40).each do |sid|
  fn = "../../exported/CM1100.DAT_#{sid}"
  next unless File.exist?(fn)
  
  commands = parse_commands(fn).to_a
  count_2013 = commands.count { |c| c.code == 0x2013 }
  next if count_2013 == 0
  
  print "  Script #{sid}... "
  STDOUT.flush
  t0 = Time.now
  
  dialogs = analyze_with_metadata(sid)
  
  # 输出每个对话文件
  dialogs.each do |fid, groups|
    groups = groups.to_a.sort_by { |g| g[:texts].first || 0 }
    
    dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
    next unless File.exist?(dialog_fn)
    
    contents = IO.binread(dialog_fn)
    len = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{len}")
    
    # 缓存对话文件字符串
    all_fid_strings[fid] ||= begin
      strs = {}
      (0...len).each do |ti|
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
          strs[ti] = str.force_encoding("shift_jis").encode("utf-8")
        rescue
          strs[ti] = "(encoding error)"
        end
      end
      strs
    end
    
    all_fid_covered[fid] ||= Set.new
    
    # 输出带元数据的对话组
    File.open("#{out_dir}/script#{sprintf('%02d', sid)}_fid#{sprintf('%02X', fid)}.txt", "w") do |f|
      group_no = 0
      groups.each do |g|
        group_no += 1
        # speaker info
        left = g[:left_face] || -1
        right = g[:right_face] || -1
        side = g[:speaker_side] || 0
        speaker_id = side == 0 ? left : right
        speaker_str = speaker_id >= 0 ? sprintf('char_%04X', speaker_id) : 'none'
        side_str = side == 0 ? 'left' : 'right'
        nc = g[:next_cmd] || 0
        f.puts "--- Group #{group_no} [#{side_str}:#{speaker_str} next=#{sprintf('%04X', nc)}] ---"
        g[:texts].each do |ti|
          next if ti >= indices.size
          all_fid_covered[fid].add(ti)
          str = all_fid_strings[fid][ti] || "(missing)"
          f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', ti)}] #{str}"
        end
        f.puts ""
      end
    end
  end
  
  puts "done (#{(Time.now-t0).round(1)}s)"
end

# ============================================================
# 覆盖率报告: 每个对话文件的所有字符串 vs 已覆盖
# ============================================================

puts
puts "=" * 70
puts "COVERAGE REPORT: per-file string coverage"
puts "=" * 70

all_fid_strings.keys.sort.each do |fid|
  strs = all_fid_strings[fid]
  covered = all_fid_covered[fid] || Set.new
  missing = strs.keys.to_set - covered
  
  cov_pct = strs.size > 0 ? (covered.size.to_f / strs.size * 100).round(1) : 0
  
  # 排除空字符串
  non_empty_total = strs.count { |_, v| !v.strip.empty? }
  non_empty_covered = covered.count { |ti| strs[ti] && !strs[ti].strip.empty? }
  non_empty_pct = non_empty_total > 0 ? (non_empty_covered.to_f / non_empty_total * 100).round(1) : 0
  
  status = non_empty_pct >= 99 ? "✓" : non_empty_pct >= 80 ? "⚠" : "✗"
  
  puts "  #{status} FID #{sprintf('%02X', fid)}: #{covered.size}/#{strs.size} all strings (#{cov_pct}%), #{non_empty_covered}/#{non_empty_total} non-empty (#{non_empty_pct}%)"
  
  # 列出缺失的非空字符串 (<20个时)
  missing_non_empty = missing.select { |ti| strs[ti] && !strs[ti].strip.empty? }
  if missing_non_empty.size > 0 && missing_non_empty.size <= 20
    missing_non_empty.sort.each do |ti|
      puts "       MISS [#{sprintf('%04X', ti)}] #{strs[ti][0..60]}"
    end
  elsif missing_non_empty.size > 20
    puts "       ... #{missing_non_empty.size} non-empty strings missing"
    missing_non_empty.sort.first(5).each do |ti|
      puts "       MISS [#{sprintf('%04X', ti)}] #{strs[ti][0..60]}"
    end
    puts "       ... and #{missing_non_empty.size - 5} more"
  end
end

# 总计
total_all = all_fid_strings.values.sum { |s| s.size }
total_covered = all_fid_covered.values.sum { |s| s.size }
total_non_empty = all_fid_strings.values.sum { |s| s.count { |_, v| !v.strip.empty? } }
non_empty_covered = 0
all_fid_strings.each do |fid, strs|
  covered = all_fid_covered[fid] || Set.new
  non_empty_covered += covered.count { |ti| strs[ti] && !strs[ti].strip.empty? }
end

puts
puts "=" * 70
puts "FINAL: #{non_empty_covered}/#{total_non_empty} non-empty strings covered (#{(non_empty_covered.to_f/total_non_empty*100).round(1)}%)"
puts "       #{total_covered}/#{total_all} all strings (#{(total_covered.to_f/total_all*100).round(1)}%)"
puts "       #{all_fid_strings.size} dialog files analyzed"
puts "       Output: #{out_dir}/"
