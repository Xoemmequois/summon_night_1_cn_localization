autoSkipDialogs = false

local SCRIPT_PC_OFFSET = 0xA8282
local CMD_BASE_OFFSET = 0xE000C
local WAIT_OPCODES = { [0x2012] = true, [0x201D] = true }

local lastPc = -1
local circleActive = false
local circlePressed = false
local errorLatch = nil
local vsyncListener = nil

local function setCircle(pressed)
    local pad = PCSX.SIO0.slots[1].pads[1]
    local btn = PCSX.CONSTS.PAD.BUTTON.CIRCLE
    if pressed then
        pad.setOverride(btn)
    else
        pad.clearOverride(btn)
    end
end

local function pollDialogSkip()
    local ok, err = pcall(function()
        local mem = PCSX.getMemPtr()
        if not mem then
            return
        end
        local pc = mem[SCRIPT_PC_OFFSET + 1] * 256 + mem[SCRIPT_PC_OFFSET]
        if pc ~= lastPc then
            lastPc = pc
            local off = CMD_BASE_OFFSET + pc * 2
            local op = mem[off + 1] * 256 + mem[off]
            circleActive = WAIT_OPCODES[op] == true
            if not circleActive and circlePressed then
                circlePressed = false
                setCircle(false)
            end
        end
        if not autoSkipDialogs then
            if circlePressed then
                circlePressed = false
                setCircle(false)
            end
            return
        end
        if circleActive then
            circlePressed = not circlePressed
            setCircle(circlePressed)
        end
    end)
    if not ok and errorLatch ~= err then
        errorLatch = err
        printError("DialogSkip error: " .. tostring(err))
    end
end

function drawDialogSkipControls()
    local changed
    changed, autoSkipDialogs = imgui.Checkbox("Auto-skip dialogs", autoSkipDialogs)
    return changed
end

function startDialogSkip()
    vsyncListener = PCSX.Events.createEventListener("GPU::Vsync", pollDialogSkip)
    print("Dialog Skip Setup Complete")
end
