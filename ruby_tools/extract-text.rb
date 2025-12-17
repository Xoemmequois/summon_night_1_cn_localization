File.open("CM1100.DAT_42", "rb") do |file|
	file.seek(0x1d0)
	str = ""
	strs = []
	while true
		buf = "aa"
		break unless file.read(2, buf)
		if buf == "\x0\x0"
			unless str.empty?
				strs.push "#{file.pos.to_s(16)} " + str.force_encoding("shift_jis").encode("utf-8")
			end
			str = ""
		else
			str += buf
		end
	end
	File.write("text.txt", strs.join("\n"))
end
