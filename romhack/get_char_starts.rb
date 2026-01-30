$CM1100 = IO.binread("rom/CM1100.DAT")

$starts = {}

def get_subcontent(id)
  arr = $CM1100[0x10 + id * 4, 4].unpack("S!<S!<")
  offset = arr[0]
  len = arr[1]
  return $CM1100[offset * 0x800, len * 0x800]
end
def parse_dialog_contents(id)
  contents = get_subcontent(id + 0x29)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  indices.each do |start|
    index = 0
    loop do
      break if contents[start * 2 + index] == "\x0" && contents[start * 2 + index + 1] == "\x0"
      $starts[contents[start * 2 + index]] = 1
      index += 2
    end
  end
end
1.upto(145) do |id|
  parse_dialog_contents(id)
end
p $starts.keys.sort