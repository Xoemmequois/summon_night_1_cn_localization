# ============================================================
# trace_path.rb — 追踪 VM 执行路径到指定对话文本
# ============================================================
# 用法:
#   ruby trace_path.rb [script_id] [fid] [text_index]
#   ruby trace_path.rb 1 6 0x0F    # 追踪到 FID=6, TEXT 0x000F
#   ruby trace_path.rb              # 默认: script=1, fid=6, text=0x0F
#
# 关键: 0006-0015 = FID=6, text index=0x0F (15 decimal)
# ============================================================

require_relative "../commands_parse_tools"
load "#{__dir__}/analyze_script3.rb"
require "set"

# ============================================================
# 给 VMState 添加执行路径记录
# ============================================================

class VMState
  attr_accessor :exec_path

  alias_method :orig_init, :initialize

  def initialize(script_id)
    orig_init(script_id)
    @exec_path = []
  end

  def record_step(cmd)
    return if @exec_path.size > 8000  # 防止内存爆炸

    v = {
      f8: read_c4(0xF8), f9: read_c4(0xF9), fa: read_c4(0xFA),
      fb: read_c4(0xFB), fc: read_c4(0xFC), c3: read_c4(0xC3),
      g95: read_c4(0x95), g93: read_c4(0x93), c4: read_c4(0xC4),
      c5: read_c4(0xC5), c6: read_c4(0xC6),
    }

    params_str = cmd.params[0..[3, cmd.params.size - 1].min].map { |p| sprintf("%04X", p) }.join(" ")

    @exec_path << {
      sid:  @script_id,
      off:  cmd.index,
      code: cmd.code,
      pars: params_str,
      fid:  @dialog_file_id,
      vars: v,
      _pc:  @pc,           # 当前数组索引位置
    }
  end

  alias_method :orig_clone, :clone

  def clone
    c = orig_clone
    c.exec_path = @exec_path.map { |h| h.dup }
    c
  end
end

# ============================================================
# 重写 run_manager 以记录每一步
# ============================================================

def run_manager(manager, commands, script_id)
  step_count = 0
  until manager.instance_variable_get(:@worklist).empty?
    s = manager.instance_variable_get(:@worklist).shift
    step_count += 1
    $stderr.print "\r  Step #{step_count}, queue=#{manager.instance_variable_get(:@worklist).size}" if step_count % 200 == 0
    break if manager.instance_variable_get(:@visited).size > 200000

    path_steps = 0
    path_visited = Set.new
    loop do
      break if s.pc >= commands.size || s.pc < 0
      cmd = commands[s.pc]
      break if cmd.nil?

      # 记录每一步到 exec_path
      s.record_step(cmd) if s.exec_path.size < 5000

      step_key = [s.pc, s.stack.hash, s.regB, s.regA,
                  s.read_c4(0xF8), s.read_c4(0xF9), s.read_c4(0xFA),
                  s.read_c4(0xFB), s.read_c4(0xFC), s.read_c4(0x95),
                  s.read_c4(0xC3), s.read_c4(0xC5), s.read_c4(0xC6),
                  s.read_c4(0x19), s.read_c4(0x1B),
                  s.read_c8(0x0A)].hash
      break if path_visited.include?(step_key)
      path_visited.add(step_key)

      if !s.pending_dialogs.empty? && cmd.code != 0x2013
        manager.flush_dialogs(s, cmd.code)
      end

      cont = manager.dispatch(s, cmd, commands)
      break unless cont

      path_steps += 1
      break if path_steps > 100000
    end
    manager.flush_dialogs(s, 0) unless s.pending_dialogs.empty?
  end
  $stderr.puts
end

# ============================================================
# 改写 handle_2013 检测目标
# ============================================================

