require_relative "../commands_parse_tools"
require "set"

# ============================================================
# 双变量表 VM 模拟器 — 修复 group_dialogs.rb 的问题
# ============================================================
# 问题修复:
#   1. 追踪 A82C4 和 A82C8 两个变量表
#   2. 正确模拟 0x0003/0x0005 对 RegByteB(CalcFlags) 的设置
#   3. 从 PC=0 开始执行（第一次 F8=0，走 init 路径）
#   4. 0x002C 加载子脚本时保留变量表

$script_stats = {}

# ---------------------------------------------------------
# 指令处理: 根据 Ghidra 反编译实现
# ---------------------------------------------------------

# 0x0001: 变量清零
def handle_0001(state, cmd)
  mode = cmd.params[0]
  var_id = cmd.params[1]
  if mode == 2
    state.tbl_c4[var_id] = 0
  elsif mode == 4
    state.tbl_c8[var_id] = 0
  end
  state.pc += 1
  true
end

# 0x0003: 检查变量 == 0，结果设置 RegByteB bit0
def handle_0003(state, cmd)
  mode = cmd.params[0]
  var_id = cmd.params[1]
  val = var_id  # 默认: param[1] 作为立即数
  if mode == 2
    val = state.read_c4(var_id)
  elsif mode == 4
    val = state.read_c8(var_id)
  end
  state.regB = state.regB & 0xFE  # Clear bit 0
  state.regB |= 1 if val == 0       # Set bit 0 if equal
  state.pc += 1
  true
end

# 0x0005: 比较两个值(变量or立即数)，结果设置 RegByteB bit0
def handle_0005(state, cmd)
  mode = cmd.params[0]   # 2=A82C4, 4=A82C8
  var_id = cmd.params[1]
  cmp_mode = cmd.params[2]  # 1=立即数, 2=A82C4变量
  cmp_val = cmd.params[3]

  if mode == 2
    left = state.read_c4(var_id)
    right = (cmp_mode == 2) ? state.read_c4(cmp_val) : cmp_val
  elsif mode == 4
    left = state.read_c8(var_id)
    right = (cmp_mode == 2) ? state.read_c4(cmp_val) : cmp_val
  else
    left = 0
    right = 0
  end

  state.regB = state.regB & 0xFE
  state.regB |= 1 if left == right
  state.pc += 1
  true
end

# 0x0008: 变量+1
def handle_0008(state, cmd)
  mode = cmd.params[0]
  var_id = cmd.params[1]
  if mode == 2
    state.tbl_c4[var_id] = state.read_c4(var_id) + 1
  elsif mode == 4
    state.tbl_c8[var_id] = state.read_c8(var_id) + 1
  end
  state.pc += 1
  true
end

# 0x0009: 变量-1
def handle_0009(state, cmd)
  mode = cmd.params[0]
  var_id = cmd.params[1]
  if mode == 2
    state.tbl_c4[var_id] = state.read_c4(var_id) - 1
  elsif mode == 4
    state.tbl_c8[var_id] = state.read_c8(var_id) - 1
  end
  state.pc += 1
  true
end

# 0x0010: A82C4[param0] = param1
def handle_0010(state, cmd)
  state.tbl_c4[cmd.params[0]] = cmd.params[1]
  state.pc += 1
  true
end

# 0x0011: A82C4[param0] = A82C4[param1]
def handle_0011(state, cmd)
  state.tbl_c4[cmd.params[0]] = state.read_c4(cmd.params[1])
  state.pc += 1
  true
end

# 0x0012: A82C8[param0] = param1
def handle_0012(state, cmd)
  state.tbl_c8[cmd.params[0]] = cmd.params[1]
  state.pc += 1
  true
end

# 0x0013: A82C8[param0] = A82C4[param1]
def handle_0013(state, cmd)
  state.tbl_c8[cmd.params[0]] = state.read_c4(cmd.params[1])
  state.pc += 1
  true
end

# 0x0020: RegByteA & 1 == 0 ? fall_through : jump
def handle_0020(state, cmd, manager, commands)
  if (state.regA & 1) != 0
    manager.fork(state, commands, cmd.params[0])
    return false  # 当前路径不继续（反正被跳过了）
  end
  state.pc += 1
  true
end

# 0x0021: RegByteB & 1 == 0 ? fall_through : jump
def handle_0021(state, cmd, manager, commands)
  if (state.regB & 1) != 0
    manager.fork(state, commands, cmd.params[0])
    return false
  end
  state.pc += 1
  true
