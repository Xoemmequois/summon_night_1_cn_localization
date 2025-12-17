require "./commands_parse_tools"
$hash = {}
$hash2 = {}
parse_commands("../exported/CM1100.DAT_2").each do |a|
  if(a.code == 0x0010)
    $hash[a.params[0]] = 1
  end
  if(a.code == 0x0027 && a.params[0] == 2)
    $hash2[a.params[1]] = 1
  end
end
puts ($hash.keys & $hash2.keys).sort.map{|a| sprintf("0x%x", a)}.join(", ")
