-- Amazeballs CC updater: one-time tree setup, then pull selected files each run.
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
    local res, err = http.get(url)
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

local function selectionKey(src)
    return src
end

local function runSetup(catalog)
    local tree = catalog.tree
    local pathStack = {} -- list of names from root
    local cursor = 1
    local selected = {} -- src -> { src, dest, label }

    local function currentNode()
        local node = tree
        for _, name in ipairs(pathStack) do
            node = nodeChildren(node)[name] or node[name]
            if not node then
                return {}
            end
        end
        return node
    end

    local function currentPath()
        if #pathStack == 0 then
            return ""
        end
        return table.concat(pathStack, "/")
    end

    local function buildRows()
        local node = currentNode()
        local kids = nodeChildren(node)
        -- If we're at a file-meta-only confusion, kids may be empty for empty dirs
        if type(node) == "table" and next(kids) == nil and (node.dest or node.label) then
            kids = {}
        end
        -- For root/dirs, catalog stores children directly on the node
        if #pathStack == 0 then
            kids = {}
            for k, v in pairs(tree) do
                kids[k] = v
            end
        else
            kids = {}
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
        rows[#rows + 1] = { kind = "done", label = "[Done — save selection]" }
        if #pathStack > 0 then
            rows[#rows + 1] = { kind = "up", label = "[..]" }
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
                rows[#rows + 1] = {
                    kind = "dir",
                    name = name,
                    label = name .. "/",
                }
            end
        end
        return rows
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    while true do
        local rows = buildRows()
        if cursor < 1 then
            cursor = 1
        end
        if cursor > #rows then
            cursor = #rows
        end

        term.clear()
        term.setCursorPos(1, 1)
        print("CC updater setup")
        print("Path: /" .. currentPath())
        print("Space=toggle  Enter=open/Done  Backspace=up")
        print(string.rep("-", 40))

        local w, h = term.getSize()
        local maxShow = math.max(1, h - 6)
        local start = math.max(1, cursor - maxShow + 1)
        local finish = math.min(#rows, start + maxShow - 1)

        for i = start, finish do
            local row = rows[i]
            local prefix = (i == cursor) and "> " or "  "
            if row.kind == "file" then
                local mark = selected[selectionKey(row.src)] and "[x]" or "[ ]"
                local destNote = row.dest ~= row.name and (" -> " .. row.dest) or ""
                print(prefix .. mark .. " " .. row.label .. destNote)
            else
                print(prefix .. row.label)
            end
        end

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
                    print("Protected dest: " .. row.dest)
                    sleep(1.2)
                else
                    local k = selectionKey(row.src)
                    if selected[k] then
                        selected[k] = nil
                    else
                        selected[k] = {
                            src = row.src,
                            dest = row.dest,
                            label = row.label,
                        }
                    end
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
                -- Enter also toggles files for convenience
                if not isProtectedDest(row.dest) then
                    local k = selectionKey(row.src)
                    if selected[k] then
                        selected[k] = nil
                    else
                        selected[k] = {
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

    if #files == 0 then
        print("Nothing selected. Setup cancelled.")
        return false
    end

    -- Ask which program to run on boot
    term.clear()
    term.setCursorPos(1, 1)
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
    for i, d in ipairs(dests) do
        print(i .. ") " .. d)
    end
    write("Choice [0]: ")
    local line = read()
    local choice = tonumber(line) or 0
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
            write("GET " .. src .. " -> " .. dest .. " ... ")
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
    print(string.format("Done: %d ok, %d failed", okCount, failCount))
    return failCount == 0
end

local function selfUpdate()
    -- Download latest updater.lua into a temp name, then replace if different.
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

local function main(args)
    args = args or {}
    local forceSetup = false
    for _, a in ipairs(args) do
        if a == "--setup" or a == "setup" then
            forceSetup = true
        end
    end

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
        if not runSetup(catalog) then
            return
        end
        cfg = loadConfig()
        if not cfg then
            print("Config missing after setup.")
            return
        end
    end

    local suOk, suMsg = selfUpdate()
    if suOk and suMsg == "updated" then
        print("Updater self-updated.")
    end

    pullFiles(cfg)
end

local args = { ... }
main(args)
