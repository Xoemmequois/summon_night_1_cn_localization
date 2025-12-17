def process(fn)
	File.open(fn, "rb") do |f|
		f.seek 0x08
		len = f.read(2).unpack1("S<")

		len.times do |i|
			f.seek(0x10 + i * 4)
			arr = f.read(4).unpack("S<*")
			p arr
			offset = arr[0]
			len = arr[1]
			next if(offset == 0 || len == 0)
			f.seek(2048 * offset)
			content = f.read(len * 2048)
			IO.binwrite("#{fn}_#{i}", content)
		end


	end
end
process("CM1100.DAT")
