require "commands_parse_tools"

fn = "../../romhack/rom/CM1100.DAT_19"

commands = parse_commands(fn).to_a

puts "=" * 70
puts "SCRIPT 19 COMMAND ANALYSIS"
puts "=" * 70

total = commands.length
puts "\n1. TOTAL COMMANDS: #{total}"

# Count opcodes
opcode_counts = Hash.new(0)
commands.each { |c| opcode_counts[c.code] += 1 }

count_2013 = opcode_counts[0x2013] || 0
puts "\n2. COUNT of 0x2013 (add dialog line): #{count_2013}"

# All 0x002F occurrences
puts "\n3. ALL 0x002F (load dialog text) OCCURRENCES:"
puts "-" * 70
cmd_count_002f = 0
fids = []
commands.each do |c|
  next unless c.code == 0x002F
  cmd_count_002f += 1
  fid = c.params[0]
  fids << fid
  subcontent_id = fid + 0x29
  byte_offset = c.index * 2
  puts "  Cmd##{cmd_count_002f} | CmdIndex=#{c.index} | ByteOffset=0x#{byte_offset.to_s(16).upcase} | FID=0x#{fid.to_s(16).upcase} (#{fid}) | SubcontentID=0x#{subcontent_id.to_s(16).upcase} (#{subcontent_id})"
end
puts "  TOTAL 0x002F commands: #{cmd_count_002f}"

puts "\n  FIDs referenced (sorted): #{fids.sort.map { |f| "0x#{f.to_s(16).upcase}" }.join(', ')}"

# Check for 0x4E and 0x4F
puts "\n  Check for FIDs 0x4E and 0x4F:"
found_4e = fids.include?(0x4E)
found_4f = fids.include?(0x4F)
puts "    FID 0x4E (78): #{found_4e ? "FOUND" : "NOT FOUND"}"
puts "    FID 0x4F (79): #{found_4f ? "FOUND" : "NOT FOUND"}"

# All 0x0027 occurrences
puts "\n4. ALL 0x0027 (switch-on-variable) OCCURRENCES:"
puts "-" * 70
cmd_count_0027 = 0
commands.each do |c|
  next unless c.code == 0x0027
  cmd_count_0027 += 1
  mode = c.params[0]
  var_id = c.params[1]
  param3 = c.params[2]
  param4 = c.params[3]
  jump_table = c.params[4..] || []
  
  byte_offset = c.index * 2
  
  mode_desc = case mode
  when 2 then "TableC4 (*0x800A82C4=0x800EF000)"
  when 4 then "TableC8 (*0x800A82C8)"
  else "Unknown mode #{mode}"
  end
  
  terminator_idx = jump_table.index(0x0000)
  actual_table = terminator_idx ? jump_table[0...terminator_idx] : jump_table
  
  puts "\n  --- Switch ##{cmd_count_0027} ---"
  puts "  CmdIndex=#{c.index} | ByteOffset=0x#{byte_offset.to_s(16).upcase}"
  puts "  Mode=#{mode} (#{mode_desc})"
  puts "  VarID=0x#{var_id.to_s(16).upcase} (#{var_id})"
  puts "  Param3=0x#{param3.to_s(16).upcase}"
  puts "  Param4=0x#{param4.to_s(16).upcase} (#{param4})"
  puts "  Jump targets (#{actual_table.length} entries, before 0x0000):"
  actual_table.each_with_index do |target, idx|
    puts "    [val=#{idx+param4}] => target=0x#{target.to_s(16).upcase} (#{target})"
  end
  
  if var_id == 0x95 && mode == 2
    puts "  *** THIS IS c4[0x95] SWITCH ***"
  end
  
  if !actual_table.empty?
    puts "  Subroutines reached:"
    actual_table.each_with_index do |target, idx|
      target_cmd = commands.find { |cc| cc.index == target }
      if target_cmd
        puts "    [val=#{idx+param4}] target=0x#{target.to_s(16).upcase} -> Cmd@#{target_cmd.index} opcode=0x#{target_cmd.code.to_s(16).upcase}"
        if target_cmd.code == 0x002F
          puts "      -> 0x002F FID=0x#{target_cmd.params[0].to_s(16).upcase} (#{target_cmd.params[0]})"
        end
        target_idx_in_commands = commands.index(target_cmd)
        if target_idx_in_commands
          lookahead = commands[target_idx_in_commands, 10] || []
          lookahead.each do |la|
            if la.code == 0x002F
              puts "      (within +10) 0x002F FID=0x#{la.params[0].to_s(16).upcase} (#{la.params[0]})"
            end
          end
        end
      else
        puts "    [val=#{idx+param4}] target=0x#{target.to_s(16).upcase} -> (no command at this index)"
      end
    end
  end
end
puts "\n  TOTAL 0x0027 commands: #{cmd_count_0027}"

# Full opcode statistics
puts "\n5. FULL OPCODE STATISTICS:"
puts "-" * 70
opcode_counts.sort_by { |code, count| code }.each do |code, count|
  puts "  0x#{code.to_s(16).upcase.rjust(4,'0')}: #{count}"
end

# Check FIDs NOT found
puts "\n6. FID GAP ANALYSIS:"
puts "-" * 70
if fids.empty?
  puts "  No 0x002F commands found."
else
  min_fid = fids.min
  max_fid = fids.max
  all_possible_fids = (min_fid..max_fid).to_a
  missing_fids = all_possible_fids - fids
  if missing_fids.empty?
    puts "  No gaps from 0x#{min_fid.to_s(16).upcase} to 0x#{max_fid.to_s(16).upcase}"
  else
    puts "  FIDs referenced range: 0x#{min_fid.to_s(16).upcase} (#{min_fid}) to 0x#{max_fid.to_s(16).upcase} (#{max_fid})"
    puts "  Missing FIDs in range:"
    missing_fids.each do |mf|
      puts "    0x#{mf.to_s(16).upcase} (#{mf}) -> SubcontentID 0x#{(mf+0x29).to_s(16).upcase} (#{mf+0x29})"
    end
  end
end

puts "\n7. SUMMARY:"
puts "-" * 70
puts "  Total commands:    #{total}"
puts "  0x2013 commands:   #{count_2013}"
puts "  0x002F commands:   #{cmd_count_002f}"
puts "  0x0027 commands:   #{cmd_count_0027}"
puts "  Unique FIDs:       #{fids.uniq.length}"
