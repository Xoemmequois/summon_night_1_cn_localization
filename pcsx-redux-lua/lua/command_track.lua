local bit = require("bit")
index = -1
logFile = Support.File.open("command.txt", "TRUNCATE")

function log(str)
    print(str)
    logFile:write(str)
    logFile:write("\n")
end

-- 定义指令长度映射表
local pcOffset = {
    [0x0000] = 1,
    [0x0001] = 3,
    [0x0002] = 5,
    [0x0003] = 3,
    [0x0004] = 1,
    [0x0005] = 5,
    [0x0006] = 2,
    [0x0007] = 1,
    [0x0008] = 3,
    [0x0009] = 3,
    [0x000B] = 1,
    [0x000C] = 1,
    [0x000D] = 1,
    [0x000E] = 1,
    [0x000F] = 1,
    [0x0010] = 3,
    [0x0011] = 3,
    [0x0012] = 3,
    [0x0013] = 3,
    [0x0014] = 2,
    [0x0015] = 1,
    [0x0016] = 3,
    [0x0017] = 1,
    [0x0018] = 1,
    [0x0019] = 1,
    [0x001A] = 3,
    [0x001B] = 1,
    [0x001C] = 1,
    [0x001D] = 1,
    [0x001E] = 1,
    [0x001F] = 1,
    [0x0020] = 2,
    [0x0021] = 2,
    [0x0022] = 2,
    [0x0023] = 2,
    [0x0024] = 1,
    [0x0025] = 2,
    [0x0026] = 1,
    [0x0027] = 5,
    [0x0028] = 2,
    [0x0029] = 1,
    [0x002A] = 1,
    [0x002B] = 2,
    [0x002C] = 2,
    [0x002D] = 2,
    [0x002E] = 1,
    [0x002F] = 2,
    [0x0030] = 1,
    [0x0031] = 1,
    [0x0032] = 1,
    [0x0033] = 1,
    [0x0034] = 2,
    [0x0035] = 2,
    [0x0036] = 2,
    [0x0037] = 2,
    [0x0038] = 3,
    [0x0039] = 1,
    [0x003A] = 9,
    [0x003B] = 1,
    [0x003C] = 2,
    [0x003D] = 1,
    [0x003E] = 1,
    [0x003F] = 1,
    [0x0040] = 1,
    [0x0041] = 1,
    [0x0042] = 1,
    [0x0043] = 1,
    [0x0044] = 1,
    [0x0045] = 1,
    [0x0046] = 1,
    [0x0047] = 1,
    [0x1000] = 1,
    [0x1001] = 1,
    [0x1002] = 1,
    [0x1003] = 1,
    [0x1004] = 1,
    [0x1005] = 1,
    [0x1006] = 2,
    [0x1007] = 1,
    [0x1008] = 1,
    [0x1009] = 1,
    [0x100A] = 1,
    [0x100B] = 1,
    [0x100C] = 1,
    [0x100D] = 1,
    [0x100E] = 1,
    [0x100F] = 1,
    [0x1010] = 1,
    [0x1011] = 3,
    [0x1012] = 3,
    [0x1013] = 3,
    [0x1014] = 2,
    [0x1015] = 2,
    [0x1016] = 1,
    [0x1017] = 1,
    [0x1018] = 1,
    [0x1019] = 2,
    [0x101A] = 2,
    [0x101B] = 2,
    [0x101C] = 2,
    [0x101D] = 2,
    [0x101E] = 1,
    [0x101F] = 1,
    [0x2000] = 4,
    [0x2001] = 3,
    [0x2002] = 3,
    [0x2003] = 5,
    [0x2004] = 2,
    [0x2005] = 2,
    [0x2006] = 3,
    [0x2007] = 1,
    [0x2008] = 1,
    [0x2009] = 1,
    [0x200A] = 1,
    [0x200B] = 2,
    [0x200C] = 1,
    [0x200D] = 1,
    [0x200E] = 1,
    [0x200F] = 2,
    [0x2010] = 4,
    [0x2011] = 1,
    [0x2012] = 1,
    [0x2013] = 2,
    [0x2014] = 1,
    [0x2015] = 2,
    [0x2016] = 4,
    [0x2017] = 2,
    [0x2018] = 2,
    [0x2019] = 2,
    [0x201A] = 1,
    [0x201B] = 1,
    [0x201C] = 1,
    [0x201D] = 3,
    [0x201E] = 1,
    [0x201F] = 1,
    [0x2020] = 3,
    [0x2021] = 2,
    [0x2022] = 5,
    [0x2023] = 5,
    [0x2024] = 3,
    [0x2025] = 3,
    [0x2026] = 2,
    [0x2027] = 1,
    [0x2029] = 2,
    [0x202A] = 1,
    [0x202B] = 1,
    [0x202C] = 1,
    [0x202D] = 1,
    [0x202E] = 1,
    [0x202F] = 1,
    [0x2030] = 2,
    [0x2031] = 1,
    [0x2032] = 1,
    [0x2033] = 1,
    [0x2034] = 1,
    [0x2035] = 1,
    [0x2036] = 1,
    [0x2037] = 1,
    [0x2038] = 1,
    [0x2039] = 1,
    [0x203A] = 1,
    [0x203B] = 1,
    [0x203C] = 1,
    [0x203D] = 1,
    [0x203E] = 1,
    [0x203F] = 1,
    [0x2040] = 1,
    [0x2041] = 1,
    [0x2042] = 1,
    [0x2043] = 1,
    [0x2044] = 1,
    [0x2045] = 1,
    [0x2046] = 1,
    [0x2047] = 1,
    [0x2048] = 1,
    [0x2049] = 1,
    [0x204A] = 1,
    [0x204B] = 1,
    [0x204C] = 3,
    [0x204D] = 3,
    [0x204E] = 3,
    [0x204F] = 1,
    [0x2050] = 1,
    [0x2051] = 3,
    [0x2052] = 1,
    [0x2053] = 1,
    [0x2054] = 2,
    [0x2055] = 1,
    [0x2056] = 1,
    [0x2057] = 1,
    [0x2058] = 1,
    [0x2059] = 1,
    [0x205A] = 1,
    [0x205B] = 1,
    [0x205C] = 1,
    [0x205D] = 1,
    [0x205E] = 1,
    [0x205F] = 1,
    [0x2060] = 1,
    [0x2061] = 3,
    [0x2062] = 1,
    [0x2063] = 1,
    [0x2064] = 1,
    [0x2065] = 1,
    [0x2066] = 1,
    [0x2067] = 1,
    [0x2068] = 1,
    [0x2069] = 2,
    [0x206A] = 1,
    [0x206B] = 1,
    [0x206C] = 1,
    [0x206D] = 1,
    [0x206E] = 1,
    [0x206F] = 1,
    [0x2070] = 3,
    [0x2071] = 1,
    [0x2072] = 1,
    [0x2073] = 1,
    [0x2074] = 1,
    [0x2075] = 1,
    [0x2076] = 1,
    [0x2077] = 1,
    [0x2078] = 1,
    [0x2079] = 1,
    [0x207A] = 1,
    [0x207B] = 1,
    [0x207C] = 1,
    [0x207D] = 1,
    [0x207E] = 1,
    [0x207F] = 1,
    [0xFFFF] = 1
}
--- 新增辅助函数：按照逻辑读取16位数值
local function readWord(data, n)
    local a = data[n * 2 + 0xE000C] or 0
    local b = data[n * 2 + 0xE000D] or 0
    return bit.bor(bit.lshift(b, 8), a)
