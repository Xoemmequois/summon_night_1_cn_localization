local bit = require("bit")

local utils = {}

-- Utility function to find function start address
function utils.findFunctionStart(start_address)
    start_address = bit.band(start_address, 0x7FFFFFFF)
    local mem_ptr = PCSX.getMemPtr()
    
    local INSTRUCTION_SIZE = 4
    local JR_RA_OPCODE = 0x0800E003
    
    if start_address % INSTRUCTION_SIZE ~= 0 then
        start_address = start_address - (start_address % INSTRUCTION_SIZE)
    end
    
    local current_address = start_address
    local MIN_SEARCH_ADDRESS = 0x00000000
    
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

-- Show current callstacks and return callstack table
function utils.showCurrentCallstacks()
    local callstack = {}
    local calls = PCSX.getCurrentCalls();
    for call in calls do 
        local cra = call.ra
        local craStart = utils.findFunctionStart(cra)
        if log then
            log(string.format("%X(%X)", craStart, cra))
        else
            print(string.format("%X(%X)", craStart, cra))
        end
        table.insert(callstack, {start = craStart, addr = cra})
    end
    local ra = PCSX.getRegisters().GPR.n.ra
    local raStart = utils.findFunctionStart(ra)
    if log then
        log(string.format("%X(%X)", raStart, ra))
    else
        print(string.format("%X(%X)", raStart, ra))
    end
    table.insert(callstack, {start = raStart, addr = ra})
    return callstack
end

return utils