end

# 0x0022: RegByteB & 1 != 0 ? fall_through : jump (和 0x0021 相反!)
def handle_0022(state, cmd, manager, commands)
  if (state.regB & 1) == 0
    manager.fork(state, commands, cmd.params[0])
    return false
  end
  state.pc += 1
  true
end

# 0x0023: 无条件跳转
def handle_0023(state, cmd, manager, commands)
  target = cmd.params[0]
  target_idx = manager.index_to_pc[target]
  if target_idx.nil?
    puts "  WARN: Jump to unknown offset #{sprintf('%04X', target)} from #{sprintf('%04X', cmd.index)}"
    return false
  end
  state.pc = target_idx
  true
end

# 0x0025: Call (push return address, jump)
def handle_0025(state, cmd, manager, commands)
  target = cmd.params[0]
  target_idx = manager.index_to_pc[target]
  if target_idx.nil?
    puts "  WARN: Call to unknown offset #{sprintf('%04X', target)} from #{sprintf('%04X', cmd.index)}"
    return false
  end
  state.stack.push(state.pc + 1)
  state.pc = target_idx
  true
end

# 0x0026: Return
def handle_0026(state, cmd)
  if state.stack.empty?
    return false  # 堆栈空，路径结束
  end
  state.pc = state.stack.pop
  true
end

# 0x0027: Switch on variable (详见 Command0027_JumpToOffset)
def handle_0027(state, cmd, manager, commands)
  mode = cmd.params[0]
  var_id = cmd.params[1]
  param4 = cmd.params[3]  # PARAM4

  # 计算 case 值 = memory_table[var_id]
  case_val = (mode == 4) ? state.read_c8(var_id) : state.read_c4(var_id)

  if case_val < 0
    # 变量未知，fork 所有目标
    for i in 4...cmd.params.size - 1
      t = cmd.params[i]
      manager.fork_at(state, commands, t) if t != 0
    end
    # 当前路径走第一个目标
    t = cmd.params[4]
    if t != 0
      state.pc = manager.index_to_pc[t]
    else
      state.pc += 1
    end
  else
    # 变量已知，根据公式选择跳转目标
    # 跳转目标在 params[4 + case_val] (PARAM4==0 时)
    # 通用公式: target_index = case_val + 0 - PARAM4 = case_val (当 PARAM4==0)
    # 实际上硬件公式中的 "内存表值" 和 params 中的索引
    # PARAM4==0: 跳转表从 params[4] 开始，变量值直接作为索引
    # PARAM4!=0: 跳转表从 params[4] 开始，变量值 - PARAM4 作为索引
    idx = case_val
    # 实际上 Ghidra 代码中: 目标地址 = *( (PC + table[var] + 5 - PARAM4) * 2 + base )
    # 这等价于: params[4 + table[var] - PARAM4]? 
    # 不，其实是 commands 数组中的位置: table[var] 给出了相对于 PC+5 的偏移
    # 而 PARAM4 是减去的一个基值
    # 简化: params 的排列是 [4]=case0, [5]=case1, ..., 索引 = table[var] 
    # 通常 PARAM4==0, table[var] 直接就是 case index
    
    if idx >= 0 && (4 + idx) < cmd.params.size - 1
      target = cmd.params[4 + idx]
      if target != 0
        target_idx = manager.index_to_pc[target]
        if target_idx
          state.pc = target_idx
          return true
        end
      end
    end
    # fallback: 走默认路径
    state.pc += 1
  end
  true
end

# 0x002C: 加载子脚本
def handle_002c(state, cmd, manager, commands)
  script_id = cmd.params[0]
  $pending_scripts.push([script_id, state.clone])
  return false  # 当前路径暂停
end

# 0x002E: 根据变量设置对话文件ID
def handle_002e(state, cmd)
  # 简化: 标记为 unknown，需要更详细分析
  state.dialog_file_id = -1
  state.pc += 1
  true
end

# 0x002F: 设置对话文件ID
def handle_002f(state, cmd)
  state.dialog_file_id = cmd.params[0]
  state.pc += 1
  true
end

# 0x2013: 对话行
def handle_2013(state, cmd, manager)
  state.pending_dialogs.push([cmd.index, cmd.params[0]])
  state.pc += 1
  true
end

# 0xFFFF: 脚本结束
def handle_ffff(state, cmd, manager)
  manager.flush_dialogs(state, 0xFFFF) unless state.pending_dialogs.empty?
  return false
