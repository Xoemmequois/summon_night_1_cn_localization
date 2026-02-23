local bit = require("bit")
local utils = require("utils")

-- CD <-> RAM mapping
SECTOR_SIZE = 0x800
RAM_SIZE = 0x200000 -- 2MB

-- Global lookup table: for each RAM byte offset (0 .. RAM_SIZE-1)
-- store which CD sector that byte was loaded from, or -1 if unknown
ramToCdSector = {}
for i = 0, RAM_SIZE - 1 do
    ramToCdSector[i] = -1
end

-- Callstack mapping: for each RAM byte offset, store the callstack addresses when it was loaded
-- Each entry is a table of addresses
ramToCallstack = {}
for i = 0, RAM_SIZE - 1 do
    ramToCallstack[i] = {}
end

-- CDRead parameters mapping: for each RAM byte offset, store the CDRead parameters
-- Each entry contains {dest, len, startSector}
ramToCDReadParams = {}
for i = 0, RAM_SIZE - 1 do
    ramToCDReadParams[i] = nil
end

-- Helper: mark a contiguous range of RAM as coming from successive CD sectors
function setSectorMapping(destAddr, sectorStart, sectorCount, callstack, cdReadParams)
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
            if callstack then
                ramToCallstack[ramStart + off] = callstack
            end
            if cdReadParams then
                ramToCDReadParams[ramStart + off] = cdReadParams
            end
        end
    end
end

function getCdSectorForRam(addr)
    addr = bit.band(addr, 0x7FFFFFFF)
    if addr >= RAM_SIZE then return nil end
    return ramToCdSector[addr]
end

function getCallstackForRam(addr)
    addr = bit.band(addr, 0x7FFFFFFF)
    if addr >= RAM_SIZE then return nil end
    return ramToCallstack[addr]
end

function getCDReadParamsForRam(addr)
    addr = bit.band(addr, 0x7FFFFFFF)
    if addr >= RAM_SIZE then return nil end
    return ramToCDReadParams[addr]
end

function onCDRead()
    local regs = PCSX.getRegisters().GPR.n;
    local len = regs.a0
    local dest = regs.a1
    log(string.format("CDRead %d Sectors From %d Into %X", len, lastSetLoc, dest))
    
    -- Get callstack and log it
    local callstack = utils.showCurrentCallstacks()

    -- Create CDRead parameters record
    local cdReadParams = {
        dest = dest,
        len = len,
        startSector = lastSetLoc
    }

    -- Normalize dest and update mapping table
    local destOff = bit.band(dest, 0x7FFFFFFF)
    if destOff < RAM_SIZE then
        setSectorMapping(destOff, lastSetLoc, len, callstack, cdReadParams)
    else
        log(string.format("CDRead into invalid RAM addr %X (offset %X)", dest, destOff))
    end
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
    utils.showCurrentCallstacks()
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