require "./commands_parse_tools"

$handled = {}
$hash = {}
$hash2 = {}
def handle(id)
  return if $handled[id]
  $handled[id] = 1
  parse_commands("../exported/CM1100.DAT_#{id}").each do |c|
    if(c.code == 0x0010)
      $hash[c.params[0]] = 1
    end
    if(c.code == 0x0027 && c.params[0] == 2)
      $hash2[c.params[1]] = 1
    end
    if c.code == 0x002c
      handle(c.params[0])
    end
  end
end

handle(1)
p $handled.keys.sort
puts ($hash.keys & $hash2.keys).sort.map{|a| sprintf("0x%x", a)}.join(", ")
