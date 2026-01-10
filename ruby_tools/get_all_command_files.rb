require "./commands_parse_tools"

$handled = {}
$hash = {}
$hash2 = {}
$dialogs = {}
def handle(id)
  return if $handled[id]
  $handled[id] = 1
  parse_commands("../exported/CM1100.DAT_#{id}").each do |c|
    if(c.code == 0x0010)
      $hash[c.params[0]] = 1
    end
    if(c.code == 0x002F)
      $dialogs[c.params[0]] = 1
    end
    if(c.code == 0x0027 && c.params[0] == 2)
      $hash2[c.params[1]] = 1
    end
    if(c.code == 0x0001 || c.code == 0x0008 || c.code == 0x0009)
      $hash[c.params[1]] = 1 if c.params[0] == 2
    end
    if c.code == 0x002c
      handle(c.params[0])
    end
  end
end

handle(1)
p $handled.keys.sort
p "Dialogs #{$dialogs.keys.sort}"
puts ($hash.keys & $hash2.keys).sort.map{|a| sprintf("0x%x", a)}.join(", ")
