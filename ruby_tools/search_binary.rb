# frozen_string_literal: true

# 定义要搜索的二进制模式
# \x3c 是 0x3c
# . 是匹配任何一个字符（字节）
# {3} 表示重复前一个模式 3 次
# /n 标志 (相当于 /m 并且 /e A) 用于在 Ruby 1.9+ 中将字符串视为 ASCII-8BIT (二进制) 数据
# 这样 . 就会匹配任何字节，包括 NULL 字节 (\x00)
# ASCII-8BIT 编码确保数据被视为原始字节
PATTERN = /\x3c.{3}\x8c.{3}\x3c.{3}\x03.{3}\xac/n.freeze

# 检查命令行参数
if ARGV.empty?
  puts "用法: ruby search_binary.rb <二进制文件路径>"
  exit 1
end

file_path = ARGV[0]

# 检查文件是否存在
unless File.exist?(file_path)
  puts "错误: 文件未找到: #{file_path}"
  exit 1
end

begin
  # 以二进制模式 ('rb') 读取文件内容，并指定 ASCII-8BIT 编码
  # 尽管 'rb' 通常会设置正确的编码，但明确指定可以确保兼容性
  content = File.open(file_path, 'rb', encoding: 'ASCII-8BIT') { |f| f.read }

  puts "正在文件 '#{file_path}' 中搜索模式..."

  # 使用 String#scan 查找所有匹配项
  matches = content.to_enum(:scan, PATTERN).map { Regexp.last_match }

  if matches.empty?
    puts "未找到匹配的模式。"
  else
    puts "找到 #{matches.size} 个匹配项:"
    matches.each do |match|
      # match.begin(0) 返回匹配项在字符串中的起始字节偏移量
      offset = match.begin(0)
      
      # 打印匹配项的十六进制表示，以帮助验证
      # 使用 #unpack('H*') 将二进制字符串转换为十六进制字符串
      hex_data = match[0].unpack('H*').first 
      
      puts "  偏移量: 0x#{(offset + 0x80010000 - 0x800).to_s(16).upcase} (十进制: #{offset})"
      puts "  数据:   #{hex_data}"
      puts "  长度:   #{match[0].length} 字节"
      puts "---"
    end
  end

rescue => e
  puts "处理文件时发生错误: #{e.message}"
end