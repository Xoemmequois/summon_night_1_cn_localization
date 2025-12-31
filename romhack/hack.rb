SDK_PATH = "D:\\projects\\psn00bsdk\\PSn00bSDK-0.24-win32\\"
GAME_PATH = "E:\\EmuRoms\\PS1\\Summon Night (Japan)\\Summon Night (Japan).bin"
DUMPSXISO = "#{SDK_PATH}\\bin\\dumpsxiso.exe"
MKPSXISO = "#{SDK_PATH}\\bin\\mkpsxiso.exe"
Dir.mkdir("output") unless Dir.exist?("output")
`#{SDK_PATH}\\bin\\mipsel-none-elf-gcc.exe -c -EL load.s -o .\\output\\load.o`
`#{SDK_PATH}\\bin\\mipsel-none-elf-objcopy.exe -R .MIPS.abiflags -O binary .\\output\\load.o .\\output\\load.bin`

bytes = IO.binread(".\\output\\load.bin")
if(bytes.length > 0x54)
  throw RuntimeError.new "错误: 装载程序过大，无法写入指定位置"
end

Dir.mkdir("rom") unless Dir.exist?("rom")
`#{DUMPSXISO} "#{GAME_PATH}" -x .\\rom -s .\\rom.xml`
File.open(".\\rom\\SLPS_025.42", "rb+") do |f|
  f.seek(0x85EFC)
  f.write(bytes)
  f.seek(0x21448)
  f.write("\xbf\x55\x02\x0c")
end
xml = IO.read(".\\rom.xml")
xml.gsub!('<file name="CM5301.DAT" source="rom/CM5301.DAT" type="mixed"/>',%Q(<file name="CM5301.DAT" source="rom/CM5301.DAT" type="mixed"/>\n<file name="C.F" source="chinese.fnt" type="data"/>))
IO.write(".\\rom.xml", xml)
`#{MKPSXISO} .\\rom.xml -y -o .\\output\\Summon_Night_Chinese.bin -c .\\output\\Summon_Night_Chinese.cue`
