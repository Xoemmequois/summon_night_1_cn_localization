local NPC_BASE = 0x9D3A8
local NPC_STRIDE = 0x30
local FACTION_OFFSET = 0x7
local DEATH_FLAG_OFFSET = 0xC
local NPC_COUNT = 64

lastKilled = nil
skipError = nil

function skipBattle()
    local mem = PCSX.getMemPtr()
    if not mem then
        error("Memory not available (no game loaded?)")
    end
    local killed = 0
    for i = 0, NPC_COUNT - 1 do
        local base = NPC_BASE + i * NPC_STRIDE
        if mem[base + FACTION_OFFSET] == 1 then
            mem[base + DEATH_FLAG_OFFSET] = 1
            killed = killed + 1
        end
    end
    return killed
end

local function drawBattleSkipWindow()
    local ok, err = pcall(function()
        imgui.safe.Begin("Battle Skip", function()
            if imgui.Button("Skip Battle") then
                local okSkip, result = pcall(skipBattle)
                if okSkip then
                    lastKilled = result
                    skipError = nil
                else
                    skipError = result
                end
            end
            if skipError then
                imgui.TextUnformatted("Error: " .. tostring(skipError))
            elseif lastKilled then
                imgui.TextUnformatted(string.format("Killed %d enemy units", lastKilled))
            else
                imgui.TextUnformatted("Click to kill all enemy units")
            end
        end)
    end)
    if not ok then
        printError("Battle Skip UI error: " .. tostring(err))
    end
end

function startBattleSkip()
    local prevFrame = DrawImguiFrame
    DrawImguiFrame = function()
        if prevFrame then
            prevFrame()
        end
        drawBattleSkipWindow()
    end
    print("Battle Skip Setup Complete")
end
