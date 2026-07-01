# ============================================================
# xref_analysis.rb — 静态 XREF + 可达性分析
# 目标: 分析 0006-0010 (FID=6, text_idx=0x0A) 的抵达路径
# ============================================================

def parse_commands_txt(fn)
  cmds = []
  File.readlines(fn).each do |line|
    m = line.match(/^(\h{4}): (.+)$/)
    next unless m
    offset = m[1].to_i(16)
    tokens = m[2].strip.split(/\s+/).map { |t| t.to_i(16) }
    cmds << { off: offset, data: tokens }
  end
  cmds
end

fn = "../../exported/CM1100.DAT_1_commands.txt"
unless File.exist?(fn)
  puts "ERROR: #{fn} not found"
  exit 1
end

cmds = parse_commands_txt(fn)

target_fid = 6
target_text = 0x0A  # decimal 10 = key 0010
target_key = sprintf("%04d-%04d", target_fid, target_text)

puts "=" * 75
puts "XREF STATIC ANALYSIS: #{target_key} (FID=#{target_fid}, TEXT=#{sprintf('%04X', target_text)})"
puts "=" * 75

# ============================================================
# [1] 所有 0x2013 text=0x0A 的位置
# ============================================================
puts
puts "[1] ALL 0x2013 TEXT=#{sprintf('%04X', target_text)} LOCATIONS"
puts "    #{'Offset'.ljust(8)} #{'Region'}  #{'Context'}"

text_locations = []
cmds.each do |cmd|
  next if cmd[:data].empty? || cmd[:data][0] != 0x2013
  next unless cmd[:data][1] == target_text
  text_locations << cmd[:off]
end

# 按区域分类
text_locations.each do |off|
  region = case off
  when 0x0570..0x05A0 then "dump"
  when 0x1BC0..0x1BE0 then "FID=2"
  when 0x1D20..0x1D40 then "FID=2 alt"
  when 0x2160..0x2180 then "FID=3"
  when 0x26A0..0x26C0 then "FID=4"
  when 0x29B0..0x29D0 then "FID=5"
  when 0x2B30..0x2B50 then "FID=5 alt"
  when 0x2CB0..0x2CD0 then "FID=6"  # *** THE IMPORTANT ONE ***
  else "unknown"
  end
  puts "    #{sprintf('%04X', off).ljust(8)} [#{region.ljust(10)}]"
end

# ============================================================
# [2] FID=6 设置点: 0x0473
# ============================================================
puts
puts "[2] FID=6 SETTER: offset 0x0473"
puts "    0473: 002F 0006          <- SetFID=6 (only place in whole script)"
puts "    0475: 0010 00F9 0004     <- c4[0xF9]=4"
puts "    0478: 0001 0002 0093     <- c4[0x93]=0"
puts "    047B: 0023 0489          <- jump to returns"
puts "    0489-048D: 0026 * 5      <- returns"
puts
puts "    This is case 5 of switch at 0x047D on c4[0x95]:"
puts "    047D: 0027 0002 0095 ..."
puts "      case 0→0421(FID=1)  1→0448(FID=2)  2→0452(FID=3)"
puts "      case 3→045C(FID=4)  4→0469(FID=5)  5→0473(FID=6)"

# ============================================================
# [3] FID=6 子程序入口
# ============================================================
puts
puts "[3] FID=6 SUBROUTINE ENTRY & CONTROL FLOW"
puts "    After FID=6 set, the outer loop (switch on F9 at 0x018F)"
puts "    dispatches to 0x0161 → 0x048E → 0x04EB → case 5 → 0x04E7"
puts "    0x04E7: 0025 2BE5    <- CALL FID=6 subroutine"
puts
puts "    --- FID=6 subroutine (entry 0x2BE5) ---"
puts "    2BE5: 0023 2C60"
puts "    2C60: 0027 switch-on-93 → always case0 → 2BE7"
puts "    2C67: 0026 (return)"
puts
puts "    2BE7: 000A (complex compare, sets regA)"
puts "    2BEE: 0020 2BF2  ← if regA & 1: jump to Path A"
puts "    2BF0: 0023 2C15  ← else:         jump to Path B"
puts
puts "    *** PATH A (regA & 1 != 0): ***"
puts "    2BF2: 0025 2C68  ← call dialog block at 2C68"

