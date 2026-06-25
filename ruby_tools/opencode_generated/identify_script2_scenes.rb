require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

# ============================================================
# 正确补全 script2 的 fid: 枚举场景(事件/进度变量), 不 fork 0x95 路由器
# ------------------------------------------------------------
# 0x95 -> fid 是 0x0494 处的确定性 1:1 路由 (6->07,7->08,8->09,
#         9->0A,A->0B,B->0C). 各 scene 自行写 0x95 再调用路由.
# scene 由事件/进度变量把守:
#   0x95=7(fid08): 0xDC==3 ; 0x95=8(fid09): 0x21==1 ;
#   0x95=A(fid0B): 0x19 switch ; 上游可达性由进度计数器 0xDE 门控.
# 故把 [0x21,0xDC,0xDE] 加入 external_vars (引擎在游戏中推进的变量),
# 让 VM 经各自合法分支到达每个 scene, 由路由映射到正确 fid 并播放
# 本场景对话. 0x95 保持内部, 避免上一版把单一场景对话贴到全部 fid 的错误.
# ============================================================

SID = 2
OUT_DIR = File.join(__dir__, "output_full")
SCENE_VARS = [0x21, 0xDC, 0xDE]
Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)

def analyze(target_id, scene_vars)
  fn = "../../exported/CM1100.DAT_#{target_id}"
  raise "missing #{fn}" unless File.exist?(fn)
  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup + scene_vars   # 不含 0x95

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

puts "Scene vars added to external_vars: #{SCENE_VARS.map { |v| sprintf('0x%02X', v) }.join(', ')} (0x95 kept internal)"
dialogs = analyze(SID, SCENE_VARS)
fids = dialogs.keys.sort
puts "Fids found: #{fids.map { |x| sprintf('%02X', x) }.join(', ')}"
fids.each { |fid| puts "  fid #{sprintf('%02X', fid)}: #{dialogs[fid].size} groups" }

written = []
fids.each { |fid| written << fid if write_fid(SID, fid, dialogs[fid]) }
puts "Wrote: #{written.map { |x| sprintf('%02X', x) }.join(', ')} -> #{OUT_DIR}/"
