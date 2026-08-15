-- Item allowlist matching for inventory slots.
local filters = {}

local function normalizeId(name)
    if type(name) ~= "string" then
        return nil
    end
    return string.lower(name)
end

--- Build a set from a list of item ids (e.g. "minecraft:iron_ore").
function filters.setFromList(list)
    local set = {}
    if type(list) ~= "table" then
        return set
    end
    for _, id in ipairs(list) do
        local n = normalizeId(id)
        if n then
            set[n] = true
        end
    end
    return set
end

function filters.matches(itemDetail, allowSet)
    if not itemDetail then
        return false
    end
    if not allowSet or next(allowSet) == nil then
        return true -- empty filter = allow all
    end
    local name = normalizeId(itemDetail.name)
    return name ~= nil and allowSet[name] == true
end

--- List slots in inventory that match allowlist. inv = wrapped peripheral.
function filters.matchingSlots(inv, allowList)
    local allowSet = filters.setFromList(allowList)
    local slots = {}
    if not inv or not inv.list then
        return slots
    end
    local listed = inv.list()
    if not listed then
        return slots
    end
    for slot, stack in pairs(listed) do
        if stack and stack.name then
            local detail = { name = stack.name, count = stack.count }
            if inv.getItemDetail then
                local d = inv.getItemDetail(slot)
                if d then
                    detail = d
                end
            end
            if filters.matches(detail, allowSet) then
                slots[#slots + 1] = {
                    slot = slot,
                    name = detail.name,
                    count = detail.count or stack.count,
                }
            end
        end
    end
    table.sort(slots, function(a, b)
        return a.slot < b.slot
    end)
    return slots
end

return filters