# Show the dialog block at 2C68
puts
puts "    --- Dialog block at 2C68 (Path A) ---"
cmds.select { |c| c[:off] >= 0x2C68 && c[:off] <= 0x2CD4 }.each do |cmd|
  next if cmd[:data].empty?
  code = cmd[:data][0]
  marker = (code == 0x2013 && cmd[:data][1] == target_text) ? " <<< TARGET" : ""
  info = case code
  when 0x0021 then "branch"
  when 0x0023 then "jump"
  when 0x0026 then "return"
  when 0x2012 then "next page"
  when 0x2015 then "wait for choice"
  when 0x200B, 0x200C then ""
  else ""
  end
  puts "    #{sprintf('%04X', cmd[:off])}: #{cmd[:data].map{|d| sprintf('%04X',d)}.join(' ')}  #{info}#{marker}"
end

puts
puts "    *** PATH B (regA & 1 == 0): ***"
puts "    2C15: 0025 2E70  ← call 2E70 (no 0x0A text here)"
puts "    ...eventually → 2C36 → 2C38 → switch on 1D →"
puts "    → 2C54(call 01FD) → 2C59(0010 F9=0A) → 2C5C(002C load sub-script 2)"
puts "    → 2C67: 0026 (return)"

# ============================================================
# [4] VM 模拟差异
# ============================================================
puts
puts "[4] REACHABILITY ANALYSIS (why VM can't reach #{target_key})"
puts
puts "    The text at 0x2CBA is on PATH A, entered via:"
puts "      2BE7: 000A (complex compare) → 2BEE: 0020 (regA & 1 ? jump)"
puts
puts "    In the Ruby VM simulator:"
puts "      - 0x000A is NOT in the ExecManager::HANDLERS table"
puts "      - It is dispatched as 'unknown' → pc += 1 (skips it)"
puts "      - The comparison result is NEVER computed"
puts "      - regA remains 0 (VM initialized)"
puts "      - 0x0020 at 2BEE sees regA & 1 == 0 → fall through"
puts "      - Execution goes to Path B (0x2C15) instead"
puts "      - Path B does NOT contain 0x2013 text=0x0A"
puts
puts "    => VM MISSES #{target_key} because 0x000A instruction is not simulated!"
puts
puts "    In the REAL game:"
puts "      - 0x000A computes: c4[0x1D] comparison chain, sets regA accordingly"
puts "      - If the condition matches (likely a specific story flag),"
puts "        regA & 1 != 0 → Path A taken → text 0x0A is displayed"
puts
puts "    ALTERNATE PATH (dump block):"
puts "      - 0x0576: 2013 000A is in the sequential dump block"
puts "      - This block is entered when c4[0x19] != 0 (external var fork)"
puts "      - VM DOES explore this via external var forking"
puts "      - But the text is recorded as part of a bulk-dump group"
puts "      - It MAY appear in all_fid_covered[6] depending on coverage calc"

# ============================================================
# [5] 同一文本在其他 FID 的使用
# ============================================================
puts
puts "[5] TEXT #{sprintf('%04X', target_text)} USAGE IN OTHER FIDs"
puts "    This same text (これは夢にちがいない！) appears in:"
puts "    - FID=2: 0x1BC4 (reachable via 0x04D7→1AEF→...→1B84)"
puts "    - FID=2 alt: 0x1D22"
puts "    - FID=3: 0x2164 (reachable via 0x04DB→20FC→...→2129)"
puts "    - FID=4: 0x26A5 (conditional path)"
puts "    - FID=5: 0x29BB, 0x2B3C"
puts "    - FID=6: 0x2CBA (Path A only, not simulated by VM)"
puts
puts "    Conclusion: text 0x0A is used in multiple character/story routes."
puts "    In FID=6, it is on a path gated by 0x000A (regA condition)."

# ============================================================
# [6] 修复建议
# ============================================================
puts
puts "[6] FIX SUGGESTION"
puts "    To make the VM find #{target_key}, either:"
puts
puts "    a) Implement 0x000A simulation:"
puts "       Parse the comparison chain at 2BE7 to determine regA"
puts "       (complex, requires understanding of the variable semantics)"
puts
puts "    b) Fork at 0x0020 instruction:"
puts "       When regA is unknown, fork both Path A and Path B"
puts "       (similar to how external vars are handled at 0x0021/0x0022)"
puts
puts "    c) Manual marking:"
puts "       Mark #{target_key} and similar texts as 'reachable' in"
puts "       the coverage report, knowing they are on alternate branches."

puts
puts "=" * 75
