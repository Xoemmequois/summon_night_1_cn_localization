require "./commands_parse_tools"

$VARID = {}
#old [0x19, 0x95, 0x99, 0xc6, 0xf8, 0xf9, 0xfa]
#new [0x19, 0x1b, 0x93, 0x95, 0x99, 0xc5, 0xc6, 0xc8, 0xf8, 0xf9, 0xfa]
#0x19 是玩家选择的选项，不追踪其值
#合理推断 0x1B 可能也是会被外部改变的变量，这里也不追踪其值
[0x93, 0x95, 0x99, 0xc5, 0xc6, 0xc8, 0xf8, 0xf9, 0xfa, 0xdc, 0xdd, 0xde, 0xdf].each_with_index do |a,i|
  $VARID[a] = i
end
$tmp = File.new("debug_tmp.txt", "w")

class Context
  attr :stack
  attr :vars, true
  def initialize(context)
    if(context)
      @stack = context.stack.clone
      @vars = context.vars.clone
    else
      @stack = []
      @vars = [0] * $VARID.size
    end
  end

  def output_vars
    @vars.to_s
  end

  def hash
    return @stack.hash ^ @vars.hash
  end

  def assign(n,v)
    if $VARID[n]
      @vars[$VARID[n]] = v
      return true
    end
    false
  end

  def getVars(n)
    return @vars[$VARID[n]] if $VARID[n]
    return -1
  end

  def eql?(other)
    return false unless other.is_a? Context
    return @stack.eql?(other.stack) && @vars.eql?(other.vars)
  end

end

class RouteManager

  attr :groups
  attr :unknown
  attr :handled
  attr :nextCommands

  def initialize
    @routes = []
    @visited = {}
    @index_to_id = {}
    @groups = []
    @unknown = {}
    @handled = {}
    @nextCommands = {}
  end

  def addNextCommandsList(id, context)
    old = @nextCommands[id]
    if old
      if not old.eql? context.vars
        puts "Command List With Multiple Vars: #{id} #{old} #{context.vars}"
      end
    end
    @nextCommands[id] = context.vars.clone
  end

  def addDialog(dialogs, dialog_index)
    if(dialog_index == -1)
      #puts "Dialog With unknown index #{dialogs[0][0].to_s(16)}"
      @unknown[dialogs[0][0]] = 1
      return
    end
    @handled[dialogs[0][0]] = 1
    dialogs.each do |arr|
      command_index = arr[0]
      dialog_id = arr[1]
      if @index_to_id[command_index] && @index_to_id[command_index] != dialog_index
        puts "command #{command_index} have different dialog index #{dialog_index} #{@index_to_id[command_index]}"
      end
      @index_to_id[command_index] = dialog_index
    end
    @groups.push dialogs.map{|d| [dialog_index, d[1]]}
  end

  def visited?(context, pc)
    arr = @visited[context]
    return false if arr.nil?
    return !!arr[pc]
  end

  def addRoute(route)
    @routes.push route
  end

  attr :debug, true

  def next(data)
    return false if @routes.empty?
    route = @routes[0]
    unless route.next(data)
      @routes.shift
      $tmp.puts route.history.map{|a| a.to_s(16)}.inspect if @debug
      #puts "Route End #{@visited.length}"
    end
    true
  end


  def markVisited(context, pc)

    if not @visited[context]
      context = Context.new(context)
      @visited[context] = []
    end
    @visited[context][pc] = 1
  end
end

