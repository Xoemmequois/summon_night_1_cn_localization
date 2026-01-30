# frozen_string_literal: true

require "json"

SRT_PATH  = "out_translated.srt"
JSON_PATH = "zh_CN.json"

def time_to_ms(ts)
  # "HH:MM:SS,mmm"
  h, m, rest = ts.split(":")
  s, ms = rest.split(",")
  (h.to_i * 3600 + m.to_i * 60 + s.to_i) * 1000 + ms.to_i
end

def fmt_ms(ms)
  # 至少 4 位，不够左侧补 0；超过 4 位则原样输出
  ms.to_i.to_s.rjust(4, "0")
end

def build_key(start_ts, end_ts)
  "#{fmt_ms(time_to_ms(start_ts))}-#{fmt_ms(time_to_ms(end_ts))}"
end

def parse_srt(path)
  text = File.read(path, mode: "r:BOM|UTF-8")
  lines = text.lines.map(&:rstrip)

  items = []
  i = 0

  while i < lines.length
    line = lines[i]

    # 跳过空行
    if line.empty?
      i += 1
      next
    end

    # 可选的序号行（纯数字）
    if line.match?(/\A\d+\z/)
      i += 1
      line = lines[i]
    end

    # 时间轴行
    if line && (m = line.match(/\A(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})/))
      start_ts, end_ts = m[1], m[2]
      i += 1

      # 收集字幕正文（直到空行）
      buf = []
      while i < lines.length && !lines[i].empty?
        buf << lines[i]
        i += 1
      end

      translation = buf.join("\n").strip
      items << [build_key(start_ts, end_ts), translation]
    else
      # 不是我们关心的行，继续走
      i += 1
    end
  end

  items
end

# 1) 从 SRT 读出：key => translation
srt_pairs = parse_srt(SRT_PATH)
srt_map = srt_pairs.to_h

# 2) 读取 JSON 并更新 translation
json_text = File.read(JSON_PATH, mode: "r:BOM|UTF-8")
data = JSON.parse(json_text)

updated = 0

case data
when Array
  data.each do |row|
    next unless row.is_a?(Hash)
    k = row["key"]
    next unless k && srt_map.key?(k)

    row["translation"] = srt_map[k]
    updated += 1
  end
else
  raise "Unsupported JSON root type: #{data.class}"
end

# 3) 写回（保持 UTF-8，不转义中文）
File.write(JSON_PATH, JSON.pretty_generate(data, ascii_only: false) + "\n", mode: "w:UTF-8")

puts "Done. Updated #{updated} entries."
