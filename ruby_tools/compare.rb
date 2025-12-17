actor0 = IO.read("actor0.txt")
actor3 = IO.read("actor3.txt")
list0 = actor0.each_line.map{|l| l =~ /(\d+)\:/; $1}.filter{|a| !a.nil?}
list3 = actor3.each_line.map{|l| l =~ /(\d+)\:/; $1}.filter{|a| !a.nil?}
list0.each_with_index do |v, i|
  puts "#{i} #{v} #{list3[i]}" if(v != list3[i])
end
