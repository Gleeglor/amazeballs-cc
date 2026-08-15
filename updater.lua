-- Amazeballs CC updater: tree setup, then pull selected files each run.
local REPO_BASE = "https://raw.githubusercontent.com/gleeglor/amazeballs-cc/main/"
local CONFIG_PATH = "/cc_update.json"
local CATALOG_URL = REPO_BASE .. "catalog.json"
local UPDATER_URL = REPO_BASE .. "updater.lua"

local PROTECTED = {
    ["startup.lua"] = true,
    ["startup"] = true,
    ["updater.lua"] = true,
    ["updater"] = true,
    ["install.lua"] = true,
    ["install"] = true,
    ["cc_update.json"] = true,
}

local function basename(path)
    return string.match(path, "([^/]+)$") or path
end

local function dirname(path)
    local d = string.match(path, "^(.*)/[^/]+$")
    return d or ""
end

local function joinPath(a, b)
    if a == "" or a == nil then
        return b
    end
    if b == "" or b == nil then
        return a
    end
    return a .. "/" .. b
end

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then
        return nil
    end
    local data = f.readAll()
    f.close()
    return data
end

local function writeFile(path, data)
    local dir = dirname(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local f = fs.open(path, "w")
    if not f then
        return false, "cannot open " .. path
    end
    f.write(data)
    f.close()
    return true
end

local function httpGet(url)
    -- Bust GitHub raw CDN cache (max-age=300) so new catalog files show up.
    local sep = string.find(url, "?", 1, true) and "&" or "?"
    local bust = sep .. "t=" .. tostring(os.epoch("utc"))
    local res, err = http.get(url .. bust)
    if not res then
        -- Fallback without query (some proxies dislike ?)
        res, err = http.get(url)
    end
    if not res then
        return nil, err or "http.get failed"
    end
    local body = res.readAll()
    res.close()
    return body
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then
        return nil
    end
    local raw = readFile(CONFIG_PATH)
    if not raw then
        return nil
    end
    local ok, cfg = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(cfg) ~= "table" then
        return nil
    end
    return cfg
end

local function saveConfig(cfg)
    local ok, encoded = pcall(textutils.serialiseJSON, cfg)
    if not ok then
        error("Failed to encode config: " .. tostring(encoded))
    end
    local success, err = writeFile(CONFIG_PATH, encoded)
    if not success then
        error(err)
    end
end

local function defaultDest(src, meta)
    if type(meta) == "table" and type(meta.dest) == "string" and meta.dest ~= "" then
        return meta.dest
    end
    return basename(src)
end

local function isProtectedDest(dest)
    return PROTECTED[dest] == true or PROTECTED[basename(dest)] == true
end

local function fetchCatalog()
    print("Fetching catalog...")
    local body, err = httpGet(CATALOG_URL)
    if not body then
        return nil, err
    end
    local ok, catalog = pcall(textutils.unserialiseJSON, body)
    if not ok or type(catalog) ~= "table" or type(catalog.tree) ~= "table" then
        return nil, "invalid catalog.json"
    end
    if type(catalog.base_url) == "string" and catalog.base_url ~= "" then
        REPO_BASE = catalog.base_url
        if not string.match(REPO_BASE, "/$") then
            REPO_BASE = REPO_BASE .. "/"
        end
    end
    return catalog
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function nodeChildren(node)
    local children = {}
    if type(node) ~= "table" then
        return children
    end
    for k, v in pairs(node) do
        if k ~= "dest" and k ~= "label" then
            children[k] = v
        end
    end
    return children
end

-- File = leaf with optional dest/label. Empty {} = placeholder directory.
local function isFileEntry(_, node)
    if type(node) ~= "table" then
        return true
    end
    if next(nodeChildren(node)) ~= nil then
        return false
    end
    if node.dest == nil and node.label == nil then
        return false
    end
    return true
end

local function selectedList(selected)
    local list = {}
    for src in pairs(selected) do
        list[#list + 1] = src
    end
    table.sort(list)
    return list
end

local function formatSelectedLine(selected, maxWidth)
    local list = selectedList(selected)
    if #list == 0 then
        return "Selected: (none)"
    end
    local line = "Selected: " .. table.concat(list, ", ")
    if #line <= maxWidth then
        return line
    end
    local out = "Selected: "
    for i, src in ipairs(list) do
        local piece = (i == 1) and src or (", " .. src)
        if #out + #piece + 8 > maxWidth then
            out = out .. " +" .. (#list - i + 1) .. " more"
            break
        end
        out = out .. piece
    end
    return out
end

local function pathDisplay(pathStack)
    if #pathStack == 0 then
        return "/"
    end
    return "/" .. table.concat(pathStack, "/")
end

local function folderPickCount(selected, folderName)
    local prefix = folderName .. "/"
    local n = 0
    for src in pairs(selected) do
        if src == folderName or string.sub(src, 1, #prefix) == prefix then
            n = n + 1
        end
    end
    return n
end

local function runSetup(catalog, existingCfg)
    local tree = catalog.tree
    local pathStack = {}
    local cursor = 1
    local selected = {}

    if type(existingCfg) == "table" and type(existingCfg.files) == "table" then
        for _, entry in ipairs(existingCfg.files) do
            if type(entry) == "table" and type(entry.src) == "string" then
                selected[entry.src] = {
                    src = entry.src,
                    dest = entry.dest or basename(entry.src),
                    label = entry.src,
                }
            end
        end
    end

    local function currentPath()
        if #pathStack == 0 then
            return ""
        end
        return table.concat(pathStack, "/")
    end

    local function buildRows()
        local kids = {}
        if #pathStack == 0 then
            for k, v in pairs(tree) do
                kids[k] = v
            end
        else
            local n = tree
            for _, name in ipairs(pathStack) do
                n = n[name]
            end
            if type(n) == "table" then
                for k, v in pairs(n) do
                    if k ~= "dest" and k ~= "label" then
                        kids[k] = v
                    end
                end
            end
        end

        local names = sortedKeys(kids)
        local rows = {}
        if #pathStack > 0 then
            rows[#rows + 1] = { kind = "up", label = ".." }
        end
        for _, name in ipairs(names) do
            local child = kids[name]
            local src = joinPath(currentPath(), name)
            if isFileEntry(name, child) then
                local dest = defaultDest(src, child)
                local label = (type(child) == "table" and child.label) or name
                rows[#rows + 1] = {
                    kind = "file",
                    name = name,
                    src = src,
                    dest = dest,
                    label = label,
                }
            else
                local picks = folderPickCount(selected, src)
                local label = name .. "/"
                if picks > 0 then
                    label = label .. " [" .. picks .. " selected]"
                end
                rows[#rows + 1] = {
                    kind = "dir",
                    name = name,
                    label = label,
                }
            end
        end
        rows[#rows + 1] = { kind = "done", label = "[DONE] save and continue" }
        return rows
    end

    local function draw()
        local rows = buildRows()
        if cursor < 1 then
            cursor = 1
        end
        if cursor > #rows then
            cursor = #rows
        end

        local w, h = term.getSize()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)

        print("Script setup  " .. pathDisplay(pathStack))
        print("move=arrows  toggle=space  open/done=enter")
        print(formatSelectedLine(selected, w))
        print(string.rep("-", w))

        local headerLines = 4
        local maxShow = math.max(1, h - headerLines)
        local start = math.max(1, cursor - maxShow + 1)
        local finish = math.min(#rows, start + maxShow - 1)

        for i = start, finish do
            local row = rows[i]
            local onCursor = (i == cursor)
            local prefix = onCursor and "> " or "  "
            local line

            if row.kind == "file" then
                local isOn = selected[row.src] ~= nil
                local mark = isOn and "[X]" or "[ ]"
                local destNote = ""
                if row.dest ~= row.name and row.dest ~= basename(row.src) then
                    destNote = " (as " .. row.dest .. ")"
                end
                line = prefix .. mark .. " " .. row.label .. destNote
                if onCursor then
                    term.setTextColor(colors.yellow)
                elseif isOn then
                    -- Checked items: bright green so picks stand out
                    term.setTextColor(colors.lime)
                else
                    term.setTextColor(colors.white)
                end
            else
                -- Folders, .., and DONE: white (not gray), yellow when focused
                line = prefix .. row.label
                if onCursor then
                    term.setTextColor(colors.yellow)
                else
                    term.setTextColor(colors.white)
                end
            end

            if #line > w then
                line = string.sub(line, 1, w)
            end
            print(line)
        end
        term.setTextColor(colors.white)
        return rows
    end

    while true do
        local rows = draw()
        local _, key = os.pullEvent("key")
        if key == keys.up then
            cursor = math.max(1, cursor - 1)
        elseif key == keys.down then
            cursor = math.min(#rows, cursor + 1)
        elseif key == keys.backspace then
            if #pathStack > 0 then
                table.remove(pathStack)
                cursor = 1
            end
        elseif key == keys.space then
            local row = rows[cursor]
            if row.kind == "file" then
                if isProtectedDest(row.dest) then
                    local _, th = term.getSize()
                    term.setCursorPos(1, th)
                    term.clearLine()
                    term.setTextColor(colors.red)
                    write("Protected: " .. row.dest)
                    term.setTextColor(colors.white)
                    sleep(1)
                elseif selected[row.src] then
                    selected[row.src] = nil
                else
                    selected[row.src] = {
                        src = row.src,
                        dest = row.dest,
                        label = row.label,
                    }
                end
            end
        elseif key == keys.enter then
            local row = rows[cursor]
            if row.kind == "done" then
                break
            elseif row.kind == "up" then
                table.remove(pathStack)
                cursor = 1
            elseif row.kind == "dir" then
                pathStack[#pathStack + 1] = row.name
                cursor = 1
            elseif row.kind == "file" then
                if not isProtectedDest(row.dest) then
                    if selected[row.src] then
                        selected[row.src] = nil
                    else
                        selected[row.src] = {
                            src = row.src,
                            dest = row.dest,
                            label = row.label,
                        }
                    end
                end
            end
        end
    end

    local files = {}
    for _, entry in pairs(selected) do
        files[#files + 1] = { src = entry.src, dest = entry.dest }
    end
    table.sort(files, function(a, b)
        return a.src < b.src
    end)

    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)

    if #files == 0 then
        print("Nothing selected. Keeping previous config (if any).")
        return false
    end

    print("Selected " .. #files .. " file(s).")
    print("Run on boot after update?")
    print("0) none")
    local dests = {}
    local seen = {}
    for _, f in ipairs(files) do
        if not seen[f.dest] then
            seen[f.dest] = true
            dests[#dests + 1] = f.dest
        end
    end
    table.sort(dests)

    local defaultRun = ""
    if type(existingCfg) == "table" and type(existingCfg.run) == "string" then
        defaultRun = existingCfg.run
    end
    local defaultIndex = 0
    for i, d in ipairs(dests) do
        local mark = (d == defaultRun) and " *" or ""
        print(i .. ") " .. d .. mark)
        if d == defaultRun then
            defaultIndex = i
        end
    end

    local promptDefault = defaultIndex
    write("Choice [" .. tostring(promptDefault) .. "]: ")
    local line = read()
    local choice
    if line == nil or line == "" then
        choice = promptDefault
    else
        choice = tonumber(line) or 0
    end
    local run = ""
    if choice >= 1 and choice <= #dests then
        run = dests[choice]
    end

    local cfg = {
        base_url = catalog.base_url or REPO_BASE,
        files = files,
        run = run,
    }
    saveConfig(cfg)
    print("Saved " .. CONFIG_PATH)
    return true
end

local function ensureParentDirs(path)
    local dir = dirname(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function pullFiles(cfg)
    local base = cfg.base_url or REPO_BASE
    if not string.match(base, "/$") then
        base = base .. "/"
    end
    local okCount, failCount = 0, 0
    for _, entry in ipairs(cfg.files or {}) do
        local src = entry.src
        local dest = entry.dest or basename(src)
        if isProtectedDest(dest) then
            print("Skip protected: " .. dest)
            failCount = failCount + 1
        else
            local url = base .. src
            write(src .. " to " .. dest .. " ... ")
            local body, err = httpGet(url)
            if not body then
                print("FAIL (" .. tostring(err) .. ")")
                failCount = failCount + 1
            else
                ensureParentDirs(dest)
                local success, werr = writeFile(dest, body)
                if success then
                    print("ok")
                    okCount = okCount + 1
                else
                    print("FAIL (" .. tostring(werr) .. ")")
                    failCount = failCount + 1
                end
            end
        end
    end
    print(okCount .. " ok, " .. failCount .. " failed")
    return failCount == 0
end

local function selfUpdate()
    local body, err = httpGet(UPDATER_URL)
    if not body then
        return false, err
    end
    local current = readFile("/updater.lua") or readFile("updater.lua")
    if current == body then
        return true, "unchanged"
    end
    local success, werr = writeFile("/updater.lua", body)
    if not success then
        return false, werr
    end
    return true, "updated"
end

local function wantsSetup(args)
    for _, a in ipairs(args) do
        a = string.lower(tostring(a))
        if a == "--setup" or a == "setup" or a == "reinstall" or a == "--reinstall" then
            return true
        end
    end
    return false
end

local function main(args)
    args = args or {}
    local forceSetup = wantsSetup(args)

    if not http then
        print("HTTP API is disabled on this server.")
        return
    end

    local cfg = loadConfig()
    if forceSetup or not cfg then
        local catalog, err = fetchCatalog()
        if not catalog then
            print("Could not load catalog: " .. tostring(err))
            return
        end
        if not runSetup(catalog, cfg) then
            cfg = loadConfig()
            if not cfg then
                return
            end
        else
            cfg = loadConfig()
            if not cfg then
                print("Config missing after setup.")
                return
            end
        end
    end

    if not forceSetup then
        local suOk, suMsg = selfUpdate()
        if suOk and suMsg == "updated" then
            print("Updater self-updated.")
        end
    end

    pullFiles(cfg)
end

local args = { ... }
main(args)