end

# ---------------------------------------------------------
# VM 状态
# ---------------------------------------------------------

class VMState
  attr_accessor :pc, :tbl_c4, :tbl_c8, :stack, :regA, :regB
  attr_accessor :dialog_file_id, :pending_dialogs, :script_id
  attr_accessor :left_face, :right_face, :speaker_side  # 0=left speaks, 1=right speaks
  attr_accessor :pending_speaker_info  # [{left:, right:, side:}] per 0x2013

  def initialize(script_id)
    @script_id = script_id
    @pc = 0
    @tbl_c4 = {}   # A82C4 变量表
    @tbl_c8 = {}   # A82C8 变量表
    @stack = []
    @regA = 0    # Ghidra: GlobalScriptContextRegShortA
    @regB = 0
    @dialog_file_id = -1
    @pending_dialogs = []
    @pending_speaker_info = []
    @left_face = -1
    @right_face = -1
    @speaker_side = 0  # 0=left, 1=right
  end

  def read_c4(id); @tbl_c4[id] || 0; end
  def read_c8(id); @tbl_c8[id] || 0; end

  def clone
    s = VMState.new(@script_id)
    s.pc = @pc
    s.tbl_c4 = @tbl_c4.dup
    s.tbl_c8 = @tbl_c8.dup
    s.stack = @stack.dup
    s.regA = @regA
    s.regB = @regB
    s.dialog_file_id = @dialog_file_id
    s.pending_dialogs = @pending_dialogs.dup
    s.pending_speaker_info = @pending_speaker_info.dup
    s.left_face = @left_face
    s.right_face = @right_face
    s.speaker_side = @speaker_side
    s
  end

  # 用于 visited 检测的关键变量 (用于 0x0027 switch)
  KEY_VARS = [0xF8, 0xF9, 0xFA, 0xC5, 0xC6, 0x95, 0xFB, 0xFC, 0x19, 0x1B, 0x93, 0x99, 0xC4, 0xC3, 0x12, 0xD2]

  # 外部变量: 游戏逻辑在 VM 外部修改, 静态分析无法确定值
  # 对于这些变量, 分支指令 (0x0003/0x0005 → 0x0020/0x0021/0x0022) 会 fork 两条路径
  EXTERNAL_VARS = [0x19, 0x1B, 0x1D, 0x93, 0x99]  # 0x93 控制主对话分支选择; 0x99 是 0x1D 的快照(角色/话题选择)

  def self.external_vars
    EXTERNAL_VARS
  end

  def state_key
    key_vals = KEY_VARS.map { |v| read_c4(v) }
    c8_keys = [0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]
    c8_vals = c8_keys.map { |v| read_c8(v) }
    [@script_id, @pc, @stack.hash, @regB, @regA, @dialog_file_id, key_vals, c8_vals].hash
  end
end

# ---------------------------------------------------------
# 执行管理器
# ---------------------------------------------------------