class Route
  attr :context
  attr :dialog_index
  attr :leftFace
  attr :rightFace
  attr :dialogs
  attr :history
  def initialize(pc, route, manager)

    if route
      @history = route.history.clone
      @context = Context.new(route.context)
      @dialog_index = route.dialog_index
      @leftFace = route.leftFace
      @rightFace = route.rightFace
    else
      @history = []
      @context = Context.new(nil)
      @dialog_index = -1
      @leftFace = -1
      @rightFace = -1
    end
    @dialogs = []
    @manager = manager
    @pc = pc
  end

  def next(data)
    command = data[@pc]
    if(command.nil?)
      puts "Invalid pc #{@pc}"
    end
    @history.push command.index
    #p sprintf("%04d: %04X %04X", command.index, command.code, command.params[0] ? command.params[0] : 0)
    if not @dialogs.empty? and command.code != 0x2013
      @manager.addDialog(@dialogs, @dialog_index)
      @dialogs.clear
    end

    return false if @manager.visited? @context, @pc
    @manager.markVisited @context, @pc

    case command.code
    when 0x0001
      @context.assign(command.params[1], 0) if command.params[0] == 2
    when 0x0008, 0x0009
      delta = command.code == 0x0008 ? 1 : -1
      @context.assign(command.params[1], @context.getVars(command.params[1]) + delta) if command.params[0] == 2
    when 0x0010
      @context.assign(command.params[0], command.params[1])
    when 0x001A, 0x001B
      throw RuntimeError.new("command #{sprintf("%04X", command.code)} At #{command.index}")
    when 0x0020, 0x0021, 0x0022
      @manager.addRoute Route.new($index_to_pc[command.params[0]], self, @manager)
    when 0x0023
      @pc = $index_to_pc[command.params[0]]
      return true
    when 0x0025
      @context.stack.push @pc + 1
      @pc = $index_to_pc[command.params[0]]
      return true
    when 0x0026
      p "#{@context.stack.map{|a| data[a].index.to_s(16)}} Pop At #{command.index.to_s(16)}" if @context.stack.include? 508
      if @context.stack.empty?
        puts "Mismatched call and return"
        return false
      end
      @pc = @context.stack.pop
      return true
    when 0x0027
      vari = @context.getVars(command.params[1])
      if(command.params[0] == 2 && vari >= 0)
        @pc = $index_to_pc[command.params[4 + vari]]
        return true
      end
      command.params[5..-2].each do |npc|
        @manager.addRoute Route.new($index_to_pc[npc], self, @manager)
      end
      @pc = $index_to_pc[command.params[4]]
      return true
    when 0x002C
      @manager.addNextCommandsList(command.params[0], @context)
      puts "Load #{command.params[0]} At #{command.index} DialogIndex #{@dialog_index} #{@context.output_vars}"
      return false
    when 0x002E
      puts "Load Dialog Index By Variable"
      @dialog_index = -1
    when 0x002F
      @dialog_index = command.params[0]
    when 0x2013
      @dialogs.push [command.index, command.params[0]]
    when 0xFFFF
      return false
    end
    @pc += 1
    true
  end
end
#p commands.length
#p $index_to_pc

#p manager.groups

def parse_dialog_contents(id)
  fn = "../exported/CM1100.DAT_#{id + 0x29}"
  contents = IO.binread(fn)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  strs = []
  indices.each do |start|
    str = ""
    index = 0
    loop do
      break if contents[start * 2 + index] == "\x0" && contents[start * 2 + index + 1] == "\x0"
      str += contents[start * 2 + index] + contents[start * 2 + index + 1]
      index += 2
    end
    c = str.force_encoding("shift_jis").encode("utf-8")
    strs.push c
  end
  return strs
end

$strs = {}
def write_dialogs(groups, id)
  File.open("dialog#{id}.txt", "w") do |f|
    groups.each do |group|
      dialogContent = ""
      group.each do |arr|
        fid = arr[0]
        did = arr[1]
        unless $strs[fid]
          $strs[fid] = parse_dialog_contents(fid)
        end
        dialogContent += $strs[fid][did]
        dialogContent += "\n"
      end
      f.puts dialogContent
      f.puts
    end
  end
end

$handled = {}
def handle(id, vars)
  if($handled[id])
    puts "#{id} Handled Multiple times"
    return
  end
  puts "Handling #{id}"
  $handled[id] = 1
  commands = parse_commands("../exported/CM1100.DAT_#{id}").to_a
  $index_to_pc = {}
  commands.each_with_index do |c, i|
    $index_to_pc[c.index] = i
  end
  manager = RouteManager.new
  manager.debug = true if id == 2
  initRoute = Route.new(127, nil, manager)
  #initRoute.context.vars = vars

  initRoute.context.assign(0xF8, 3)
  initRoute.context.assign(0xF9, 0xA)
  manager.addRoute(initRoute)
  while manager.next(commands)
  end
  write_dialogs(manager.groups, id)
  p manager.unknown.keys.map{|a| sprintf("%04X", a)}
  p manager.groups
  manager.nextCommands.each do |k,v|
    handle(k, v)
  end
end
c = Context.new nil
c.assign(0xF8, 3)
c.assign(0xF9, 0xA)
handle(1, c.vars)
