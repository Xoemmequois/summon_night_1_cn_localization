local utils = require("utils")

-- Global lookup table for GPU memory (1024 * 512 entries)
-- Each entry stores the RAM source address for the corresponding GPU memory location
gpuToRamLookup = {}

-- Initialize the lookup table
for i = 0, 1024 * 512 - 1 do
    gpuToRamLookup[i] = 0
end

-- LoadImage parameters mapping: for each GPU index, store the LoadImage parameters
-- Each entry contains {x, y, w, h, ramSource, byteCount}
gpuToLoadImageParams = {}
for i = 0, 1024 * 512 - 1 do
    gpuToLoadImageParams[i] = nil
end

-- Breakpoint handle
loadImageBP = nil

-- Log file
logFile = Support.File.open("loadimage_log.txt", "TRUNCATE")

function log(str)
    print(str)
    if logFile then
        logFile:write(str)
        logFile:write("\n")
    end
end

function getLoadImageParamsForGpu(gpuIndex)
    if gpuIndex < 0 or gpuIndex >= 1024 * 512 then return nil end
    return gpuToLoadImageParams[gpuIndex]
end

function onLoadImage()
    local regs = PCSX.getRegisters().GPR.n
    local a0 = regs.a0  -- Pointer to rect (x, y, w, h)
    local a1 = regs.a1  -- Source address in RAM
    
    -- Check if a0 is in valid range
    if a0 < 0x80000000 or a0 > 0x807FFFFF then
        log(string.format("onLoadImage: a0=%X out of range, ignoring", a0))
        return true
    end
    
    -- Warp a0 if it's in 0x80200000-0x807FFFFF range
    if a0 >= 0x80200000 and a0 <= 0x807FFFFF then
        local offset = (a0 - 0x80200000) % 0x200000
        a0 = 0x80000000 + offset
        log(string.format("onLoadImage: warped a0 from %X to %X", regs.a0, a0))
    end
    
    -- Clear the highest bit (80 -> 00)
    local rectAddr = bit.band(a0, 0x7FFFFFFF)
    
    -- Get memory pointer
    local mem = PCSX.getMemPtr()
    
    -- Read rect data (4 uint16_t, little-endian): x, y, w, h
    local x = bit.lshift(mem[rectAddr + 1], 8) + mem[rectAddr]
    local y = bit.lshift(mem[rectAddr + 3], 8) + mem[rectAddr + 2]
    local w = bit.lshift(mem[rectAddr + 5], 8) + mem[rectAddr + 4]
    local h = bit.lshift(mem[rectAddr + 7], 8) + mem[rectAddr + 6]

    if(x == 0 and y == 480 and w == 256 and h == 32 and a1 == 0x801C4000) then
        return true
    end
    
    log(string.format("onLoadImage: src=%X, rect=(%d,%d,%d,%d)", a1, x, y, w, h))
    utils.showCurrentCallstacks()
    
    -- Each pixel is 2 bytes, so total size is w * h * 2
    local pixelCount = w * h
    local byteCount = pixelCount * 2
    
    -- Create LoadImage parameters record
    local loadImageParams = {
        x = x,
        y = y,
        w = w,
        h = h,
        ramSource = a1,
        byteCount = byteCount
    }
    
    -- Update the global lookup table
    -- For each pixel in the rect, map GPU address to RAM source
    for py = 0, h - 1 do
        for px = 0, w - 1 do
            local gpuIndex = (y + py) * 1024 + (x + px)
            local ramSource = a1 + (py * w + px) * 2
            gpuToRamLookup[gpuIndex] = ramSource
            -- Store LoadImage parameters for this GPU index
            gpuToLoadImageParams[gpuIndex] = loadImageParams
        end
    end
    
    log(string.format("onLoadImage: updated %d entries in lookup table", pixelCount))
    
    return true
end

function startLoadImage()
    -- Add breakpoint at 0x8006c66c
    loadImageBP = PCSX.addBreakpoint(0x8006c66c, 'Exec', 4, "LoadImage", onLoadImage)
    log("LoadImage breakpoint setup at 0x8006c66c")
    print("LoadImage breakpoint setup complete!")
end

