arr = File.read("out_translated.srt").split(/\n\n+/)
$hash = {}
arr.each do |item|
    lines = item.split(/\n/)
    # Parse SRT time line from lines[1]
    time_line = lines[1]
    # Expected format: "HH:MM:SS,MMM --> HH:MM:SS,MMM"
    if time_line =~ /(\d{2}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2}):(\d{2}):(\d{2}),(\d{3})/
      start_hour, start_min, start_sec, start_msec = $1, $2, $3, $4
      end_hour, end_min, end_sec, end_msec = $5, $6, $7, $8
    end
    if start_hour.to_i != 0
        key = [start_msec.to_i, end_msec.to_i]
        $hash[key] = lines[2..-1].join("\n").strip
    end
end
p $hash

$CM1100 = IO.binread("rom/CM1100.DAT")

$srt = File.new("out.srt", "w")
$chars = {}

$char_index = 0
def get_next_char_id
    throw RuntimeError.new("too much characters") if $char_index >= 2560
    c = $char_index
    $char_index += 1
    if c < 256 * 3
        return [c / 256 + 0x85, c % 256].pack("C*")
    else
        c -= 256 * 3
        return [c / 256 + 0x99, c % 256].pack("C*")
    end

end

def get_subcontent(id)
  arr = $CM1100[0x10 + id * 4, 4].unpack("S!<S!<")
  offset = arr[0]
  len = arr[1]
  return [offset * 0x800, len * 0x800, $CM1100[offset * 0x800, len * 0x800]]
end

def convert_dialog_contents(id)
  content_start, content_len, contents = get_subcontent(id + 0x29)
  len = contents.unpack1("S!<")
  indices = contents.unpack("S!<#{len}")
  strs = []

  indices.each_with_index do |start, i|
    str = ""
    index = 0
    loop do
      break if contents[start * 2 + index] == "\x0" && contents[start * 2 + index + 1] == "\x0"
      str += contents[start * 2 + index] + contents[start * 2 + index + 1]
      index += 2
    end
    if $hash[[id, i]]
        str = ""
        $hash[[id, i]].each_char do |char|
            if char == "@"
                str += "\x40\x00"  
                next
            end
            if char == "n"
                str += "\x6E\x00"
                next
            end
            unless $chars[char]
                $chars[char] = get_next_char_id()
            end
            str += $chars[char] 
        end
        strs.push str
    else
        strs.push str
    end
    #str.gsub!("\x40\x00\x6E\x00", "\x40\x6E")
    #c = str.force_encoding("shift_jis").encode("utf-8")
    #strs.push c
  end
  #File.write("#{id}_contents.json", strs.to_json)
  str_start = indices[0]
  new_indices = []
  new_contents = ""
  strs.each_with_index do |str, i|
    new_contents += [str_start].pack("S<")
    str_start += str.bytesize / 2 + 1
  end
  #p indices.length, strs.length, new_contents.length
  strs.each do |str|
    new_contents += str
    new_contents += "\x00\x00"
  end
  throw RuntimeError.new("new content has larger size #{id}") if new_contents.length > contents.length
  new_contents = new_contents.ljust(contents.length, "\x00")
  p content_start.to_s(16), new_contents.length.to_s(16)
  $CM1100[content_start, new_contents.length] = new_contents
end
1.upto(145) do |i|
    convert_dialog_contents(i)
end
IO.binwrite("rom/CM1100.DAT.mod", $CM1100)
p $chars