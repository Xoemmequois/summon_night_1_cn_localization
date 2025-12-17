require "./commands_parse_tools"
require "json"
class DisjointSet

  def initialize
    @numCount = 0
    @parents = {}
  end

  def newValue
    v = @numCount += 1
    @parents[v] = v
    return v
  end

  def root(v)
    return v if @parents[v] == v
    @parents[v] = root(@parnets[v])
    return @parents[v]
  end

  def merge(v1, v2)
    @parents[root(v1)] = root(v2)
  end
end

$forceJumpCodes = {0x001A => 1, 0x0023 => 0, 0x0025 => 0}
$branchJumpCodes = {0x0020 => 0, 0x0021 => 0, 0x0022 => 0}
$clearStateCodes = {0x001B => 0, 0x0026 => 0, 0x0027 => 0, 0x002E => 0, 0x002F => 0}
$dialogCodes = {0x2013 => 1}

def process(fn)
  groups = {}
  hasDialogGroups = []
  set = DisjointSet.new
  currentValue = -1

  parse_commands(fn).each do |commands|
    if currentValue < 0
      if groups[commands.index]
        currentValue = groups[commands.index]
      else
        currentValue = set.newValue
      end
    end
    groups[commands.index] = currentValue

  end


end

def getParent(group_parents, dialog_groups, to_find)
  parents = group_parents[to_find]
  is_dialog_group = !!(dialog_groups[to_find])
  if parents.empty?
    if is_dialog_group
      return to_find
    else
      return nil
    end
  end
  first = getParent(group_parents, dialog_groups, parents[0])

end

def mark_inv(edges, group, group_parents, set)
  return if set[group]
  set[group] = 1

  arr = edges[group]
  if arr.nil?
    arr = []
    edges[group] = arr
  end

  arr.concat group_parents[group]
  arr.uniq!
  group_parents[group].each do |p|
    mark_inv(edges, p, group_parents,set)
  end
end

def process2(fn)
  # 先扫一遍找到所有的跳转地址
  # 遍历时每遇到一个跳转地址就创建一个新的group，如果是从上一个指令流转而来的，在parent中增加其父节点 同时把该位置的 pending_parents 也添加到自己的 parents 中
  # 遍历时遇到跳转指令，如果目标位置已经被遍历，目标位置的group的parent增加自身当前group
  # 如果目标位置没有被遍历，则提前记录在 pending_parents 中
  # 如果遇到了对话内容，将 group id 标记为对话id
  #
  # 以上流程结束后，对于每一个对话group，如果其有多个 parents root 是对话 id，让这些 parents root 合并
  #

  commands = parse_commands(fn).to_a
  jumpTargets = {}

  commands.each do |c|
    pi = $forceJumpCodes[c.code] || $branchJumpCodes[c.code]
    if pi
      j = c.params[pi]
      jumpTargets[j] = 1
    end
  end

  next_group_id = 1
  current_group_id = -1
  group_parents = []
  index_to_group = {}
  pending_parents = {}
  dialog_groups = {}
  next_group_parent_id = -1
  group_faces = {}
  isRight = 0
  commands.each do |c|
    if jumpTargets[c.index]
      old_group_id = current_group_id
      current_group_id = next_group_id
      next_group_id += 1
      parents = []
      parents += pending_parents[c.index] if pending_parents[c.index]
      parents.push old_group_id if old_group_id != -1
      parents.push next_group_parent_id if next_group_parent_id != -1
      group_parents[current_group_id] = parents
      index_to_group[c.index] = current_group_id
      parent_faces = parents.map{|a| group_faces[a]}.uniq
      if parent_faces.size > 1
        puts "Group #{current_group_id} MultiFace #{parent_faces}"
      end
      if parent_faces.size == 0
        group_faces[current_group_id] = [-1, -1]
      else
        group_faces[current_group_id] = parent_faces[0].dup
      end
    elsif current_group_id == -1
      current_group_id = next_group_id
      next_group_id += 1
      p = []
      p.push next_group_parent_id if next_group_parent_id != -1
      group_parents[current_group_id] = p
      index_to_group[c.index] = current_group_id
      parent_faces = p.map{|a| group_faces[a]}.uniq
      if parent_faces.size > 1
        puts "Group #{current_group_id} MultiFace #{parent_faces}"
      end
      if parent_faces.size == 0
        group_faces[current_group_id] = [-1, -1]
      else
        group_faces[current_group_id] = parent_faces[0].dup
      end
    end
    next_group_parent_id = -1
    if c.code == 0x2001
      group_faces[current_group_id][0] = c.params[0]
    elsif c.code == 0x2002
      group_faces[current_group_id][1] = c.params[0]
    elsif c.code == 0x2009
      group_faces[current_group_id][1] = -1
    elsif c.code == 0x200A
      group_faces[current_group_id][0] = -1
    end
    if c.code == 0x2010
      isRight = c.params[0] == 1
    end
    if $dialogCodes[c.code]
      arr = dialog_groups[current_group_id]
      if arr.nil?
        arr = []
        dialog_groups[current_group_id] = arr
      end
      arr.push [c, isRight ? group_faces[current_group_id][1] : group_faces[current_group_id][0]]
    end
    pid = $forceJumpCodes[c.code] || $branchJumpCodes[c.code]
    if pid
      addr = c.params[pid]
      if index_to_group[addr]
        group_parents[index_to_group[addr]].push current_group_id
      else
        pending_parent = pending_parents[addr]
        if pending_parent.nil?
          pending_parent = []
          pending_parents[addr] = pending_parent
        end
        pending_parent.push current_group_id
      end
      next_group_parent_id = current_group_id if $branchJumpCodes[c.code]
      current_group_id = -1
    end
    if $clearStateCodes[c.code]
      if c.code == 0x0027
        p sprintf("0027 %04X %04X", c.params[0], c.params[1])
      end
      current_group_id = -1
    end
  end

  edges = {}
  group_parents.each_with_index do |v, k|
    next if v.nil?
    v.each do |p|
      arr = edges[p]
      if arr.nil?
        arr = []
        edges[p] = arr
      end
      arr.push k
    end
  end
  set = []
  dialog_groups.each_key do |key|
      mark_inv(edges, key, group_parents, set)
  end

  dialog_big_group_id = {}
  visited = []
  to_visit = []
  big_gid = 0
  dialog_groups.each_key do |key|
    next if visited[key]
    to_visit.push key
    until to_visit.empty?
      node = to_visit.shift
      next if visited[node]
      visited[node] = 1
      dialog_big_group_id[node] = big_gid if dialog_groups[node]
      to_visit.concat edges[node] if edges[node]
    end
    big_gid += 1
  end
  groupedDialogs = {}
  dialog_groups.each do |key, value|
    gid = dialog_big_group_id[key]
    dialogs = groupedDialogs[gid]
    if dialogs.nil?
      dialogs = []
      groupedDialogs[gid] = dialogs
    end
    for i in 0...value.size
      if i != 0 and value[i][0].index - value[i - 1][0].index
        dialogs[-1][:content].push value[i][0].params[0]
      else
        arr = [value[i][0].params[0]]
        dialogs.push({:speaker => (value[i][1]), :content => arr})
      end
    end
  end

  File.write("#{fn}_dialogs.json", groupedDialogs.to_json)
  # p dialog_big_group_id.values
  # p dialog_big_group_id.values.uniq.size
  # p dialog_groups.size
  # [306, 305, 303, 302, 314].each do |g|
  #   index_to_group.each.filter{|a,b| b == g}.each{|a| p sprintf("%d -> %04X", a[1], a[0])}
  # end


end
process2("../exported/CM1100.DAT_1")
