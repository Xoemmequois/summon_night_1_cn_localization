require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

# ============================================================
# Script 07 场景识别 (FID 0x1F)
# ============================================================
# 漏文本根因: 召唤术教学剧情有三个导师版本
#   (キール / カシス / クラレット)，由分派开关
#   switch mode=2 var[0x99] @ off 0x96f 选择:
#     case 1 -> call 0xc85  (Kill 版,   TEXT 0x8B..)
#     case 2 -> call 0xf3d  (Cassis 版)
#     case 3 -> call 0x119f (Claret 版)
# var[0x99] 不在 EXTERNAL_VARS，VM 只走 case 0，
# 三个导师版本全被跳过 (168/349 漏)。
# 修复: 将 0x99 加入 external_vars -> 349/349 全覆盖。
# ============================================================

SID = 7
OUT_DIR = File.join(__dir__, "output_full")
Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)

def write_fid(sid, fid, groups)
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  return false unless File.exist?(dialog_fn)
  contents = IO.binread(dialog_fn)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  groups = groups.to_a.sort_by { |g| g[:texts].first || 0 }

  File.open("#{OUT_DIR}/script#{sprintf('%02d', sid)}_fid#{sprintf('%02X', fid)}.txt", "w") do |f|
    group_no = 0
    groups.each do |g|
      group_no += 1
      left  = g[:left_face]  || -1
      right = g[:right_face] || -1
      side  = g[:speaker_side] || 0
      speaker_id = side == 0 ? left : right
      speaker_str = speaker_id >= 0 ? sprintf('char_%04X', speaker_id) : 'none'
      side_str = side == 0 ? 'left' : 'right'
      nc = g[:next_cmd] || 0
      f.puts "--- Group #{group_no} [#{side_str}:#{speaker_str} next=#{sprintf('%04X', nc)}] ---"
      g[:texts].each do |ti|
        next if ti >= indices.size
        s = indices[ti]
        str = ""; p = 0
        loop do
          break if contents[s * 2 + p] == "\x0" && contents[s * 2 + p + 1] == "\x0"
          str += contents[s * 2 + p] + contents[s * 2 + p + 1]
          p += 2
          break if p > 200
        end
        begin
          str = str.force_encoding("shift_jis").encode("utf-8")
        rescue
          str = "(encoding error)"
        end
        f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', ti)}] #{str}"
      end
      f.puts ""
    end
  end
  true
end

puts "Script 07: extract with var[0x99] added to external_vars"
puts "  (fixes 3-mentor summoning tutorial dispatch @ switch var[0x99] off 0x96f)"
puts

dialogs = analyze_script_static(SID, {}, [0x99])
fids = dialogs.keys.sort
puts "FIDs found: #{fids.map { |x| sprintf('%02X', x) }.join(', ')}"

fids.each do |fid|
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  next unless File.exist?(dialog_fn)
  contents = IO.binread(dialog_fn)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  non_empty = (0...len).count do |ti|
    next false if ti >= indices.size
    s = indices[ti]
    str = ""; pp = 0
    loop do
      break if contents[s * 2 + pp] == "\x0" && contents[s * 2 + pp + 1] == "\x0"
      str += contents[s * 2 + pp] + contents[s * 2 + pp + 1]
      pp += 2
      break if pp > 200
    end
    !str.strip.empty?
  end
  txts = dialogs[fid].flat_map { |g| g[:texts] }.uniq.size
  pct = non_empty > 0 ? (txts.to_f / non_empty * 100).round(1) : 0
  puts "  FID #{sprintf('%02X', fid)}: #{txts}/#{non_empty} (#{pct}%) #{dialogs[fid].size} groups"
end

written = []
fids.each { |fid| written << fid if write_fid(SID, fid, dialogs[fid]) }
puts "Wrote: #{written.map { |x| sprintf('%02X', x) }.join(', ')} -> #{OUT_DIR}/"
