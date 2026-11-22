--[[
    ABOVE Hub - unified loader (Auto Farm + Island Builder + Pollinator)

    Usage (optional config first, then the one-liner):

        getgenv().ABOVE_CONFIG = {
            WebhookUrl = "",        -- optional: pre-fills the Discord webhook input (never put it in the repo)
            Branch     = "main",    -- optional: repo branch / tag / commit
            NoCache    = false,     -- optional: bypass raw.githubusercontent caching while developing
            LocalPath  = nil,       -- optional: e.g. "Above-Script" to load modules from the executor workspace via readfile
        }
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Kou1503/Above-Script/main/loader.lua"))()

    This file holds NO secrets. The webhook URL lives only in the user's executor workspace
    (ABOVE_Obsidian/secrets/webhook.txt) or in getgenv().ABOVE_CONFIG, never in GitHub.

    Module convention: every file in Modules/ returns   function(State) ... return exports end
    Import(path) fetches it once, runs it with the shared State and caches the exports.
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local genv = (getgenv and getgenv()) or _G

------------------------------------------------------------------------------------------
-- Re-execution guard: tear down any previous copy (unified or the old standalone Builder)
------------------------------------------------------------------------------------------
if type(genv.ScriptState) == "table" and type(genv.ScriptState.Unload) == "function" then
    pcall(genv.ScriptState.Unload)
end
if type(genv.__ABOVE_BUILDER) == "table" and type(genv.__ABOVE_BUILDER.Unload) == "function" then
    pcall(genv.__ABOVE_BUILDER.Unload)
end

------------------------------------------------------------------------------------------
-- User config (from getgenv, never hardcoded)
------------------------------------------------------------------------------------------
local userConfig = type(genv.ABOVE_CONFIG) == "table" and genv.ABOVE_CONFIG or {}
local REPO_OWNER, REPO_NAME = "Kou1503", "Above-Script"
local BRANCH = type(userConfig.Branch) == "string" and userConfig.Branch ~= "" and userConfig.Branch or "main"
local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(REPO_OWNER, REPO_NAME, BRANCH)

local SAVE_FOLDER = "ABOVE_Obsidian"
local SECRETS_FOLDER = SAVE_FOLDER .. "/secrets"
local WEBHOOK_FILE = SECRETS_FOLDER .. "/webhook.txt"

------------------------------------------------------------------------------------------
-- Shared state
------------------------------------------------------------------------------------------
local State = {
    Version = "1.0.0",
    Loaded = false,
    Unloaded = false,
    BaseUrl = BASE_URL,
    SaveFolder = SAVE_FOLDER,

    Config = userConfig,

    -- Secrets: placeholders only. Filled at runtime from the local file or getgenv config.
    Secrets = {
        WebhookUrl = "",        -- Discord webhook for Farm reports / disconnect alerts / diagnostics
        File = WEBHOOK_FILE,
    },

    Services = {},
    Game = {},
    UI = { Tabs = {}, Groups = {} },

    Activity = { owner = nil, since = 0 },   -- "farm" | "builder" | "pollinator"

    Farm = {},
    Builder = {},
    Pollinator = {},

    Modules = {},           -- path -> exports
    ModuleErrors = {},      -- path -> error string
    Connections = {},
    Cleanup = {},           -- functions run (newest first) on Unload
}
genv.ScriptState = State

-- Real injects STATE into live-reload scripts; under loadstring it is nil.
local realState = rawget(genv, "STATE") or STATE
function State.alive()
    if State.Unloaded then return false end
    return realState == nil or type(realState.alive) ~= "function" or realState.alive()
end

function State.Track(connection)
    if connection then table.insert(State.Connections, connection) end
    return connection
end

function State.OnCleanup(fn)
    if type(fn) == "function" then table.insert(State.Cleanup, fn) end
end

------------------------------------------------------------------------------------------
-- Activity lock: only one feature moves the character / owns the hotbar at a time
------------------------------------------------------------------------------------------
function State.Acquire(owner)
    local current = State.Activity.owner
    if current ~= nil and current ~= owner then return false, current end
    State.Activity.owner, State.Activity.since = owner, os.clock()
    return true
end

function State.Release(owner)
    if State.Activity.owner == owner then State.Activity.owner = nil end
end

function State.BusyByOther(owner)
    local current = State.Activity.owner
    return current ~= nil and current ~= owner, current
end

------------------------------------------------------------------------------------------
-- Secrets: local file <-> State.Secrets (never saved into SaveManager profiles)
------------------------------------------------------------------------------------------
local function ensureFolder(path)
    if type(isfolder) ~= "function" or type(makefolder) ~= "function" then return end
    local built = ""
    for part in path:gmatch("[^/]+") do
        built = built == "" and part or (built .. "/" .. part)
        if not isfolder(built) then pcall(makefolder, built) end
    end
end

function State.LoadSecrets()
    if type(isfile) == "function" and type(readfile) == "function" then
        local ok, content = pcall(function() return isfile(WEBHOOK_FILE) and readfile(WEBHOOK_FILE) or nil end)
        if ok and type(content) == "string" then
            State.Secrets.WebhookUrl = content:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    -- getgenv config wins over the file when given
    if type(userConfig.WebhookUrl) == "string" and userConfig.WebhookUrl ~= "" then
        State.Secrets.WebhookUrl = userConfig.WebhookUrl
    end
    return State.Secrets.WebhookUrl
end

function State.SaveWebhook(url)
    url = type(url) == "string" and url or ""
    State.Secrets.WebhookUrl = url
    if type(writefile) ~= "function" then return false, "This executor has no writefile." end
    ensureFolder(SECRETS_FOLDER)
    local ok, err = pcall(writefile, WEBHOOK_FILE, url)
    return ok, err
end

State.LoadSecrets()

------------------------------------------------------------------------------------------
-- Import(path): fetch + run a module once, cache its exports
------------------------------------------------------------------------------------------
local function fetchSource(path)
    local localRoot = userConfig.LocalPath
    if type(localRoot) == "string" and localRoot ~= "" and type(readfile) == "function" then
        local ok, source = pcall(readfile, localRoot .. "/" .. path)
        if ok and type(source) == "string" and source ~= "" then return source end
    end
    local url = BASE_URL .. path
    if userConfig.NoCache then url ..= "?t=" .. tostring(os.time()) .. tostring(math.random(1000, 9999)) end
    local ok, source = pcall(game.HttpGet, game, url)
    if not ok then return nil, "HttpGet failed for " .. url .. ": " .. tostring(source) end
    if type(source) ~= "string" or source == "" or source:sub(1, 3) == "404" then
        return nil, "Empty or missing file: " .. url
    end
    return source
end

local function Import(path)
    if State.Modules[path] ~= nil then return State.Modules[path] end
    local source, fetchErr = fetchSource(path)
    if not source then error(fetchErr, 2) end
    local chunk, compileErr = loadstring(source, "=" .. path)
    if not chunk then error("Compile error in " .. path .. ": " .. tostring(compileErr), 2) end
    local result = chunk()
    if type(result) == "function" then result = result(State) end
    if result == nil then result = true end
    State.Modules[path] = result
    return result
end
State.Import = Import

-- pcall wrapper used for the load order below: one broken module never kills the others
local function TryImport(path)
    local ok, result = pcall(Import, path)
    if not ok then
        State.ModuleErrors[path] = tostring(result)
        warn("[ABOVE Hub] " .. path .. " failed: " .. tostring(result))
        return nil, result
    end
    return result
end
State.TryImport = TryImport

------------------------------------------------------------------------------------------
-- Services + game modules (shared by every module)
------------------------------------------------------------------------------------------
do
    local Sv = State.Services
    for _, name in ipairs({ "Players", "RunService", "CollectionService", "ReplicatedStorage", "HttpService",
        "VirtualUser", "GuiService", "PathfindingService", "Lighting" }) do
        Sv[name] = game:GetService(name)
    end
    local G = State.Game
    G.LocalPlayer = Sv.Players.LocalPlayer
    G.Remotes = Sv.ReplicatedStorage:WaitForChild("Remotes")
    G.Shared = Sv.ReplicatedStorage:WaitForChild("Shared")
    G.Controllers = G.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
    G.HotbarController = require(G.Controllers:WaitForChild("HotbarController"))
end

------------------------------------------------------------------------------------------
-- One shared Obsidian UI (pinned commit from the Farm script)
------------------------------------------------------------------------------------------
local OBSIDIAN_COMMIT = "67c9cde7647456d60eec215257e938fbbe8688be"
local obsidianRepo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/" .. OBSIDIAN_COMMIT .. "/"
local obsidianMain = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"

local function loadRemote(primary, fallback)
    local ok, result = pcall(function() return loadstring(game:HttpGet(primary))() end)
    if ok and result then return result end
    if fallback then
        warn("[ABOVE Hub] " .. primary .. " failed, using " .. fallback)
        return loadstring(game:HttpGet(fallback))()
    end
    error(result)
end

local Library = loadRemote(obsidianRepo .. "Library.lua")
local SaveManager = loadRemote(obsidianRepo .. "addons/SaveManager.lua")
local ThemeManager = loadRemote(obsidianRepo .. "addons/ThemeManager.lua", obsidianMain .. "addons/ThemeManager.lua")

local Window = Library:CreateWindow({
    Title = "ABOVE Hub",
    Footer = "auto farm / build / pollinate",
    Size = UDim2.fromOffset(620, 560),
    Center = true,
    AutoShow = true,
    Resizable = true,
    ToggleKeybind = Enum.KeyCode.U,
    ShowCustomCursor = false,
    Animations = false,
})

local UI = State.UI
UI.Library, UI.Window = Library, Window
UI.SaveManager, UI.ThemeManager = SaveManager, ThemeManager
UI.Options, UI.Toggles = Library.Options, Library.Toggles
UI.IgnoreIndexes = {}      -- modules append transient control IDs; Settings applies them

function UI.notify(title, content, time)
    pcall(function() Library:Notify({ Title = title, Description = content, Time = time or 4 }) end)
end

-- Tabs are created here, in sidebar order, so the layout is stable even if a module fails.
local tabOrder = {
    { "Combat",     "Combat",     "swords" },
    { "Gathering",  "Gathering",  "pickaxe" },
    { "Collect",    "Collect",    "gem" },
    { "Priority",   "Priority",   "list-ordered" },
    { "Movement",   "Movement",   "move" },
    { "Webhook",    "Webhook",    "bell" },
    { "Build",      "Build",      "hammer" },
    { "Plant",      "Planter",    "flower-2" },
    { "Schem",      "Schematic",  "clipboard" },
    { "Run",        "Run",        "play" },
    { "Pollen",     "Pollinator", "flower" },
    { "Settings",   "Settings",   "settings" },
}
for _, t in ipairs(tabOrder) do
    UI.Tabs[t[1]] = Window:AddTab(t[2], t[3])
end

------------------------------------------------------------------------------------------
-- Unified unload (single OnUnload handler for every feature)
------------------------------------------------------------------------------------------
function State.Unload()
    if State.Unloaded then return end
    State.Unloaded = true
    for i = #State.Cleanup, 1, -1 do
        local ok, err = pcall(State.Cleanup[i])
        if not ok then warn("[ABOVE Hub] cleanup error: " .. tostring(err)) end
    end
    State.Cleanup = {}
    for _, c in ipairs(State.Connections) do pcall(function() c:Disconnect() end) end
    State.Connections = {}
    State.Activity.owner = nil
    if not Library.Unloaded then pcall(function() Library:Unload() end) end
    if genv.__ABOVE_BUILDER and genv.__ABOVE_BUILDER.__unified then genv.__ABOVE_BUILDER = nil end
    if genv.ScriptState == State then genv.ScriptState = nil end
end
Library:OnUnload(function() State.Unload() end)

if realState and type(realState.onCleanup) == "function" then
    pcall(realState.onCleanup, State.Unload)
end

------------------------------------------------------------------------------------------
-- Load order
------------------------------------------------------------------------------------------
local function loadGroup(name, paths, tabsForMessage)
    for _, path in ipairs(paths) do
        local _, err = TryImport(path)
        if err then
            for _, key in ipairs(tabsForMessage or {}) do
                pcall(function()
                    UI.Tabs[key]:AddLeftGroupbox(name .. " unavailable", "triangle-alert")
                        :AddLabel(name .. " did not load: " .. tostring(err), true)
                end)
            end
            UI.notify("ABOVE Hub", name .. " failed to load. See the console.", 6)
            return false
        end
    end
    return true
end

local farmOk = loadGroup("Auto Farm", {
    "Modules/Farm/Config.lua",
    "Modules/Farm/Diagnostics.lua",
    "Modules/Farm/Webhook.lua",
    "Modules/Farm/Cache.lua",
    "Modules/Farm/Targeting.lua",
    "Modules/Farm/Movement.lua",
    "Modules/Farm/Combat.lua",
    "Modules/Farm/Catcher.lua",
    "Modules/Farm/Tabs.lua",
}, { "Combat", "Gathering", "Collect", "Priority", "Movement", "Webhook" })

-- Builder needs your island; failing here leaves the Farm untouched.
local builderOk = loadGroup("Island Builder", {
    "Modules/Builder/Island.lua",
    "Modules/Builder/Region.lua",
    "Modules/Builder/Planner.lua",
    "Modules/Builder/Executor.lua",
    "Modules/Builder/Tabs.lua",
}, { "Build", "Plant", "Schem", "Run" })

if builderOk then
    loadGroup("Pollinator", {
        "Modules/Pollinator/Pollinator.lua",
        "Modules/Pollinator/Fps.lua",
        "Modules/Pollinator/Tabs.lua",
    }, { "Pollen" })
else
    pcall(function()
        UI.Tabs.Pollen:AddLeftGroupbox("Pollinator unavailable", "triangle-alert")
            :AddLabel("The Pollinator needs the Island Builder, which did not load. Join your island and run the script again.", true)
    end)
end

-- Settings last: it hooks autosave onto every control that now exists, then loads the autoload profile.
loadGroup("Settings", { "Modules/Shared/Settings.lua" }, { "Settings" })

-- Farm loop starts only after the profile is applied, and only if every Farm module loaded.
if farmOk then TryImport("Modules/Farm/Loop.lua") end

State.Loaded = true
local failed = 0
for _ in pairs(State.ModuleErrors) do failed += 1 end
UI.notify("ABOVE Hub", failed == 0 and "Loaded. Press U to toggle the menu."
    or ("Loaded with %d module error(s). See the console."):format(failed), 5)

return State
