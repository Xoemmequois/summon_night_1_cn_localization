require 'rexml/document'
require 'rexml/formatters/pretty'

$CM1100 = IO.binread("rom/CM1100.DAT")

$srt = File.new("out.srt", "w")

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
  indices.each do |start|
    str = ""
    index = 0
    loop do
      break if contents[start * 2 + index] == "\x0" && contents[start * 2 + index + 1] == "\x0"
      str += contents[start * 2 + index] + contents[start * 2 + index + 1]
      index += 2
    end
    str.gsub!("\x40\x00\x6E\x00", "\x40\x6E")
    c = str.force_encoding("shift_jis").encode("utf-8")
    strs.push c
  end
  #File.write("#{id}_contents.json", strs.to_json)
  return strs
end
$index = 1
def build_xliff
  doc = REXML::Document.new
  xliff = doc.add_element('xliff')
  xliff.add_attribute('version', '1.2')

  1.upto(145) do |id|
    file = xliff.add_element('file')
    file.add_attribute('original', sprintf('CM1100.DAT:%04d', id))
    file.add_attribute('source-language', 'ja')
    file.add_attribute('target-language', 'zh-CN')
    file.add_attribute('datatype', 'plaintext')
    body = file.add_element('body')
    strs = parse_dialog_contents(id)
    strs.each_with_index do |str, i|
      next if str.empty?
      t = sprintf("00:00:00,%03d --> 00:00:00,%03d", id, i)
      $srt.puts $index
      $srt.puts t
      $srt.puts str
      $srt.puts
      $index += 1
      

      ctx = sprintf('%04d-%04d', id, i)
      unit = body.add_element('trans-unit')
      unit.add_attribute('id', ctx)
      unit.add_element('source').text = str
      unit.add_element('target').text = ''
    end
  end

  formatter = REXML::Formatters::Pretty.new
  File.open('zh_CN.xlf', 'w') { |io| formatter.write(doc, io) }
end
build_xliff