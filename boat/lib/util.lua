-- Shared helpers for boat scripts.
local util = {}

function util.clamp(x, lo, hi)
    if x < lo then
        return lo
    end
    if x > hi then
        return hi
    end
    return x
end

function util.ensureDir(path)
    if path == nil or path == "" then
        return
    end
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

function util.dirname(path)
    local d = string.match(path, "^(.*)/[^/]+$")
    return d or ""
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
    local dir = util.dirname(path)
    if dir ~= "" then
        util.ensureDir(dir)
    end
    local ok, encoded = pcall(textutils.serialiseJSON, data)
    if not ok then
        return false, tostring(encoded)
    end
    local f = fs.open(path, "w")
    if not f then
        return false, "cannot open " .. path
    end
    f.write(encoded)
    f.close()
    return true
end

function util.readFile(path)
    if not fs.exists(path) then
        return nil
    end
    local f = fs.open(path, "r")
    if not f then
        return nil
    end
    local raw = f.readAll()
    f.close()
    return raw
end

function util.writeFile(path, data)
    local dir = util.dirname(path)
    if dir ~= "" then
        util.ensureDir(dir)
    end
    local f = fs.open(path, "w")
    if not f then
        return false, "cannot open " .. path
    end
    f.write(data)
    f.close()
    return true
end

function util.now()
    if os.epoch then
        return os.epoch("utc") / 1000
    end
    return os.clock()
end

function util.deepCopy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = util.deepCopy(v)
    end
    return out
end

function util.httpGet(url)
    if not http then
        return nil, "http disabled"
    end
    local sep = string.find(url, "?", 1, true) and "&" or "?"
    local bust = sep .. "t=" .. tostring(os.epoch and os.epoch("utc") or os.clock())
    local res, err = http.get(url .. bust)
    if not res then
        res, err = http.get(url)
    end
    if not res then
        return nil, err or "http.get failed"
    end
    local body = res.readAll()
    res.close()
    return body
end

return util