class ExecManager
  old_2013 = instance_method(:handle_2013)

  define_method(:handle_2013) do |state, cmd, mgr, cmds|
    fid = state.dialog_file_id
    text_idx = cmd.params[0]

    if $TARGET_FID && $TARGET_TEXT && fid == $TARGET_FID && text_idx == $TARGET_TEXT
      $hit_count += 1
      if $hit_count <= $hit_max
        print_target_hit(state, cmd, fid, text_idx)
      end
    end

    # 原始逻辑
    old_2013.bind(self).call(state, cmd, mgr, cmds)
  end
end

# ============================================================
# 输出命中路径
# ============================================================

$hit_count = 0
$hit_max = 5

def print_target_hit(state, cmd, fid, text_idx)
  puts
  puts "=" * 90
  puts "  TARGET HIT ##{$hit_count}"
  puts "  FID=#{sprintf('%02X', fid)}  TEXT=#{sprintf('%04X', text_idx)}  (key: #{sprintf('%04d-%04d', fid, text_idx)})"
  puts "=" * 90

  # 读取实际文本
  dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
  if File.exist?(dialog_fn)
    contents = IO.binread(dialog_fn)
    len = contents.unpack1("S!<")
    indices = contents.unpack("S!<#{len}")
    if text_idx < indices.size
      s_pos = indices[text_idx]
      str = ""
      p = 0
      loop do
        break if s_pos * 2 + p + 1 >= contents.size
        break if contents[s_pos * 2 + p] == "\x0" && contents[s_pos * 2 + p + 1] == "\x0"
        str += contents[s_pos * 2 + p] + contents[s_pos * 2 + p + 1]
        p += 2
        break if p > 200
      end
      begin
        puts "  Text: #{str.force_encoding('shift_jis').encode('utf-8')}"
      rescue
        puts "  Text: (encoding error)"
      end
    end
  end
  puts

  # 输出关键事件摘要 (只显示跳转/调用/返回/设置FID, 省略 0x2013 等线性指令)
  puts "  ---- Key Events (FID assignments, branching, sub-script calls) ----"
  puts "  #{'Offset'.ljust(8)} #{'Code'.ljust(8)} #{'FID'.ljust(6)} #{'F8 F9 FA 95 C3'.ljust(16)} #{'Note'}"
  puts "  #{'-' * 78}"

  key_codes = {
    0x002F => "SetFID",
    0x002E => "SetFID(var)",
    0x0027 => "Switch",
    0x0025 => "Call",
    0x0026 => "Return",
    0x0023 => "Jump",
    0x002C => "LoadSub",
    0x0020 => "JmpIf(RegA)",
    0x0021 => "JmpIf(RegB)",
    0x0022 => "JmpIf(!RegB)",
  }

  prev_step = nil
  consecutive_gap = 0

  state.exec_path.each do |entry|
    code = entry[:code]
    v = entry[:vars]
    is_key = key_codes.key?(code)

    unless is_key
      consecutive_gap += 1
      next
    end

    if consecutive_gap > 0 && prev_step
      puts "  #{'[...]'.ljust(8)} #{'...'.ljust(8)} #{"(#{consecutive_gap} steps)".ljust(6)}"
    end
    consecutive_gap = 0

    vars_s = sprintf("%02X %02X %02X %02X %02X", v[:f8], v[:f9], v[:fa], v[:g95], v[:c3])
    fid_s = sprintf("%02X", entry[:fid])
    note = key_codes[code] || ""

    parts = entry[:pars].split(/\s+/)
    first_param = parts[0]
    if code == 0x002F
      note += " -> FID=#{sprintf('%d', entry[:fid])}"
    elsif code == 0x0025 || code == 0x0023
      note += " -> #{first_param}" if first_param
    elsif code == 0x0020 || code == 0x0021 || code == 0x0022
      note += " -> #{first_param}" if first_param
    elsif code == 0x002C
      note += " script=#{first_param}" if first_param
    elsif code == 0x0027
      var_id = parts[1]
      note += " var=#{var_id}"
    end

    puts sprintf("  %-8s %-8s %-6s %-16s %s",
      sprintf("%04X", entry[:off]),
      sprintf("%04X", code),
      fid_s,
      vars_s,
      note
    )

    prev_step = entry
  end

  puts
  puts "  ---- End State ----"
  v = state.exec_path.last[:vars]
  puts "  #{sprintf('F8=%02X F9=%02X FA=%02X FB=%02X FC=%02X', v[:f8], v[:f9], v[:fa], v[:fb], v[:fc])}"
  puts "  #{sprintf('C3=%02X C4=%02X 95=%02X 93=%02X', v[:c3], v[:c4], v[:g95], v[:g93])}"
  puts "  #{sprintf('regB=%X stack_depth=%d', state.regB, state.stack.size)}"
  puts
end

# ============================================================
# 主入口
# ============================================================

if __FILE__ == $0
  script_id = (ARGV[0] || 1).to_i
  $TARGET_FID = (ARGV[1] || 6).to_i
  # 支持 0x0F 和 15 两种写法
  text_arg = ARGV[2] || "0x0F"
  $TARGET_TEXT = text_arg.start_with?("0x") ? text_arg.to_i(16) : text_arg.to_i

  puts "=" * 70
  puts "TRACE: #{sprintf('%04d', $TARGET_FID)}-#{sprintf('%04d', $TARGET_TEXT)} (FID=#{$TARGET_FID}, TEXT=#{sprintf('%04X', $TARGET_TEXT)})"
  puts "Target key: #{sprintf('%04d-%04d', $TARGET_FID, $TARGET_TEXT)}"
  puts "Script: #{script_id}"
  puts "=" * 70
  puts

  fn = "../../exported/CM1100.DAT_#{script_id}"
  unless File.exist?(fn)
    puts "ERROR: File not found: #{fn}"
    puts
    puts "The exported command scripts are expected at:"
    puts "  #{File.expand_path(fn, __dir__)}"
    puts
    puts "Run the rip pipeline to generate them:"
    puts "  dotnet run --project ..\\romhack_csharp -- --rip"
    exit 1
  end

  start_time = Time.now

  commands = parse_commands(fn).to_a
  puts "Parsed #{commands.size} commands from script #{script_id}"
  puts

  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  manager.external_vars = VMState::EXTERNAL_VARS.dup

  state = VMState.new(script_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  state.tbl_c4[0x95] = 0
  state.tbl_c4[0x93] = 0

  idx = manager.index_to_pc[0x012E]
  if idx.nil?
    puts "ERROR: Entry point 0x012E not found"
    exit 1
  end
  state.pc = idx

  puts "Entry: PC index=#{idx} (offset=0x012E)"
  puts "Init:  F8=#{sprintf('%X', state.read_c4(0xF8))} F9=#{sprintf('%X', state.read_c4(0xF9))} " +
       "FA=#{sprintf('%X', state.read_c4(0xFA))} C3=#{sprintf('%X', state.read_c4(0xC3))} " +
       "C4=#{sprintf('%X', state.read_c4(0xC4))}"
  puts

  manager.push(state)
  run_manager(manager, commands, script_id)

  elapsed = (Time.now - start_time).round(1)

  puts
  puts "=" * 70
  if $hit_count == 0
    puts "NO HIT. Target (#{sprintf('%04d-%04d', $TARGET_FID, $TARGET_TEXT)}) not reached."
    puts
    puts "Possible reasons:"
    puts "  1. The text is in a sub-script (loaded via 0x002C)"
    puts "  2. Different initial variable state needed"
    puts "  3. The text is unreachable from entry point 0x012E"
    puts
    puts "Try other scripts or adjust initial state variables."
  else
    puts "Found #{$hit_count} hit(s). Target IS reachable from script #{script_id}."
  end
  puts "Elapsed: #{elapsed}s"
  puts "=" * 70
end