class ExecManager
  attr_reader :index_to_pc, :dialogs, :unknown_dialogs
  attr_accessor :external_vars

  def initialize
    @worklist = []
    @visited = Set.new
    @dialogs = {}      # dialog_file_id => Set of groups
    @unknown_dialogs = []
    @next_scripts = [] # [script_id, state]
    @external_vars = VMState::EXTERNAL_VARS.dup
  end

  def index_to_pc=(val)
    @index_to_pc = val
  end

  def push(state)
    key = state.state_key
    return if @visited.include?(key)
    @visited.add(key)
    @worklist.push(state)
  end

  def fork(parent, commands, target_offset)
    s = parent.clone
    idx = @index_to_pc[target_offset]
    return unless idx
    s.pc = idx
    push(s)
  end

  def fork_at(parent, commands, target_offset)
    fork(parent, commands, target_offset)
  end

  def flush_dialogs(state, next_cmd_code = 0)
    fid = state.dialog_file_id
    if state.pending_dialogs.empty?
      return
    end
    if fid < 0
      state.pending_dialogs.each { |d| @unknown_dialogs.push(d) }
    else
      groups = @dialogs[fid]
      unless groups
        groups = Set.new
        @dialogs[fid] = groups
      end
      # 对话组: 包含文本ID、角色信息、后续指令类型
      group_texts = state.pending_dialogs.map { |d| d[1] }
      # 取第一个 0x2013 的 speaker 信息作为整组信息
      first_info = state.pending_speaker_info.first || { left: -1, right: -1, side: 0 }
      group_key = {
        texts: group_texts,
        left_face: first_info[:left],
        right_face: first_info[:right],
        speaker_side: first_info[:side],
        next_cmd: next_cmd_code,
      }
      groups.add(group_key)
    end
    state.pending_dialogs = []
    state.pending_speaker_info = []
  end

  def run(script_id, commands, parent_state = nil, debug = false)
    $stderr.puts "Running script #{script_id} (#{commands.size} commands)..."
    $stderr.puts "  parent_state: #{parent_state ? "F8=#{parent_state.read_c4(0xF8)} F9=#{parent_state.read_c4(0xF9)} FA=#{parent_state.read_c4(0xFA)}" : "nil"}"

    @index_to_pc = {}
    commands.each_with_index { |c, i| @index_to_pc[c.index] = i }
    @commands = commands

    init_state = parent_state ? parent_state.clone : VMState.new(script_id)
    if parent_state.nil? && script_id == 3
      # 脚本 3: 从 PC=127 开始 (跳过 init, 模拟从脚本 1 加载的状态)
      # 模拟脚本 1 init 设置的变量: F8=3, F9=0xA, FA=0x0D, FB=0, FC=0
      init_state.tbl_c4[0xF8] = 3
      init_state.tbl_c4[0xF9] = 0xA
      init_state.tbl_c4[0xFA] = 0x0D
      init_state.tbl_c4[0xFB] = 0
      init_state.tbl_c4[0xFC] = 0
      init_state.tbl_c4[0xC4] = 4
      init_state.tbl_c4[0xC3] = 4
      init_state.tbl_c4[0x95] = 0
      init_state.tbl_c4[0x93] = 0
      init_state.pc = 127  # index of offset 0x012E (main switch)
      # 但是我们需要找到正确的 index
      idx = @index_to_pc[0x012E]
      if idx
        init_state.pc = idx
      else
        init_state.pc = 0
      end
    else
      init_state.pc = 0
    end
    push(init_state)

    step_count = 0
    until @worklist.empty?
      # 防止状态爆炸
      if @visited.size > 50000
        $stderr.puts "  Visited limit reached!"
        break
      end
      
      state = @worklist.shift
      step_count += 1

      # 进度汇报
      $stderr.print "\r  Step #{step_count}, queue=#{@worklist.size}, visited=#{@visited.size}" if step_count % 1000 == 0

      path_steps = 0
      path_visited = Set.new  # 路径内 (pc, state_key) 去重
      loop do
        break if state.pc >= commands.size || state.pc < 0

        cmd = commands[state.pc]
        break if cmd.nil?

        # 路径内 visited 检查 (防止单个 state 内的死循环)
        step_key = [state.pc, state.stack.hash, state.regB, state.regA,
                    state.read_c4(0xF8), state.read_c4(0xF9), state.read_c4(0xFA),
                    state.read_c4(0xFB), state.read_c4(0xFC), state.read_c4(0x95),
                    state.read_c4(0xC3), state.read_c4(0xC5), state.read_c4(0xC6),
                    state.read_c4(0x19), state.read_c4(0x1B),
                    state.read_c8(0x0A)].hash
        if path_visited.include?(step_key)
          # 死循环检测
          break
        end
        path_visited.add(step_key)

        if debug && path_steps < 200
          $stderr.printf "    [%d] %04X: %04X %s  (F8=%X F9=%X FA=%X FB=%X RegB=%X)\n",
            path_steps, cmd.index, cmd.code,
            cmd.params[0..[2, cmd.params.size-1].min].map{|p| sprintf("%04X",p)}.join(" "),
            state.read_c4(0xF8), state.read_c4(0xF9), state.read_c4(0xFA),
            state.read_c4(0xFB), state.regB
        end

        # 每执行一条指令前检查：遇到非2013指令时提交积累的对话
        if !state.pending_dialogs.empty? && cmd.code != 0x2013
          mgr.flush_dialogs(state, cmd.code)
        end

        cont = dispatch(state, cmd, commands)

        break unless cont

        path_steps += 1
        # 防止死循环
        if path_steps > 100000
          $stderr.puts "  WARN: path step limit reached"
          break
        end
      end

      # 如果 path 结束时还有未提交的对话
      flush_dialogs(state, 0) unless state.pending_dialogs.empty?
    end

    $stderr.puts "\r  Done. Steps=#{step_count} worklist_items, visited_states=#{@visited.size}"
    $stderr.puts "  Dialogs: #{@dialogs.keys.sort.map{|k| "#{sprintf('%02X',k)}(#{@dialogs[k].size})"}.join(', ')}"
    $stderr.puts "  Unknown: #{@unknown_dialogs.size}"
    @dialogs
  end

  # 指令分发
  HANDLERS = {
    0x0001 => :handle_0001,
    0x0003 => :handle_0003,
     0x0005 => :handle_0005,
     0x0008 => :handle_0008,
     0x0009 => :handle_0009,
     0x000A => :handle_000A,
     0x0010 => :handle_0010,
    0x0011 => :handle_0011,
    0x0012 => :handle_0012,
    0x0013 => :handle_0013,
    0x0020 => :handle_0020,
    0x0021 => :handle_0021,
    0x0022 => :handle_0022,
    0x0023 => :handle_0023,
    0x0025 => :handle_0025,
    0x0026 => :handle_0026,
    0x0027 => :handle_0027,
    0x002C => :handle_002c,
    0x002E => :handle_002e,
    0x002F => :handle_002f,
    0x2013 => :handle_2013,
    0x2001 => :handle_2001,
    0x2002 => :handle_2002,
    0x2009 => :handle_2009,
    0x200A => :handle_200A,
    0x2010 => :handle_2010,
    0xFFFF => :handle_ffff,
  }.freeze

  def dispatch(state, cmd, commands)
    h = HANDLERS[cmd.code]
    if h
      send(h, state, cmd, self, commands)
    else
      # 未知指令: 仅前进 PC (很多指令如 0x0042, 0x1010 不需要特殊处理)
      state.pc += 1
      true
    end
  end

  # ==================================================================
  # 指令实现方法
  # ==================================================================

  include Module.new {
    define_method(:handle_0001) { |state, cmd, mgr, cmds|
      mode = cmd.params[0]; var_id = cmd.params[1]
      state.tbl_c4[var_id] = 0 if mode == 2
      state.tbl_c8[var_id] = 0 if mode == 4
      state.pc += 1; true
    }

    define_method(:handle_0003) { |state, cmd, mgr, cmds|
      mode = cmd.params[0]; var_id = cmd.params[1]
      val = var_id
      val = state.read_c4(var_id) if mode == 2
      val = state.read_c8(var_id) if mode == 4
      result = (val == 0)
      old_pc = state.pc
      state.regB = state.regB & 0xFE
      state.regB |= 1 if result
      state.pc += 1

      # 外部变量: fork 另一方分支
      if mode == 2 && mgr.external_vars.include?(var_id)
        fork_state = state.clone
        fork_state.pc = old_pc + 1  # 跳过比较指令
        fork_state.regB = fork_state.regB & 0xFE
        fork_state.regB |= (result ? 0 : 1)
        mgr.push(fork_state)
      end
      true
    }

    define_method(:handle_0005) { |state, cmd, mgr, cmds|
      mode = cmd.params[0]; var_id = cmd.params[1]; cmp_m = cmd.params[2]; cmp_v = cmd.params[3]
      if mode == 2
        l = state.read_c4(var_id); r = (cmp_m == 2) ? state.read_c4(cmp_v) : cmp_v
      elsif mode == 4
        l = state.read_c8(var_id); r = (cmp_m == 2) ? state.read_c4(cmp_v) : cmp_v
      else
        l = r = 0
      end
      result = (l == r)
      old_pc = state.pc
      state.regB = state.regB & 0xFE
      state.regB |= 1 if result
      state.pc += 1

      # 外部变量: fork 另一方分支
      if mode == 2 && mgr.external_vars.include?(var_id)
        fork_state = state.clone
        fork_state.pc = old_pc + 1  # 跳过比较指令
        fork_state.regB = fork_state.regB & 0xFE
        fork_state.regB |= (result ? 0 : 1)
        mgr.push(fork_state)
      end
      true
    }

    define_method(:handle_0008) { |state, cmd, mgr, cmds|
      mode = cmd.params[0]; var_id = cmd.params[1]
      state.tbl_c4[var_id] = state.read_c4(var_id) + 1 if mode == 2
      state.tbl_c8[var_id] = state.read_c8(var_id) + 1 if mode == 4
      state.pc += 1; true
    }

    define_method(:handle_0009) { |state, cmd, mgr, cmds|
      mode = cmd.params[0]; var_id = cmd.params[1]
      state.tbl_c4[var_id] = state.read_c4(var_id) - 1 if mode == 2
      state.tbl_c8[var_id] = state.read_c8(var_id) - 1 if mode == 4
      state.pc += 1; true
    }

    # 0x000A: RPN 表达式求值。目前仅处理性别检查固定模式
    # Pattern: 000A 0002 001D 0001 0002 0088 000B → c4[0x1D] < 2
    # 0x1D = 1 (男) → regA=1 → 0x0020 跳转; 0x1D = 0x23 (女) → regA=0 → fall through
    define_method(:handle_000A) { |state, cmd, mgr, cmds|
      if cmd.params.size >= 6 &&
         cmd.params[0] == 0x0002 && cmd.params[1] == 0x001D &&
         cmd.params[2] == 0x0001 && cmd.params[3] == 0x0002 &&
         cmd.params[4] == 0x0088 && cmd.params[5] == 0x000B
        f = state.clone
        f.regA = 1    # male path: c4[0x1D]=1 < 2 → jumps at 0x0020
        f.pc = state.pc + 1
        mgr.push(f)
        state.regA = 0  # female path: c4[0x1D]=0x23 >= 2 → falls through
      end
      state.pc += 1
      true
    }

    define_method(:handle_0010) { |state, cmd, mgr, cmds|
      state.tbl_c4[cmd.params[0]] = cmd.params[1]; state.pc += 1; true
    }

    define_method(:handle_0011) { |state, cmd, mgr, cmds|
      state.tbl_c4[cmd.params[0]] = state.read_c4(cmd.params[1]); state.pc += 1; true
    }

    define_method(:handle_0012) { |state, cmd, mgr, cmds|
      state.tbl_c8[cmd.params[0]] = cmd.params[1]; state.pc += 1; true
    }

    define_method(:handle_0013) { |state, cmd, mgr, cmds|
      state.tbl_c8[cmd.params[0]] = state.read_c4(cmd.params[1]); state.pc += 1; true
    }

    define_method(:handle_0020) { |state, cmd, mgr, cmds|
      # 0x20: RegShortA == 0 → fall through; else → jump
      if state.regA == 0
        state.pc += 1; true
      else
        t = mgr.index_to_pc[cmd.params[0]]
        return false unless t
        state.pc = t; true
      end
    }

    define_method(:handle_0021) { |state, cmd, mgr, cmds|
      # 0x21: RegByteB & 1 == 0 → fall through; == 1 → jump
      if (state.regB & 1) != 0
        t = mgr.index_to_pc[cmd.params[0]]
        return false unless t
        state.pc = t; true
      else
        state.pc += 1; true
      end
    }

    define_method(:handle_0022) { |state, cmd, mgr, cmds|
      # 0x22: RegByteB & 1 != 0 → fall through; == 0 → jump (opposite of 0x21!)
      if (state.regB & 1) == 0
        t = mgr.index_to_pc[cmd.params[0]]
        return false unless t
        state.pc = t; true
      else
        state.pc += 1; true
      end
    }

    define_method(:handle_0023) { |state, cmd, mgr, cmds|
      t = mgr.index_to_pc[cmd.params[0]]
      return false unless t
      state.pc = t; true
    }

    define_method(:handle_0025) { |state, cmd, mgr, cmds|
      t = mgr.index_to_pc[cmd.params[0]]
      return false unless t
      state.stack.push(state.pc + 1)
      state.pc = t; true
    }

    define_method(:handle_0026) { |state, cmd, mgr, cmds|
      return false if state.stack.empty?
      state.pc = state.stack.pop; true
    }

    define_method(:handle_0027) { |state, cmd, mgr, cmds|
      mode = cmd.params[0]; var_id = cmd.params[1]
      case_val = (mode == 4) ? state.read_c8(var_id) : state.read_c4(var_id)

      # 外部变量: 探索性 fork
      if mode == 2 && mgr.external_vars.include?(var_id)
        for i in 4...cmd.params.size - 1
          t = cmd.params[i]
          mgr.fork(state, cmds, t) if t != 0  # 全部 fork
        end
        t0 = cmd.params[4]
        if t0 != 0 && mgr.index_to_pc[t0]
          state.pc = mgr.index_to_pc[t0]
        else
          state.pc += 1
        end
        return true
      end

      if case_val >= 0 && (4 + case_val) < cmd.params.size - 1
        target = cmd.params[4 + case_val]
        if target != 0
          t = mgr.index_to_pc[target]
          if t
            state.pc = t; return true
          end
        end
      end
      # 未知/无效 case: fork 所有分支 + 当前路径走默认
      for i in 4...cmd.params.size - 1
        t = cmd.params[i]
        mgr.fork(state, cmds, t) if t != 0
      end
      t0 = cmd.params[4]
      if t0 != 0 && mgr.index_to_pc[t0]
        state.pc = mgr.index_to_pc[t0]
      else
        state.pc += 1
      end
      true
    }

    define_method(:handle_002c) { |state, cmd, mgr, cmds|
      $pending_scripts.push([cmd.params[0], state.clone])
      false
    }

    define_method(:handle_002e) { |state, cmd, mgr, cmds|
      state.dialog_file_id = -1; state.pc += 1; true
    }

    define_method(:handle_002f) { |state, cmd, mgr, cmds|
      state.dialog_file_id = cmd.params[0]; state.pc += 1; true
    }

    define_method(:handle_2013) { |state, cmd, mgr, cmds|
      state.pending_dialogs.push([cmd.index, cmd.params[0]])
      state.pending_speaker_info.push({
        left: state.left_face,
        right: state.right_face,
        side: state.speaker_side
      })
      state.pc += 1; true
    }

    # 0x2001: 加载角色到左边
    define_method(:handle_2001) { |state, cmd, mgr, cmds|
      state.left_face = cmd.params[0] if cmd.params.size >= 1
      state.pc += 1; true
    }

    # 0x2002: 加载角色到右边
    define_method(:handle_2002) { |state, cmd, mgr, cmds|
      state.right_face = cmd.params[0] if cmd.params.size >= 1
      state.pc += 1; true
    }

    # 0x2009: 隐藏右边角色
    define_method(:handle_2009) { |state, cmd, mgr, cmds|
      state.right_face = -1
      state.pc += 1; true
    }

    # 0x200A: 隐藏左边角色
    define_method(:handle_200A) { |state, cmd, mgr, cmds|
      state.left_face = -1
      state.pc += 1; true
    }

    # 0x2010: 设置对话框格式 (0=左侧说话/对话框在右, 1=右侧说话/对话框在左)
    define_method(:handle_2010) { |state, cmd, mgr, cmds|
      state.speaker_side = cmd.params[0] if cmd.params.size >= 1
      state.pc += 1; true
    }

    define_method(:handle_ffff) { |state, cmd, mgr, cmds|
      mgr.flush_dialogs(state, 0) unless state.pending_dialogs.empty?
      false
    }
  }
