dynamic = File.read("../command_1.txt")
static = File.read("../exported/CM1100.DAT_1_commands.txt")
$hash = {}
static.each_line do |line|
  if line =~ /^([A-F0-9]{4})\:\ ([A-F0-9]{4})/
    $hash[$1.to_i(16)] = $2.to_i(16)
  end
end

dynamic.each_line do |line|
  if line =~ /^([0-9])\:\ ([A-F0-9]{4})/
    index = $1.to_i
    if $hash[index] != $2.to_i(16)
      puts "Mismatch At #{index.to_s(16)}"
    end
  end
end
