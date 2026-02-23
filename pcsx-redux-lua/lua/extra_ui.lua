print(type(table))
value = 0

-- GPU coordinate lookup state
gpuX = 0
gpuY = 0
ramAddress = nil
cdSector = nil
fileName = nil
sectorOffset = nil

-- File list: {name, startSector, sectorCount}
-- Based on the screenshot provided (column 3 is startSector, column 2 / 0x800 is sectorCount)
local files = {
    {name = "CM1000.DAT", startSector = 297, sectorCount = math.floor(17963008 / 0x800)},
    {name = "CM1100.DAT", startSector = 9068, sectorCount = math.floor(1660928 / 0x800)},
    {name = "CM5000.DAT", startSector = 9879, sectorCount = math.floor(34816 / 0x800)},
    {name = "CM1200.DAT", startSector = 9896, sectorCount = math.floor(931840 / 0x800)},
    {name = "CM2000.DAT", startSector = 10351, sectorCount = math.floor(9621504 / 0x800)},
    {name = "CM4000.DAT", startSector = 15049, sectorCount = math.floor(48752640 / 0x800)},
    {name = "CM3000.DAT", startSector = 38854, sectorCount = math.floor(9551872 / 0x800)},
}

function findFileForSector(sector)
    for _, file in ipairs(files) do
        local endSector = file.startSector + file.sectorCount - 1
        if sector >= file.startSector and sector <= endSector then
            local offset = sector - file.startSector
            return file.name, offset
        end
    end
    return nil, nil
end

function DrawImguiFrame()

    imgui.safe.Begin("CD Address Lookup", function() 

        imgui.TextUnformatted("GPU to RAM Lookup")
        
        -- Input fields for X and Y coordinates
        changed, gpuX = imgui.InputInt("GPU X", gpuX)
        changed, gpuY = imgui.InputInt("GPU Y", gpuY)
        
        if(imgui.Button("Query GPU Address")) then
            -- Calculate GPU index: (y * 1024 + x)
            local gpuIndex = gpuY * 1024 + gpuX
            
            -- Check if gpuToRamLookup exists and has the entry
            if gpuToRamLookup and gpuToRamLookup[gpuIndex] then
                ramAddress = gpuToRamLookup[gpuIndex]
                
                -- Now query ramToCdSector for this RAM address
                if ramToCdSector then
                    cdSector = getCdSectorForRam(ramAddress)
                    if cdSector == nil or cdSector == -1 then
                        cdSector = nil
                        fileName = nil
                        sectorOffset = nil
                    else
                        -- Find which file this sector belongs to
                        fileName, sectorOffset = findFileForSector(cdSector)
                    end
                else
                    cdSector = nil
                    fileName = nil
                    sectorOffset = nil
                end
            else
                ramAddress = nil
                cdSector = nil
                fileName = nil
                sectorOffset = nil
            end
        end
        
        imgui.Separator()
        imgui.TextUnformatted("Query Results")
        
        -- Display RAM address result
        if ramAddress then
            imgui.TextUnformatted(string.format("RAM Address: 0x%X", ramAddress))
        else
            imgui.TextUnformatted("RAM Address: Not Found")
        end
        
        -- Display CD Sector result
        if cdSector then
            imgui.TextUnformatted(string.format("CD Sector: %d", cdSector))
        else
            if ramAddress then
                imgui.TextUnformatted("CD Sector: Not Found")
            else
                imgui.TextUnformatted("CD Sector: N/A")
            end
        end
        
        -- Display file information
        if fileName then
            imgui.TextUnformatted(string.format("File: %s", fileName))
            imgui.TextUnformatted(string.format("Sector Offset: 0x%X", sectorOffset))
        elseif cdSector then
            imgui.TextUnformatted("File: Not in any file")
        end
    end)
end