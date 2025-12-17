bytes = IO.binread("../memory_mark")
start = 0
arr = []
for i in 0..bytes.length
	next if bytes[i] == "\x00"
	if i - start >= 1024
		arr.push [start, i-1,  i - start]
	end
	start = i + 1
end
arr.sort_by!{|a| a[2]}
arr.each do |a|
	printf("%x-%x %d\n", a[0], a[1], a[2])
end
