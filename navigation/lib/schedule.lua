-- Port schedule slot selection by mode and priority.
local schedule = {}

local function slotDirection(slot)
    return slot.direction or slot.mode or "export"
end

--- Filter schedule slots by port mode (export|import|both).
function schedule.eligible(slots, mode)
    mode = mode or "both"
    local out = {}
    if type(slots) ~= "table" then
        return out
    end
    for _, slot in ipairs(slots) do
        local dir = slotDirection(slot)
        if mode == "both" or mode == dir then
            out[#out + 1] = slot
        end
    end
    return out
end

--- Sort by priority ascending (lower number = first). Stable by name.
function schedule.sortByPriority(slots)
    local copy = {}
    for i, s in ipairs(slots) do
        copy[i] = s
    end
    table.sort(copy, function(a, b)
        local pa = a.priority or 100
        local pb = b.priority or 100
        if pa ~= pb then
            return pa < pb
        end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return copy
end

--- Ordered list of slots to run for this dock visit.
function schedule.plan(config)
    local mode = (config and config.mode) or "both"
    local slots = (config and config.schedule) or {}
    return schedule.sortByPriority(schedule.eligible(slots, mode))
end

return schedule