end

--- 模拟 instr000A
local function instr000A(pc, data)
    local old_pc = pc
    pc = pc + 1
    while true do
        local n = readWord(data, pc) -- 替换 data[pc]
        pc = pc + 1
        if n < 8 then
            pc = pc + 1
        elseif n < 0x80 then
            break
        end
    end
    return pc - old_pc
end

--- 模拟 instr0027
local function instr0027(pc, data)
    local i = 5
    while true do
        -- 替换 data[pc + i]
        if readWord(data, pc + i) == 0 then
            i = i + 1
            break
        end
        i = i + 1
    end
    return i
end

--- 模拟 instr2028
local function instr2028(pc, data)
    local arg = readWord(data, pc + 1) -- 替换 data[pc + 1]
    local offset = 2

    if arg == 0 or arg == 1 then
        offset = 6
    elseif arg == 2 then
        offset = 5
    elseif arg == 3 or arg == 6 or arg == 7 then
        offset = 2
    elseif arg == 4 then
        offset = 4
    elseif arg == 5 then
        offset = 3
    else
        print("Invalid Arg for 2028 " .. tostring(arg))
    end

    return offset
end

--- 获取指令偏移量
function getCommandOffset(pc, data)
    local offset = 1
    local code = readWord(data, pc) -- 替换 data[pc]

    if code == 0x000A then
        offset = instr000A(pc, data)
    elseif code == 0x2028 then
        offset = instr2028(pc, data)
    elseif code == 0x0027 then
        offset = instr0027(pc, data)
    else
        offset = pcOffset[code]
        if offset == nil then
            offset = 1
        end
    end

    return offset
end

lastPC = -1

function onExecuteCommandFetched()
    local mem = PCSX.getMemPtr();
    local b1 = mem[0xA8282]
    local b2 = mem[0xA8283]
    local pc = b2 * 256 + b1
    if (lastPC ~= pc) then
        lastPC = pc
        local paramsCount = getCommandOffset(pc, mem) - 1
        -- 补充的代码逻辑如下：
        local paramsList = {}
        for i = 1, paramsCount do
            -- 从 pc + 1 开始读取
            local val = readWord(mem, pc + i)
            -- %04X 表示 16 进制，不足 4 位补 0，大写
            -- 如果需要小写，可以使用 %04x
            table.insert(paramsList, string.format("%04X", val))
        end

        -- 使用空格合并成一个字符串
        local paramsString = table.concat(paramsList, " ")
        local instruction = bit.band(PCSX.getRegisters().GPR.n.v0, 0xFFFF)
        local hash = string.format("%02x%02x%02x%02x %02x%02x%02x%02x", mem[0xE0004], mem[0xE0005], mem[0xE0006],
            mem[0xE0007], mem[0xE0008], mem[0xE0009], mem[0xE000A], mem[0xE000B])
        getCommandOffset(pc, mem);
        log(string.format("%04X: %04X %s index %d ms %d Hash %s", pc, instruction, paramsString, index,
            tonumber(PCSX.getCPUCycles() * 1000 / PCSX.CONSTS.CPU.CLOCKSPEED), hash))
    end
end

function startCommandTrack()
    bp1 = PCSX.addBreakpoint(0x80019E88, "Exec", 4, "ExecuteCommand-Enter", function()
        index = PCSX.getRegisters().GPR.n.a0
    end);
    bp2 = PCSX.addBreakpoint(0x80019FBC, "Exec", 4, "ExecuteCommand-Fetched", onExecuteCommandFetched);
    print("Command Track Setup Complete")
end
