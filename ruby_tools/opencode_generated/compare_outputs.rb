require "set"

[1, 2].each do |id|
  puts "=== Script #{id} ==="
  
  old_fn = File.join(__dir__, "..", "dialog#{id}.txt")
  if File.exist?(old_fn)
    old_text = File.read(old_fn, encoding: "utf-8").split("\n").reject { |l| l.strip.empty? }
    puts "  Old (#{old_fn}): #{old_text.size} non-empty lines"
    
    new_files = Dir["dialog#{id}_fid*.txt"]
    new_text = new_files.flat_map { |fn| File.read(fn, encoding: "utf-8").split("\n").reject { |l| l.strip.empty? } }
    puts "  New (#{new_files.size} files): #{new_text.size} non-empty lines"
    
    old_set = Set.new(old_text)
    new_set = Set.new(new_text)
    common = old_set.intersection(new_set)
    old_only = old_set - new_set
    new_only = new_set - old_set
    puts "  Common lines: #{common.size}"
    puts "  Old-only: #{old_only.size}"
    puts "  New-only: #{new_only.size}"
    
    if new_only.size > 0 && new_only.size < 30
      puts "  New-only samples:"
      new_only.to_a.first(10).each { |l| puts "    #{l}" }
    end
    if old_only.size > 0 && old_only.size < 30
      puts "  Old-only samples:"
      old_only.to_a.first(5).each { |l| puts "    #{l}" }
    end
  else
    puts "  Old file not found: #{old_fn}"
  end
  puts ""
end
