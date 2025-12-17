def compare_binary_files(file1_path, file2_path, start_offset, end_offset)
  # 检查文件是否存在
  unless File.exist?(file1_path) && File.exist?(file2_path)
    puts "错误：文件 #{file1_path} 或 #{file2_path} 不存在。"
    return
  end

  # 读取文件内容
  begin
    file1_content = File.binread(file1_path).bytes
    file2_content = File.binread(file2_path).bytes
  rescue StandardError => e
    puts "读取文件时发生错误: #{e.message}"
    return
  end

  # 确保文件大小至少达到结束偏移量
  max_offset = [file1_content.length, file2_content.length].min
  if max_offset <= end_offset
    puts "警告：至少一个文件的大小 (#{max_offset.to_s(16)}) 小于或等于结束偏移量 (#{end_offset.to_s(16)})。"
    puts "比较范围将缩小到 [0x#{start_offset.to_s(16)}..0x#{max_offset.to_s(16) - 1}]。"
    actual_end_offset = max_offset - 1
  else
    actual_end_offset = end_offset
  end

  # 调整起始偏移量，确保它不大于实际结束偏移量
  if start_offset > actual_end_offset
    puts "错误：起始偏移量 (0x#{start_offset.to_s(16)}) 大于实际结束偏移量 (0x#{actual_end_offset.to_s(16)})。"
    return
  end

  # 调整为实际的比较范围
  range_start = start_offset
  range_end = actual_end_offset

  puts "正在比较文件 #{file1_path} 和 #{file2_path}。"
  puts "比较范围：0x#{range_start.to_s(16)} 到 0x#{range_end.to_s(16)}"
  puts "---"

  # 存储不同字节的范围
  differences = []

  # 当前不同字节范围的起始地址
  current_diff_start = nil

  # 遍历指定的字节范围
  (range_start..range_end).each do |offset|
    byte1 = file1_content[offset]
    byte2 = file2_content[offset]

    if byte1 != byte2
      # 找到不同字节
      if current_diff_start.nil?
        # 这是一个新范围的开始
        current_diff_start = offset
      end
    else
      # 字节相同
      if current_diff_start
        # 不同的范围刚刚结束
        differences << [current_diff_start, offset - 1]
        current_diff_start = nil
      end
    end
  end

  # 检查是否在文件末尾结束了未完成的不同范围
  if current_diff_start
    differences << [current_diff_start, range_end]
  end

  # 输出结果
  if differences.empty?
    puts "在指定范围内，两个文件完全相同。"
  else
    puts "发现以下不同字节范围（地址包含结束）："
    differences.each do |start_addr, end_addr|
      # 格式化输出地址为十六进制
      puts "  0x#{start_addr.to_s(16).upcase} - 0x#{end_addr.to_s(16).upcase} (长度: #{end_addr - start_addr + 1} 字节)"
    end
  end
end

# --- 脚本配置 ---

# 文件路径
FILE1 = '../summon_night_cpu'
FILE2 = '../summon_night_cpu3'

# 比较的起始和结束地址（包含结束地址）
# 0x10000 到 0x98000
START_OFFSET = 0x10000
END_OFFSET = 0x98000

# 执行比较函数
compare_binary_files(FILE1, FILE2, START_OFFSET, END_OFFSET)
