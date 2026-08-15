-- Shared helpers for navigation scripts.
local util = {}

function util.ensureDir(path)
    if path == "" or path == nil then
        return
    end
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

function util.readJSON(path)
    if not fs.exists(path) then
        return nil
    end
    local f = fs.open(path, "r")
    if not f then
        return nil
    end
    local raw = f.readAll()
    f.close()
    local ok, data = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(data) ~= "table" then
        return nil
    end
    return data
end

function util.writeJSON(path, data)
    local dir = string.match(path, "^(.*)/[^/]+$")
    if dir then
        util.ensureDir(dir)
    end
    local ok, encoded = pcall(textutils.serialiseJSON, data)
    if not ok then
        return false, encoded
    end
    local f = fs.open(path, "w")
    if not f then
        return false, "cannot open " .. path
    end
    f.write(encoded)
    f.close()
    return true
end

function util.openWireless()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem.isWireless and modem.isWireless() then
                if not rednet.isOpen(name) then
                    rednet.open(name)
                end
                return name
            end
        end
    end
    return nil
end

function util.openAllWiredModems()
    local opened = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem.isWireless and not modem.isWireless() then
                if not modem.isOpen(modem.getNameLocal and modem.getNameLocal() or "") then
                    -- wired modem: open for peripheral networking via peripheral methods; no rednet needed
                end
                opened[#opened + 1] = name
            end
        end
    end
    return opened
end

function util.wrapInventory(name)
    if not name then
        return nil
    end
    if not peripheral.isPresent(name) then
        return nil
    end
    if not peripheral.hasType(name, "inventory") then
        return nil
    end
    return peripheral.wrap(name)
end

function util.findInventories()
    local list = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "inventory") then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end

function util.clamp(x, lo, hi)
    if x < lo then
        return lo
    end
    if x > hi then
        return hi
    end
    return x
end

function util.now()
    return os.epoch("utc")
end

return util
