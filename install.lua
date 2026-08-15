-- Bootstrap / reinstall Amazeballs CC updater onto this computer.
-- Usage:
--   install              -- install or reinstall (always reopens file setup)
--   install pull         -- refresh updater + startup only, then pull (no setup UI)
local REPO_BASE = "https://raw.githubusercontent.com/gleeglor/amazeballs-cc/main/"

local function httpGet(url)
    local res, err = http.get(url)
    if not res then
        return nil, err or "http.get failed"
    end
    local body = res.readAll()
    res.close()
    return body
end

local function writeFile(path, data)
    local f = fs.open(path, "w")
    if not f then
        return false
    end
    f.write(data)
    f.close()
    return true
end

if not http then
    print("HTTP API is disabled. Ask the server admin to enable ComputerCraft http.")
    return
end

local args = { ... }
local skipSetup = false
for _, a in ipairs(args) do
    a = string.lower(tostring(a))
    if a == "pull" or a == "--pull" then
        skipSetup = true
    end
end

print("Downloading updater.lua...")
local updater, err = httpGet(REPO_BASE .. "updater.lua")
if not updater then
    print("Failed: " .. tostring(err))
    return
end
if not writeFile("/updater.lua", updater) then
    print("Could not write /updater.lua")
    return
end
print("Wrote /updater.lua")

local startup = [[
-- Managed by amazeballs-cc installer. Do not replace with role startups.
if not fs.exists("/updater.lua") then
    print("Missing updater.lua")
    return
end
shell.run("/updater.lua")
local f = fs.open("/cc_update.json", "r")
if f then
    local raw = f.readAll()
    f.close()
    local ok, cfg = pcall(textutils.unserialiseJSON, raw)
    if ok and type(cfg) == "table" and type(cfg.run) == "string" and cfg.run ~= "" then
        if fs.exists(cfg.run) or fs.exists("/" .. cfg.run) then
            shell.run(cfg.run)
        else
            print("autorun missing: " .. cfg.run)
        end
    end
end
]]

if not writeFile("/startup.lua", startup) then
    print("Could not write /startup.lua")
    return
end
print("Wrote /startup.lua")

if skipSetup then
    print("Pulling selected files...")
    shell.run("/updater.lua")
else
    print("Opening file selection (reinstall ok)...")
    shell.run("/updater.lua", "--setup")
end
