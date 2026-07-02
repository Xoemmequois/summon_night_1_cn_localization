require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

# ============================================================
# Script 04 场景识别器
# ============================================================
# Script04 是纯路由/派发脚本, 0xF9 在 0x018F 处决定当前场景。
# 每个 F9 值对应一个子场景, 各子场景写 c4[0x95] 为不同值,
# 然后在 0x042F 路由中经 0x04A4/0x0661 等功能函数级联到
# 深层子函数 (如 0x17F1/0x21E1/0x282E 等), 播放 0x2013 对话。
# 最后由 0x0494 switch 将 c4[0x95]→FID 映射:
#   2→0F, 4→11, 5→12, 7→14, 8→15
#
# 将 0xF9 加入 external_vars, 让 VM 在 0x018F 处 fork 所有
# 分支, 各分支自然到达对应 c4[0x95]→FID 并播放正确对话。
# ============================================================

SID = 4
OUT_DIR = File.join(__dir__, "output_full")
SCENE_VARS = [0xF9]  # 场景派发器

# 0x95 是多状态机核心, 游戏引擎经多轮循环逐步改变其值。
# 静态分析无法模拟多轮循环, 故枚举所有有效 c4[0x95] 值,
# 每个值单独运行一次, 合并所有 FID 的结果。
# 有效值: 2→0F, 4→11, 5→12, 7→14, 8→15
C4_95_VALUES = [2, 4, 5, 7, 8]
Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)

def analyze(target_id, scene_vars, init_95 = nil)
  fn = "../../exported/CM1100.DAT_#{target_id}"
  raise "missing #{fn}" unless File.exist?(fn)
  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup + scene_vars

  state = VMState.new(target_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = init_95 if init_95

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)
  run_manager(manager, commands, target_id)
  manager.dialogs
end

# 合并多个 runs 的 dialogs, 按 FID 去重
def merge_dialogs(all_results)
  merged = {}
  all_results.each do |dialogs|
    dialogs.each do |fid, groups|
      merged[fid] ||= Set.new
      groups.each { |g| merged[fid].add(g) }
    end
  end
  merged
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

puts "Scene vars added to external_vars: #{SCENE_VARS.map { |v| sprintf('0x%02X', v) }.join(', ')}"
puts "  (c4[0x95] → FID: 2→0F, 4→11, 5→12, 7→14, 8→15)"
puts "  Iterating over initial c4[0x95] = #{C4_95_VALUES.join(', ')}"
puts

all_results = []
C4_95_VALUES.each do |val|
  $stderr.puts "  Trying c4[0x95]=#{val}..."
  dialogs = analyze(SID, SCENE_VARS, val)
  fids = dialogs.keys.sort
  $stderr.puts "    → fids: #{fids.map{|x| sprintf('%02X',x)}.join(', ')} (#{dialogs.values.sum{|g| g.size}} groups)"
  all_results << dialogs
end

dialogs = merge_dialogs(all_results)
fids = dialogs.keys.sort
puts
puts "Fids found: #{fids.map { |x| sprintf('%02X', x) }.join(', ')}"
fids.each { |fid| puts "  fid #{sprintf('%02X', fid)}: #{dialogs[fid].size} groups" }

written = []
fids.each { |fid| written << fid if write_fid(SID, fid, dialogs[fid]) }
puts "Wrote: #{written.map { |x| sprintf('%02X', x) }.join(', ')} → #{OUT_DIR}/"
