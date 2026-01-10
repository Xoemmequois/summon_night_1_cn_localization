require 'gettext/po'

$CM1100 = IO.binread("rom/CM1100.DAT")


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
  strs = []
  p "S!<#{len}"
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
  #File.write("#{id}_contents.json", strs.to_json)
  return strs
end
# 1. 创建一个新的 PO 对象
po = GetText::PO.new
=begin
# 2. 添加元数据（Header）
po.set_value("", "Project-Id-Version: Summon Night (CN) 1.0\n" \
                 "Content-Type: text/plain; charset=UTF-8\n" \
                 "Content-Transfer-Encoding: 8bit\n")
=end

1.upto(145) do |id|
  strs = parse_dialog_contents(id)
  strs.each_with_index do |str, i|
    next if str.empty?
    entry = GetText::POEntry.new(:msgctxt)
    entry.msgid = str
    entry.msgstr = ""

    entry.msgctxt = sprintf("%04d-%04d", id, i)
    entry.references = [sprintf("%04d:%04d", id, i)]

    po[sprintf("%04d-%04d\004%s", id, i, str)] = entry # 在 GetText 内部，Key 的格式通常是 context + \004 + msgid
  end
end



File.write("zh_CN.po", po.to_s)
