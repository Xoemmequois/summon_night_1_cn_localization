SDK_PATH = "G:\\hob\\PSn00bSDK-0.24-win32\\"
Dir.mkdir("output") unless Dir.exist?("output")
`#{SDK_PATH}\\bin\\mipsel-none-elf-gcc.exe -c -EL font.s -o .\\output\\font.o`
`#{SDK_PATH}\\bin\\mipsel-none-elf-objcopy.exe -R .MIPS.abiflags -O binary .\\output\\font.o .\\output\\font.bin`
