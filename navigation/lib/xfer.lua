-- Inventory pull/push between two peripherals with optional filters.
local filters = require("filters")

local xfer = {}

local function invOf(name)
    if type(name) ~= "string" then
        return nil
    end
    if not peripheral.isPresent(name) then
        return nil
    end
    return peripheral.wrap(name)
end

--- Move matching items from `fromName` to `toName`.
-- @param limit max items to move (nil = until empty/full)
-- @param allowList item id list or nil for all
-- @return moved count, reason string
function xfer.moveFiltered(fromName, toName, allowList, limit)
    local from = invOf(fromName)
    local to = invOf(toName)
    if not from then
        return 0, "missing from inventory: " .. tostring(fromName)
    end
    if not to then
        return 0, "missing to inventory: " .. tostring(toName)
    end
    if not from.pushItems then
        return 0, "from has no pushItems"
    end

    local moved = 0
    local limitLeft = limit
    local slots = filters.matchingSlots(from, allowList)
    if #slots == 0 then
        return 0, "no matching items"
    end

    for _, entry in ipairs(slots) do
        if limitLeft and limitLeft <= 0 then
            break
        end
        local count = entry.count
        if limitLeft and count > limitLeft then
            count = limitLeft
        end
        local n = from.pushItems(toName, entry.slot, count)
        if type(n) == "number" and n > 0 then
            moved = moved + n
            if limitLeft then
                limitLeft = limitLeft - n
            end
        end
    end

    if moved == 0 then
        return 0, "nothing moved (full or blocked)"
    end
    return moved, "ok"
end

--- Keep moving until no progress, timeout, or predicate.
function xfer.pump(fromName, toName, allowList, opts)
    opts = opts or {}
    local timeout = opts.timeout or 30
    local idleLimit = opts.idle_rounds or 3
    local deadline = os.clock() + timeout
    local total = 0
    local idle = 0

    while os.clock() < deadline do
        local n, reason = xfer.moveFiltered(fromName, toName, allowList, opts.batch)
        if n > 0 then
            total = total + n
            idle = 0
        else
            idle = idle + 1
            if idle >= idleLimit then
                return total, reason or "idle"
            end
        end
        sleep(opts.sleep or 0.2)
    end
    return total, "timeout"
end

--- Count matching items in an inventory.
function xfer.countMatching(invName, allowList)
    local inv = invOf(invName)
    if not inv then
        return 0
    end
    local slots = filters.matchingSlots(inv, allowList)
    local n = 0
    for _, s in ipairs(slots) do
        n = n + (s.count or 0)
    end
    return n
end

return xfer
