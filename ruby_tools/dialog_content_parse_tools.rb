require "./commands_parse_tools"
require "json"

def parse_dialog_contents(id)
  p id
  fn = "../exported/CM1100.DAT_#{id + 0x29}"
  contents = IO.binread(fn)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  strs = []
  p "S!<#{len}"
  indices.each do |start|
    str = ""
    index = 0
    loop do
      break if contents[start * 2 + index] == "\x0" && contents[start * 2 + index + 1] == "\x0"
        p "#{start}, #{index}, #{start * 2 + index}"
      str += contents[start * 2 + index] + contents[start * 2 + index + 1]
      index += 2
    end
    c = str.force_encoding("shift_jis").encode("utf-8")
    strs.push str
  end
  File.write("#{fn}_contents.json", strs.to_json)
end

def getContents(fn)
  parse_commands(fn).each do |c|
    if c.code == 0x002F
      parse_dialog_contents c.params[0]
    end
  end
end
