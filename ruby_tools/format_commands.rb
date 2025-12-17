require "./commands_parse_tools"
def format_commands(fn)
  File.open("#{fn}_commands.txt", "w") do |f|
    parse_commands(fn).each do |c|
      f.puts sprintf("%04X: %04X %s", c.index, c.code, c.params.map{|a| sprintf("%04X", a)}.join(" "))
    end
  end
end
4.upto(40) do |a|
format_commands("../exported/CM1100.DAT_#{a}")
end