end

# ---------------------------------------------------------
# 递归入口
# ---------------------------------------------------------

$pending_scripts = []
$loaded_states = {}  # script_id => Set of state hashes
$depth = 0
$max_depth = 10

def analyze_script(script_id, parent_state = nil)
  # 防止无限递归: 同状态不重复加载
  state_sig = parent_state ? parent_state.state_key : :initial
  $loaded_states[script_id] ||= Set.new
  if $loaded_states[script_id].include?(state_sig) || $depth > $max_depth
    return {}
  end
  $loaded_states[script_id].add(state_sig)
  $depth += 1

  fn = "../../exported/CM1100.DAT_#{script_id}"
  unless File.exist?(fn)
    puts "File not found: #{fn}"
    return
  end

  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  debug = false  # 调试 id==3 (太长了，先关掉)
  dialogs = manager.run(script_id, commands, parent_state, debug)

  # 处理脚本内部 0x002C 触发的子脚本
  while !$pending_scripts.empty?
    child_id, child_state = $pending_scripts.shift
    analyze_script(child_id, child_state)
  end

  $depth -= 1
  dialogs
end

# ---------------------------------------------------------
# 通用分析入口: 从 PC=127 (主 switch) 开始, 模拟脚本 1 init 后的状态
# ---------------------------------------------------------

