file = File.read("out_translated.srt")
$chars = {}
file.each_char do |c|
    $chars[c] ||= 0
    $chars[c] += 1
end
$f = File.new("count.txt", "w")
arr = $chars.to_a
arr.sort_by!{|a| a[1]}
arr.each do |k, v|
    $f.puts "#{k}: #{v}" if k =~ /\p{Han}/
end
