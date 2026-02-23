local bit = require("bit")

-- CD <-> RAM mapping
SECTOR_SIZE = 0x800
RAM_SIZE = 0x200000 -- 2MB

-- Global lookup table: for each RAM byte offset (0 .. RAM_SIZE-1)
-- store which CD sector that byte was loaded from, or -1 if unknown
ramToCdSector = {}
for i = 0, RAM_SIZE - 1 do
    ramToCdSector[i] = -1
end

-- Helper: mark a contiguous range of RAM as coming from successive CD sectors
function setSectorMapping(destAddr, sectorStart, sectorCount)
    destAddr = bit.band(destAddr, 0x7FFFFFFF)
    if destAddr >= RAM_SIZE then
        return
    end
    for s = 0, sectorCount - 1 do
        local sector = sectorStart + s
        local ramStart = destAddr + s * SECTOR_SIZE
        if ramStart >= RAM_SIZE then break end
        local writeCount = math.min(SECTOR_SIZE, RAM_SIZE - ramStart)
        for off = 0, writeCount - 1 do
            ramToCdSector[ramStart + off] = sector
        end
    end
end

function getCdSectorForRam(addr)
    addr = bit.band(addr, 0x7FFFFFFF)
    if addr >= RAM_SIZE then return nil end
    return ramToCdSector[addr]
end

function findFunctionStart(start_address)

    start_address = bit.band(start_address, 0x7FFFFFFF)
    local mem_ptr = PCSX.getMemPtr()
    
    local INSTRUCTION_SIZE = 4
    
    local JR_RA_OPCODE = 0x0800E003
    
    if start_address % INSTRUCTION_SIZE ~= 0 then
        start_address = start_address - (start_address % INSTRUCTION_SIZE)
    end
    
    local current_address = start_address
    
    local MIN_SEARCH_ADDRESS = 0x00000000 -- 假设一个合理的最小搜索地址
    
    while current_address >= MIN_SEARCH_ADDRESS do
        local byte1 = mem_ptr[current_address]
        local byte2 = mem_ptr[current_address + 1]
        local byte3 = mem_ptr[current_address + 2]
        local byte4 = mem_ptr[current_address + 3]
        local instruction = bit.lshift(byte1, 24) + bit.lshift(byte2, 16) + bit.lshift(byte3, 8) + byte4

        
        if instruction == JR_RA_OPCODE then
            return current_address + 2 * INSTRUCTION_SIZE + 0x80000000
        end
        
        current_address = current_address - INSTRUCTION_SIZE
    end
end

function showCurrentCallstacks()
    local calls = PCSX.getCurrentCalls();
    for call in calls do 
        local cra = call.ra
        local craStart = findFunctionStart(cra)
        log(string.format("%X(%X)", craStart, cra))
    end
    local ra = PCSX.getRegisters().GPR.n.ra
    local raStart = findFunctionStart(ra)
    log(string.format("%X(%X)", raStart, ra))
end

function onCDRead()
    local regs = PCSX.getRegisters().GPR.n;
    local len = regs.a0
    local dest = regs.a1
    log(string.format("CDRead %d Sectors From %d Into %X", len, lastSetLoc, dest))
    -- Normalize dest and update mapping table
    local destOff = bit.band(dest, 0x7FFFFFFF)
    if destOff < RAM_SIZE then
        setSectorMapping(destOff, lastSetLoc, len)
    else
        log(string.format("CDRead into invalid RAM addr %X (offset %X)", dest, destOff))
    end
    showCurrentCallstacks()
    return true
end

function btoi(c)
    return bit.rshift(c, 4) * 10 + bit.band(c, 0xF)
end

lastSetLoc = 0

function onCDControl()
    local regs = PCSX.getRegisters().GPR.n;
    local command = regs.a0
    local commandArg = regs.a1
    if command ~= 2 then
        return
    end
    commandArg = bit.band(commandArg, 0x7FFFFFFF)
    if commandArg >= 0x200000 then
        log(string.format("CDControl with SetLoc at %X Invalid Addr", commandArg))    
        return
    end
    local mem = PCSX.getMemPtr()
    local minutes = btoi(mem[commandArg])
    local seconds = btoi(mem[commandArg + 1])
    local sectors = btoi(mem[commandArg + 2])
    local sec = minutes * 75 * 60 + seconds * 75 + sectors - 150
    lastSetLoc = sec
    log(string.format("CDControl with SetLoc at %d", sec))
    showCurrentCallstacks()
    return true
end

readCDBP = nil
cdControlBP = nil
logFile = Support.File.open("info.txt", "TRUNCATE")
--logFile.write("test")

function log(str)
    print(str)
    logFile:write(str)
    logFile:write("\n")
end

function start()
    readCDBP = PCSX.addBreakpoint(0x800731e4, 'Exec', 4, "CDRead", onCDRead)
    cdControlBP = PCSX.addBreakpoint(0x800702e0, 'Exec', 4, "CDControl", onCDControl)
    print("Setup Complete!")
end

-- local calls = PCSX.getCurrentCalls();
-- for call in calls do 
    
-- end
-- local ra = PCSX.getRegisters().GPR.n.ra