def analyze_script_static(target_id, extra_vars = {}, extra_external = nil)
  fn = "../../exported/CM1100.DAT_#{target_id}"
  unless File.exist?(fn)
    puts "File not found: #{fn}"
    return {}
  end

  commands = parse_commands(fn).to_a
  manager = ExecManager.new
  manager.index_to_pc = {}
  commands.each_with_index { |c, i| manager.index_to_pc[c.index] = i }
  
  # 外部变量列表 (可通过参数扩展)
  manager.external_vars = VMState::EXTERNAL_VARS.dup
  manager.external_vars += extra_external if extra_external

  state = VMState.new(target_id)
  state.tbl_c4[0xF8] = 3
  state.tbl_c4[0xF9] = 0xA
  state.tbl_c4[0xFA] = 0x0D
  state.tbl_c4[0xFB] = 0
  state.tbl_c4[0xFC] = 0
  state.tbl_c4[0xC4] = 4
  state.tbl_c4[0xC3] = 4
  extra_vars.each { |k, v| state.tbl_c4[k] = v }

  idx = manager.index_to_pc[0x012E]
  state.pc = idx || 127
  manager.push(state)

  run_manager(manager, commands, target_id)
  manager.dialogs
end

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

# ---------------------------------------------------------
# 输出分析结果
# ---------------------------------------------------------

def output_results(dialogs, commands, tag)
  puts
  puts "=== Results (#{tag}) ==="
  puts "Dialog file IDs with content: #{dialogs.keys.sort.join(', ')}"
  $dialog_strs = {}

  # 统计 next_cmd 分布
  next_cmd_stats = Hash.new(0)

  dialogs.each do |fid, groups|
    groups = groups.to_a
    puts "  File 0x#{sprintf('%02X', fid)}: #{groups.size} dialog groups"

    dialog_fn = "../../exported/CM1100.DAT_#{fid + 0x29}"
    if File.exist?(dialog_fn)
      contents = IO.binread(dialog_fn)
      len = contents.unpack1("S!<")
      indices = contents.unpack("S!<#{len}")

      File.open("#{tag}_fid#{sprintf('%02X', fid)}.txt", "w") do |f|
        sorted_groups = groups.sort_by { |g| g[:texts].first || 0 }
        group_no = 0
        sorted_groups.each do |g|
          group_no += 1
          # 统计 next_cmd
          nc = g[:next_cmd] || 0
          next_cmd_stats[nc] += 1

          # speaker info
          left = g[:left_face] || -1
          right = g[:right_face] || -1
          side = g[:speaker_side] || 0
          speaker_id = side == 0 ? left : right
          speaker_str = speaker_id >= 0 ? sprintf("char_%04X", speaker_id) : "none"
          side_str = side == 0 ? "left" : "right"
          next_cmd_str = sprintf("next=%04X", nc)

          f.puts "--- Group #{group_no} [#{side_str}:#{speaker_str} #{next_cmd_str}] ---"

          g[:texts].each do |text_idx|
            if text_idx < indices.size
              start = indices[text_idx]
              str = ""
              pos = 0
              loop do
                break if contents[start * 2 + pos] == "\x0" && contents[start * 2 + pos + 1] == "\x0"
                str += contents[start * 2 + pos] + contents[start * 2 + pos + 1]
                pos += 2
                break if pos > 200
              end
              begin
                f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', text_idx)}] #{str.force_encoding("shift_jis").encode("utf-8")}"
              rescue
                f.puts "[FID:#{sprintf('%02X', fid)}, TEXT:#{sprintf('%04X', text_idx)}] (encoding error)"
              end
            end
          end
          f.puts ""
        end
      end

      all_ids = Set.new
      groups.each { |g| g[:texts].each { |t| all_ids.add(t) } }
      puts "    Unique text IDs: #{all_ids.size}"
    end
  end

  # 打印 next_cmd 统计
  puts
  puts "  next_cmd statistics (command after 0x2013 group):"
  next_cmd_stats.sort.each do |cmd, count|
    desc = case cmd
    when 0x2012 then "2012 (normal dialog)"
    when 0x2015 then "2015 (waiting for choice)"
    when 0x201D then "201D (black screen cutscene)"
    when 0xFFFF then "FFFF (script end)"
    when 0 then "0 (path end)"
    else sprintf("unknown")
    end
    puts "    #{sprintf('%04X', cmd)}: #{count} groups - #{desc}"
  end

  all_2013 = commands.select { |c| c.code == 0x2013 }
  total_ids = 0
  dialogs.each do |_, groups|
    ids = Set.new
    groups.each { |g| g[:texts].each { |t| ids.add(t) } }
    total_ids += ids.size
  end
  puts "  Total 2013 in script: #{all_2013.size}, Unique text IDs found: #{total_ids}"
end

# ---------------------------------------------------------
# 主入口
# ---------------------------------------------------------

if __FILE__ == $0
  target_id = (ARGV[0] || 3).to_i
  puts "=== Analyzing script #{target_id} ==="
  puts

  commands = parse_commands("../../exported/CM1100.DAT_#{target_id}").to_a
  dialogs = analyze_script_static(target_id)
  output_results(dialogs, commands, "dialog#{target_id}")
end
