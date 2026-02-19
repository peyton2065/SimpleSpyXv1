--[[
    RemoteSpy.lua  v7  --  Xeno Executor compatible.
    Paste into Xeno's script tab and execute.

    DEBUG_NAMECALL (in CFG): when true, every __namecall fires a gold [NC] row.
    Use this to confirm the hook is working. Set false once confirmed.
]]

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local CFG = {
    MAX_LOG_LINES  = 300,
    WINDOW_W       = 720,
    WINDOW_H       = 460,
    WINDOW_X       = 60,
    WINDOW_Y       = 60,
    FONT_SIZE      = 13,
    ROW_H          = 22,
    TRUNCATE_DEPTH = 4,

    -- Only relevant when using a namecall hook (Strategies 1-3).
    -- Per-instance scan (Strategy 5) does not use __namecall so this has no effect.
    DEBUG_NAMECALL = false,

    DARK_BG    = Color3.fromRGB(24,  24,  30),
    PANEL_BG   = Color3.fromRGB(32,  32,  40),
    ACCENT     = Color3.fromRGB(94,  129, 244),
    TEXT_COLOR = Color3.fromRGB(220, 220, 230),
    ENTRY_EVEN = Color3.fromRGB(28,  28,  36),
    ENTRY_ODD  = Color3.fromRGB(34,  34,  44),
    HIGHLIGHT  = Color3.fromRGB(80,  110, 220),
    BTN_DIM    = Color3.fromRGB(60,  60,  80),
    BTN_GREEN  = Color3.fromRGB(40,  160, 80),
    BTN_RED    = Color3.fromRGB(160, 60,  60),
    DBG_COLOR  = Color3.fromRGB(100, 95,  20),  -- dark gold for debug [NC] rows
}

-- =============================================================================
-- INTERNAL STATE
-- =============================================================================
local logs         = {}
local selectedIdx  = nil
local excludeNames = {}
local blockNames   = {}
local excludeInst  = {}
local blockInst    = {}
local spyActive    = true
local frameVisible = true

-- =============================================================================
-- SERVICES
-- =============================================================================
local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")

local lp = Players.LocalPlayer
if not lp then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    lp = Players.LocalPlayer
end

local playerGui = lp:WaitForChild("PlayerGui", 10)
if not playerGui then
    error("[RemoteSpy] PlayerGui not found.")
end

-- Returns true if `instance` lives inside another player's character or Player object.
-- Uses GetPlayerFromCharacter to correctly handle Workspace character models,
-- which are plain Model instances (not Player objects) named after the player.
local function isOtherPlayerDescendant(instance)
    local obj = instance
    while obj and obj ~= game do
        -- GetPlayerFromCharacter returns the Player if this Model is their character
        local ok, player = pcall(function() return Players:GetPlayerFromCharacter(obj) end)
        if ok and player and player ~= lp then return true end
        -- Also catch instances directly under the Player object itself
        if obj:IsA("Player") and obj ~= lp then return true end
        obj = obj.Parent
    end
    return false
end

-- =============================================================================
-- COMPAT SHIMS
-- =============================================================================
local function mathRound(n) return math.floor(n + 0.5) end

local function copyToClipboard(text)
    if setclipboard then pcall(setclipboard, tostring(text)) end
end

-- clonefunction makes a Lua-level bytecode copy.  hookfunction() requires this;
-- newcclosure() produces a C closure which hookfunction() silently rejects.
-- Accept common aliases.
local cloneFn = clonefunction or clonefunc

-- wrapCClosure: wrap a Lua function in a C closure for namecall hooks.
-- Falls back to the original function if newcclosure is unavailable.
local function wrapCClosure(fn)
    if newcclosure then
        local ok, result = pcall(newcclosure, fn)
        if ok and result then return result end
    end
    return fn
end

-- =============================================================================
-- SERIALISER
-- =============================================================================
local function serialize(val, depth)
    depth = depth or 0
    local t = typeof(val)
    if t == "nil"     then return "nil"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number" then
        if val ~= val then return "nan" end
        if math.floor(val) == val then return tostring(math.floor(val)) end
        return string.format("%.3f", val)
    elseif t == "string"  then return string.format("%q", val)
    elseif t == "Vector3" then
        return string.format("Vector3.new(%g,%g,%g)", val.X, val.Y, val.Z)
    elseif t == "Vector2" then
        return string.format("Vector2.new(%g,%g)", val.X, val.Y)
    elseif t == "CFrame" then
        local p = val.Position
        local rx, ry, rz = val:ToEulerAnglesXYZ()
        return string.format("CFrame.new(%g,%g,%g) rot(%gdeg,%gdeg,%gdeg)",
            p.X, p.Y, p.Z, math.deg(rx), math.deg(ry), math.deg(rz))
    elseif t == "Color3" then
        return string.format("Color3.fromRGB(%d,%d,%d)",
            mathRound(val.R*255), mathRound(val.G*255), mathRound(val.B*255))
    elseif t == "UDim2" then
        return string.format("UDim2.new(%g,%g,%g,%g)",
            val.X.Scale, val.X.Offset, val.Y.Scale, val.Y.Offset)
    elseif t == "Instance" then
        local ok, path = pcall(function() return val:GetFullName() end)
        return ok and ("[" .. val.ClassName .. "] " .. path)
                   or ("[" .. val.ClassName .. "] (destroyed)")
    elseif t == "table" then
        if depth >= CFG.TRUNCATE_DEPTH then return "{...}" end
        local parts = {}
        local isArr = (#val > 0)
        for k, v in (isArr and ipairs or pairs)(val) do
            local prefix = isArr and "" or (tostring(k) .. "=")
            table.insert(parts, prefix .. serialize(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "EnumItem"  then return tostring(val)
    elseif t == "function"  then return "function(...)"
    else
        local ok, s = pcall(tostring, val)
        return ok and s or ("[" .. t .. "]")
    end
end

local function formatArgs(argTable)
    local parts = {}
    for i = 1, #argTable do parts[i] = serialize(argTable[i]) end
    return table.concat(parts, ", ")
end

-- =============================================================================
-- FILTER HELPERS
-- =============================================================================
local function isExcluded(remote)
    if excludeInst[remote] then return true end
    local n = remote.Name
    for pat in pairs(excludeNames) do
        if n:find(pat, 1, true) then return true end
    end
    return false
end

local function isBlocked(remote)
    if blockInst[remote] then return true end
    local n = remote.Name
    for pat in pairs(blockNames) do
        if n:find(pat, 1, true) then return true end
    end
    return false
end

-- =============================================================================
-- LOG MANAGER
-- =============================================================================
local onNewLog = nil  -- assigned after UI is built

local function pushLog(entry)
    if #logs >= CFG.MAX_LOG_LINES then table.remove(logs, 1) end
    table.insert(logs, entry)
    if onNewLog then pcall(onNewLog, #logs, entry) end
end

-- Remote classes we care about.
-- BUGFIX: added "UnreliableRemoteEvent" -- it has a DIFFERENT ClassName from
-- "RemoteEvent" and was silently filtered out in every previous version.
local REMOTE_CLASSES = {
    RemoteEvent           = true,
    RemoteFunction        = true,
    UnreliableRemoteEvent = true,
    BindableEvent         = true,
    BindableFunction      = true,
}

-- Core log function called by every hook strategy.
local function logRemote(self, methodName, args)
    if not spyActive then return end

    local clsOk, cls = pcall(function() return self.ClassName end)
    if not clsOk or not REMOTE_CLASSES[cls] then return end

    if isBlocked(self)  then return end
    if isExcluded(self) then return end

    local pathOk, path = pcall(function() return self:GetFullName() end)
    path = (pathOk and path) or self.Name

    -- Log format:  [ClassName] Full.Path.Name  :MethodName(args)
    -- The space + colon separator lets extractPath() and generateCode()
    -- reliably parse it back out.
    pushLog("[" .. cls .. "] " .. path .. "  :" .. methodName .. "(" .. formatArgs(args) .. ")")
end

-- =============================================================================
-- HOOK REPLACEMENT FUNCTIONS  (Strategy 2 / hookfunction only)
-- Defined as top-level Lua functions so clonefunction() can copy them cleanly.
-- They call through to the originals captured as upvalues after hookfunction()
-- returns them.
-- =============================================================================
local origFireServer
local origInvokeServer
local origFireAllClients
local origFireClient
local origUnreliableFireServer

local function newFireServer(self, ...)
    logRemote(self, "FireServer", {...})
    return origFireServer(self, ...)
end

local function newInvokeServer(self, ...)
    logRemote(self, "InvokeServer", {...})
    return origInvokeServer(self, ...)
end

local function newFireAllClients(self, ...)
    logRemote(self, "FireAllClients", {...})
    return origFireAllClients(self, ...)
end

local function newFireClient(self, ...)
    logRemote(self, "FireClient", {...})
    return origFireClient(self, ...)
end

-- BUGFIX: was logging "FireServer" -- should be "FireUnreliable"
local function newUnreliableFireServer(self, ...)
    logRemote(self, "FireUnreliable", {...})
    return origUnreliableFireServer(self, ...)
end

-- =============================================================================
-- HOOK INSTALLATION
-- All strategies now report their individual result so the startup log tells
-- you exactly which strategy ran and why others failed.
-- =============================================================================
local hookInstalled    = false
local hookStrategyName = "none"
local hookFailReasons  = {}

-- makeNamecallHook: build the __namecall replacement function used by
-- Strategies 1, 3, and 4.  Takes the original __namecall as a parameter so
-- each strategy can safely pass its own captured original without sharing state.
local function makeNamecallHook(originalNamecall)
    return wrapCClosure(function(self, ...)
        -- Read the method name. pcall guards against executors where it throws.
        local method = ""
        if getnamecallmethod then
            pcall(function() method = getnamecallmethod() end)
        end

        -- ----------------------------------------------------------------
        -- DEBUG MODE: log every single namecall (yellow rows in the UI).
        -- This is the most reliable way to confirm the hook is actually
        -- firing.  If you see yellow rows, the hook works; the issue is
        -- just the class/method filter.  If you see NO yellow rows after
        -- in-game interactions (click buttons, walk around), the hook is
        -- not firing and you need a different strategy or executor version.
        -- ----------------------------------------------------------------
        if CFG.DEBUG_NAMECALL and spyActive then
            local selfDesc = "unknown"
            pcall(function()
                selfDesc = self.ClassName .. "(" .. self.Name .. ")"
            end)
            pushLog("[NC] " .. tostring(method) .. "  on  " .. selfDesc)
        end

        -- Normal remote logging (always active, regardless of debug mode).
        if method == "FireServer"
        or method == "InvokeServer"
        or method == "FireAllClients"
        or method == "FireClient"
        or method == "FireUnreliable"
        or method == "Invoke"
        or method == "Fire" then   -- BindableEvent / BindableFunction use :Fire()
            logRemote(self, method, {...})
        end

        return originalNamecall(self, ...)
    end)
end

-- ---- Strategy 1: hookmetamethod  -------------------------------------------
-- The approach Ketamine uses on Xeno.  Most reliable because hookmetamethod
-- handles the lock/unlock of the metatable internally and guarantees the
-- replacement is a proper C closure.
if not hookInstalled then
    local ok, err = pcall(function()
        if not hookmetamethod then error("hookmetamethod not available") end

        -- Trampoline so originalNamecall is set before the hook can fire.
        local originalNamecall
        local hook = makeNamecallHook(function(self, ...)
            return originalNamecall(self, ...)
        end)

        originalNamecall = hookmetamethod(game, "__namecall", hook)
        if not originalNamecall then error("hookmetamethod returned nil") end

        hookInstalled    = true
        hookStrategyName = "hookmetamethod"
    end)
    if not ok then
        table.insert(hookFailReasons, "S1 hookmetamethod: " .. tostring(err))
    end
end

-- ---- Strategy 2: getrawmetatable manual write  ------------------------------
-- On Xeno, when hookmetamethod is unavailable, this is the correct fallback.
-- We read game's raw metatable, unlock it, swap __namecall, then re-lock.
-- This is a true global intercept: every instance's namecall goes through here.
if not hookInstalled then
    local ok, err = pcall(function()
        -- Accept getrawmetatable or the debug alias.
        local getRaw = getrawmetatable
            or (debug and type(debug) == "table" and rawget(debug, "getmetatable"))
        if not getRaw then error("getrawmetatable not available") end

        local mt = getRaw(game)
        if type(mt) ~= "table" then error("metatable is not a table") end

        -- Unlock the (read-only) metatable so we can write __namecall.
        -- Try every known unlock API; if all are absent the rawset will error
        -- and we fall through cleanly to the next strategy.
        if setreadonly    then pcall(setreadonly,    mt, false) end
        if make_readonly  then pcall(make_readonly,  mt, false) end
        if make_writeable then pcall(make_writeable, mt)        end

        local origNC = rawget(mt, "__namecall")
        if not origNC then error("__namecall not found in metatable") end

        rawset(mt, "__namecall", makeNamecallHook(origNC))

        -- Re-lock after writing.
        if setreadonly   then pcall(setreadonly,   mt, true) end
        if make_readonly then pcall(make_readonly, mt, true) end

        hookInstalled    = true
        hookStrategyName = "getrawmetatable"
    end)
    if not ok then
        table.insert(hookFailReasons, "S2 getrawmetatable: " .. tostring(err))
    end
end

-- ---- Strategy 3: debug.getmetatable  ----------------------------------------
-- Some executors expose the metatable only through debug.getmetatable.
if not hookInstalled then
    local ok, err = pcall(function()
        if not debug or not debug.getmetatable then
            error("debug.getmetatable not available")
        end
        local mt = debug.getmetatable(game)
        if type(mt) ~= "table" then error("metatable is not a table") end

        local origNC = rawget(mt, "__namecall")
        if not origNC then error("__namecall not found in metatable") end

        rawset(mt, "__namecall", makeNamecallHook(origNC))

        hookInstalled    = true
        hookStrategyName = "debug.getmetatable"
    end)
    if not ok then
        table.insert(hookFailReasons, "S3 debug.getmetatable: " .. tostring(err))
    end
end

-- ---- Strategy 4: hookfunction global (with self-test)  ----------------------
-- Try hooking the shared C method via a temporary instance. Verify it actually
-- intercepts calls on OTHER instances via a self-test before accepting.
-- On Xeno this is known to fail the self-test and fall through to Strategy 5.
if not hookInstalled then
    local ok, err = pcall(function()
        if not hookfunction then error("hookfunction not available") end
        if not cloneFn      then error("clonefunction/clonefunc not available") end

        local tmpRE = Instance.new("RemoteEvent")
        local tmpRF = Instance.new("RemoteFunction")

        local fnFireServer     = tmpRE.FireServer
        local fnInvokeServer   = tmpRF.InvokeServer
        local fnFireAllClients = tmpRE.FireAllClients
        local fnFireClient     = tmpRE.FireClient

        origFireServer     = hookfunction(fnFireServer,     cloneFn(newFireServer))
        origInvokeServer   = hookfunction(fnInvokeServer,   cloneFn(newInvokeServer))
        origFireAllClients = hookfunction(fnFireAllClients, cloneFn(newFireAllClients))
        origFireClient     = hookfunction(fnFireClient,     cloneFn(newFireClient))

        tmpRE:Destroy()
        tmpRF:Destroy()

        -- Self-test: create a completely separate RemoteEvent and fire it.
        -- If our hook above is truly global, newFireServer will run for it.
        local testFired  = false
        local savedActive = spyActive
        spyActive = false

        local testRE  = Instance.new("RemoteEvent")
        local savedFS = origFireServer  -- the real original
        -- Temporarily replace newFireServer's behaviour via a flag
        hookfunction(testRE.FireServer, cloneFn(function(s, ...)
            testFired = true
            return savedFS(s, ...)
        end))
        pcall(function() testRE:FireServer() end)
        testRE:Destroy()
        spyActive = savedActive

        if not testFired then
            error("self-test failed: hookfunction is per-instance only on this executor")
        end

        pcall(function()
            local tmpURE       = Instance.new("UnreliableRemoteEvent")
            local fnUnreliable = tmpURE.FireServer
            origUnreliableFireServer = hookfunction(fnUnreliable, cloneFn(newUnreliableFireServer))
            tmpURE:Destroy()
        end)

        hookInstalled    = true
        hookStrategyName = "hookfunction+clonefunction (global)"
    end)
    if not ok then
        table.insert(hookFailReasons, "S4 hookfunction-global: " .. tostring(err))
    end
end

-- ---- Strategy 5: per-instance hookfunction scan  ----------------------------
-- When no global hook API exists and hookfunction only works per-instance,
-- scan the entire game tree for remotes and hook each one individually.
-- Also connects DescendantAdded to catch remotes added later.
-- This is the correct approach for Xeno when all other strategies fail.
if not hookInstalled then
    local ok, err = pcall(function()
        if not hookfunction then error("hookfunction not available") end
        if not cloneFn      then error("clonefunction/clonefunc not available") end

        local hookedInstances = {}  -- track what we have already hooked

        -- Hook a single remote instance.
        -- Uses locals so each closure captures its own `orig` upvalue correctly.
        local function hookOne(remote)
            if hookedInstances[remote] then return end
            hookedInstances[remote] = true

            local cls = remote.ClassName

            if cls == "RemoteEvent" or cls == "UnreliableRemoteEvent" then
                -- FireServer: client -> server
                local origFS
                origFS = hookfunction(remote.FireServer, cloneFn(function(self, ...)
                    logRemote(self, "FireServer", {...})
                    return origFS(self, ...)
                end))
                -- FireAllClients / FireClient: server -> client (only visible server-side,
                -- but hook anyway in case this is running server-side or Xeno exposes it)
                pcall(function()
                    local origFAC
                    origFAC = hookfunction(remote.FireAllClients, cloneFn(function(self, ...)
                        logRemote(self, "FireAllClients", {...})
                        return origFAC(self, ...)
                    end))
                end)
                pcall(function()
                    local origFC
                    origFC = hookfunction(remote.FireClient, cloneFn(function(self, ...)
                        logRemote(self, "FireClient", {...})
                        return origFC(self, ...)
                    end))
                end)

            elseif cls == "RemoteFunction" then
                local origIS
                origIS = hookfunction(remote.InvokeServer, cloneFn(function(self, ...)
                    logRemote(self, "InvokeServer", {...})
                    return origIS(self, ...)
                end))

            elseif cls == "BindableEvent" then
                local origF
                origF = hookfunction(remote.Fire, cloneFn(function(self, ...)
                    logRemote(self, "Fire", {...})
                    return origF(self, ...)
                end))

            elseif cls == "BindableFunction" then
                local origI
                origI = hookfunction(remote.Invoke, cloneFn(function(self, ...)
                    logRemote(self, "Invoke", {...})
                    return origI(self, ...)
                end))
            end
        end

        -- Hook every remote already in the game tree.
        -- We collect them first so we can log them all after hookInstalled = true,
        -- which means pushLog (and thus the UI) is ready to display them.
        local foundRemotes = {}
        for _, desc in ipairs(game:GetDescendants()) do
            local cls = desc.ClassName
            if cls == "RemoteEvent" or cls == "RemoteFunction"
            or cls == "UnreliableRemoteEvent"
            or cls == "BindableEvent" or cls == "BindableFunction" then
                -- Hook all remotes in the game (like SimpleSpy), including under other players
                if pcall(hookOne, desc) then
                    table.insert(foundRemotes, desc)
                end
            end
        end

        -- Watch for remotes added after startup (lazy-loaded scripts, etc.)
        game.DescendantAdded:Connect(function(desc)
            local cls = desc.ClassName
            if cls == "RemoteEvent" or cls == "RemoteFunction"
            or cls == "UnreliableRemoteEvent"
            or cls == "BindableEvent" or cls == "BindableFunction" then
                -- Hook all new remotes (like SimpleSpy)
                if pcall(hookOne, desc) then
                    local ok2, path = pcall(function() return desc:GetFullName() end)
                    pushLog("[New] [" .. desc.ClassName .. "] " .. (ok2 and path or desc.Name))
                end
            end
        end)

        hookInstalled    = true
        hookStrategyName = "per-instance-scan (" .. tostring(#foundRemotes) .. " remotes found)"

        -- Log each found remote so the user can see what is being monitored.
        for _, remote in ipairs(foundRemotes) do
            local ok2, path = pcall(function() return remote:GetFullName() end)
            pushLog("[Hooked] [" .. remote.ClassName .. "] " .. (ok2 and path or remote.Name))
        end
    end)
    if not ok then
        table.insert(hookFailReasons, "S5 per-instance: " .. tostring(err))
    end
end

-- =============================================================================
-- CODE GENERATOR
-- Parses a log entry and produces a ready-to-run Lua snippet.
-- Uses full path to resolve the exact remote (like SimpleSpy) so Run Code
-- fires the same remote that was logged.
-- =============================================================================
local function escapeForLua(s)
    return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function pathParts(path)
    local parts = {}
    for segment in path:gmatch("[^%.]+") do
        table.insert(parts, segment)
    end
    return parts
end

local function generateCode(entry)
    if not entry then return "-- (no entry selected)" end

    local path, method, args

    -- [New] row format: "[New] [ClassName] Full.Path"
    local newCls, newPath = entry:match("^%[New%] %[(.-)%] (.+)$")
    if newPath then
        path = newPath
        method = (newCls == "RemoteFunction") and "InvokeServer"
            or (newCls == "BindableEvent" or newCls == "BindableFunction") and "Fire"
            or "FireServer"
        args = ""
    else
        -- Normal fire row: "[ClassName] Full.Path  :MethodName(args)"
        local cls
        cls, path, method, args = entry:match("^%[(.-)%] (.-)  :(.-)%((.*)%)%s*$")
        if not path then
            -- Old / fallback format: "[ClassName] Full.Path(args)"
            cls, path, args = entry:match("^%[(.-)%] (.-)%((.*)%)%s*$")
            method = (cls == "RemoteFunction") and "InvokeServer" or "FireServer"
        end
    end

    if not path or path == "" then return "-- (could not parse entry)" end

    method = method or "FireServer"
    if method == "FireUnreliable" then method = "FireServer" end
    args = (args and args:match("^%s*(.-)%s*$")) or ""

    local parts = pathParts(path)
    if #parts == 0 then return "-- (invalid path)" end

    local partsSource = {}
    for i = 1, #parts do
        partsSource[i] = '"' .. escapeForLua(parts[i]) .. '"'
    end
    local pathPartsStr = "{" .. table.concat(partsSource, ", ") .. "}"

    return "local pathParts = " .. pathPartsStr .. "\n"
        .. "local current = game\n"
        .. "for i = 1, #pathParts do current = current:FindFirstChild(pathParts[i]) if not current then break end end\n"
        .. "if current then current:" .. method .. "(" .. args .. ") end"
end

-- =============================================================================
-- UI
-- =============================================================================
local prevGui = playerGui:FindFirstChild("RemoteSpyGui")
if prevGui then prevGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name           = "RemoteSpyGui"
screenGui.ResetOnSpawn   = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder   = 999
screenGui.Parent         = playerGui

local function addCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 6)
    c.Parent = parent
end

local function makeButton(parent, label, x, y, w, h, bg)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, w, 0, h)
    btn.Position         = UDim2.new(0, x, 0, y)
    btn.BackgroundColor3 = bg or CFG.ACCENT
    btn.TextColor3       = Color3.fromRGB(255, 255, 255)
    btn.Text             = label
    btn.TextSize         = 12
    btn.Font             = Enum.Font.GothamMedium
    btn.AutoButtonColor  = true
    btn.BorderSizePixel  = 0
    btn.Parent           = parent
    addCorner(btn, 4)
    return btn
end

-- ---- MAIN WINDOW ------------------------------------------------------------
local mainFrame = Instance.new("Frame")
mainFrame.Name             = "MainFrame"
mainFrame.Size             = UDim2.new(0, CFG.WINDOW_W, 0, CFG.WINDOW_H)
mainFrame.Position         = UDim2.new(0, CFG.WINDOW_X, 0, CFG.WINDOW_Y)
mainFrame.BackgroundColor3 = CFG.DARK_BG
mainFrame.BorderSizePixel  = 0
mainFrame.Active           = true
mainFrame.Parent           = screenGui
addCorner(mainFrame, 8)

-- ---- TITLE BAR --------------------------------------------------------------
local titleBar = Instance.new("Frame")
titleBar.Name             = "TitleBar"
titleBar.Size             = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = CFG.PANEL_BG
titleBar.BorderSizePixel  = 0
titleBar.Parent           = mainFrame
addCorner(titleBar, 8)

-- Patch the rounded corners so the bottom of the title bar is flat
local titleFix = Instance.new("Frame")
titleFix.Size             = UDim2.new(1, 0, 0, 8)
titleFix.Position         = UDim2.new(0, 0, 1, -8)
titleFix.BackgroundColor3 = CFG.PANEL_BG
titleFix.BorderSizePixel  = 0
titleFix.Parent           = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size                   = UDim2.new(1, -160, 1, 0)
titleLabel.Position               = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.TextColor3             = CFG.TEXT_COLOR
titleLabel.TextXAlignment         = Enum.TextXAlignment.Left
titleLabel.Text                   = "Remote Spy"
titleLabel.TextSize               = 14
titleLabel.Font                   = Enum.Font.GothamBold
titleLabel.Parent                 = titleBar

local toggleBtn = makeButton(titleBar, "ACTIVE", CFG.WINDOW_W - 140, 5, 72, 20, CFG.BTN_GREEN)
local closeBtn  = makeButton(titleBar, "X",      CFG.WINDOW_W - 60,  5, 44, 20, CFG.BTN_RED)

-- ---- DRAG LOGIC -------------------------------------------------------------
local isDragging  = false
local dragStart   = nil
local frameOrigin = nil

titleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 then
        isDragging  = true
        dragStart   = inp.Position
        frameOrigin = mainFrame.Position
    end
end)

titleBar.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 then
        isDragging = false
    end
end)

UIS.InputChanged:Connect(function(inp)
    if isDragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = inp.Position - dragStart
        mainFrame.Position = UDim2.new(
            frameOrigin.X.Scale, frameOrigin.X.Offset + delta.X,
            frameOrigin.Y.Scale, frameOrigin.Y.Offset + delta.Y)
    end
end)

-- ---- LOG SCROLL AREA --------------------------------------------------------
local LOG_Y    = 34
local CTRL_H   = 84
local logAreaH = CFG.WINDOW_H - LOG_Y - CTRL_H - 4

local logScroll = Instance.new("ScrollingFrame")
logScroll.Name                 = "LogScroll"
logScroll.Size                 = UDim2.new(1, -12, 0, logAreaH)
logScroll.Position             = UDim2.new(0, 6, 0, LOG_Y)
logScroll.BackgroundColor3     = CFG.PANEL_BG
logScroll.BorderSizePixel      = 0
logScroll.ScrollBarThickness   = 5
logScroll.ScrollBarImageColor3 = CFG.ACCENT
logScroll.CanvasSize           = UDim2.new(0, 0, 0, 0)
-- XY scrolling: vertical for the list, horizontal for long paths
logScroll.ScrollingDirection   = Enum.ScrollingDirection.XY
logScroll.Parent               = mainFrame
addCorner(logScroll, 4)

local hasAutoCanvas = false
pcall(function()
    logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    hasAutoCanvas = true
end)

local logLayout = Instance.new("UIListLayout")
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding   = UDim.new(0, 1)
logLayout.Parent    = logScroll

local manualCanvasH = 0
local entryFrames   = {}

local function addLogRow(idx, text)
    local row = Instance.new("TextButton")
    row.LayoutOrder     = idx
    -- Fixed wide width so long paths don't get clipped; horizontal scroll handles overflow
    row.Size            = UDim2.new(0, 1400, 0, CFG.ROW_H)
    row.TextColor3      = CFG.TEXT_COLOR
    row.TextSize        = CFG.FONT_SIZE
    row.Font            = Enum.Font.Code
    row.Text            = text
    row.TextXAlignment  = Enum.TextXAlignment.Left
    -- No truncation: horizontal scroll lets user read the full text
    row.TextTruncate    = Enum.TextTruncate.None
    row.BorderSizePixel = 0
    row.Parent          = logScroll

    -- Colour by row type:
    -- [NC]     = debug namecall (gold, non-selectable)
    -- [Hooked] = startup inventory (dim teal, non-selectable info)
    -- [New]    = dynamically added remote (dim purple, SELECTABLE -- has path info)
    -- normal   = actual fired remote (alternating rows, selectable)
    local isInfoOnly = (text:sub(1, 4) == "[NC]" or text:sub(1, 6) == "[Hooke")

    if text:sub(1, 4) == "[NC]" then
        row.BackgroundColor3 = CFG.DBG_COLOR
        row.TextColor3       = Color3.fromRGB(220, 210, 160)
    elseif text:sub(1, 6) == "[Hooke" then
        row.BackgroundColor3 = Color3.fromRGB(20, 50, 50)
        row.TextColor3       = Color3.fromRGB(120, 170, 160)
        row.TextSize         = 11
    elseif text:sub(1, 5) == "[New]" then
        -- Dim purple, but selectable so buttons work on it
        row.BackgroundColor3 = Color3.fromRGB(40, 25, 55)
        row.TextColor3       = Color3.fromRGB(170, 140, 200)
    else
        row.BackgroundColor3 = (idx % 2 == 0) and CFG.ENTRY_EVEN or CFG.ENTRY_ODD
    end

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft  = UDim.new(0, 6)
    pad.PaddingRight = UDim.new(0, 6)
    pad.Parent       = row

    entryFrames[idx] = row

    if not hasAutoCanvas then
        manualCanvasH = manualCanvasH + CFG.ROW_H + 1
        logScroll.CanvasSize = UDim2.new(0, 1400, 0, manualCanvasH)
    else
        logScroll.CanvasSize = UDim2.new(0, 1400, 0, 0)
    end

    -- [Hooked] and [NC] rows are non-selectable (they carry no usable path/method).
    if isInfoOnly then return end

    row.MouseButton1Click:Connect(function()
        if selectedIdx and entryFrames[selectedIdx] then
            local prev     = entryFrames[selectedIdx]
            local prevText = prev.Text
            if prevText:sub(1, 4) == "[NC]" then
                prev.BackgroundColor3 = CFG.DBG_COLOR
            elseif prevText:sub(1, 6) == "[Hooke" then
                prev.BackgroundColor3 = Color3.fromRGB(20, 50, 50)
            elseif prevText:sub(1, 5) == "[New]" then
                prev.BackgroundColor3 = Color3.fromRGB(40, 25, 55)
            else
                prev.BackgroundColor3 = (selectedIdx % 2 == 0) and CFG.ENTRY_EVEN or CFG.ENTRY_ODD
            end
        end
        selectedIdx          = idx
        row.BackgroundColor3 = CFG.HIGHLIGHT
    end)
end

local function rebuildLogUI()
    for _, child in ipairs(logScroll:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    entryFrames   = {}
    selectedIdx   = nil
    manualCanvasH = 0
    if not hasAutoCanvas then logScroll.CanvasSize = UDim2.new(0, 0, 0, 0) end
    for i, entry in ipairs(logs) do addLogRow(i, entry) end
end

onNewLog = function(idx, entry)
    addLogRow(idx, entry)
    logScroll.CanvasPosition = Vector2.new(0, 1e9)
end

-- ---- CONTROL PANEL ----------------------------------------------------------
local ctrlPanel = Instance.new("Frame")
ctrlPanel.Size             = UDim2.new(1, -12, 0, CTRL_H - 2)
ctrlPanel.Position         = UDim2.new(0, 6, 1, -CTRL_H)
ctrlPanel.BackgroundColor3 = CFG.PANEL_BG
ctrlPanel.BorderSizePixel  = 0
ctrlPanel.Parent           = mainFrame
addCorner(ctrlPanel, 6)

-- Button layout: 6 per row, auto-sized to fill the window width
local BGAP = 6
local BW   = math.floor((CFG.WINDOW_W - 12 - 7*BGAP) / 6)
local BH   = 24

local btnCopyCode = makeButton(ctrlPanel, "Copy Code",    BGAP+(BW+BGAP)*0, 6,  BW, BH, CFG.ACCENT)
local btnCopyRem  = makeButton(ctrlPanel, "Copy Remote",  BGAP+(BW+BGAP)*1, 6,  BW, BH, CFG.ACCENT)
local btnRunCode  = makeButton(ctrlPanel, "Run Code",     BGAP+(BW+BGAP)*2, 6,  BW, BH, CFG.ACCENT)
local btnGetScr   = makeButton(ctrlPanel, "Get Script",   BGAP+(BW+BGAP)*3, 6,  BW, BH, CFG.ACCENT)
local btnFuncInfo = makeButton(ctrlPanel, "Func Info",    BGAP+(BW+BGAP)*4, 6,  BW, BH, CFG.ACCENT)
local btnClrLogs  = makeButton(ctrlPanel, "Clr Logs",     BGAP+(BW+BGAP)*5, 6,  BW, BH, CFG.BTN_RED)
local btnExclName = makeButton(ctrlPanel, "Excl Name",    BGAP+(BW+BGAP)*0, 36, BW, BH, CFG.BTN_DIM)
local btnBlkName  = makeButton(ctrlPanel, "Block Name",   BGAP+(BW+BGAP)*1, 36, BW, BH, CFG.BTN_DIM)
local btnExclInst = makeButton(ctrlPanel, "Excl Inst",    BGAP+(BW+BGAP)*2, 36, BW, BH, CFG.BTN_DIM)
local btnBlkInst  = makeButton(ctrlPanel, "Block Inst",   BGAP+(BW+BGAP)*3, 36, BW, BH, CFG.BTN_DIM)
local btnClrBl    = makeButton(ctrlPanel, "Clr Blacklist",BGAP+(BW+BGAP)*4, 36, BW, BH, CFG.BTN_DIM)

-- ---- BUTTON CALLBACKS -------------------------------------------------------
local function getSelected() return selectedIdx and logs[selectedIdx] or nil end

-- extractPath: pull the remote's full path out of a log entry.
-- Handles three formats:
--   Normal fire:  "[ClassName] Full.Path  :method(args)"
--   [New] row:    "[New] [ClassName] Full.Path"
--   Old format:   "[ClassName] Full.Path(args)"
local function extractPath(entry)
    if not entry then return nil end
    -- [New] rows: strip the "[New] [ClassName] " prefix to get the path
    local newPath = entry:match("^%[New%] %[.-%] (.+)$")
    if newPath then return newPath end
    -- Normal fire row: "[ClassName] path  :method(args)"
    local p = entry:match("^%[.-%] (.-)  :")
    if p then return p end
    -- Old format: "[ClassName] path(args)"
    return entry:match("^%[.-%] (.-)%(")
end

local function extractName(entry)
    local path = extractPath(entry)
    if not path then return nil end
    return path:match("[^%.]+$") or path
end

-- Resolve an instance by full path (e.g. "Workspace.PlayerName.Tool.HitRemote").
local function getInstanceByPath(path)
    if not path or path == "" then return nil end
    local current = game
    for segment in path:gmatch("[^%.]+") do
        current = current:FindFirstChild(segment)
        if not current then return nil end
    end
    return current
end

-- Parse a log entry into path, method, and args string for Run Code.
local function parseLogEntry(entry)
    if not entry then return nil, nil, nil end
    local path, method, args
    local newCls, newPath = entry:match("^%[New%] %[(.-)%] (.+)$")
    if newPath then
        path = newPath
        method = (newCls == "RemoteFunction") and "InvokeServer"
            or (newCls == "BindableEvent" or newCls == "BindableFunction") and "Fire"
            or "FireServer"
        args = ""
    else
        local cls
        cls, path, method, args = entry:match("^%[(.-)%] (.-)  :(.-)%((.*)%)%s*$")
        if not path then
            cls, path, args = entry:match("^%[(.-)%] (.-)%((.*)%)%s*$")
            method = (cls == "RemoteFunction") and "InvokeServer" or "FireServer"
        end
    end
    if path then
        args = (args and args:match("^%s*(.-)%s*$")) or ""
    end
    return path, method or "FireServer", args
end

btnCopyCode.MouseButton1Click:Connect(function()
    copyToClipboard(generateCode(getSelected()))
end)

btnCopyRem.MouseButton1Click:Connect(function()
    local path = extractPath(getSelected())
    if path then copyToClipboard(path) end
end)

btnRunCode.MouseButton1Click:Connect(function()
    local entry = getSelected()
    local path, method, argsStr = parseLogEntry(entry)
    if not path then
        pushLog("[RunCode error] No entry or could not parse")
        return
    end
    local remote = getInstanceByPath(path)
    if not remote then
        pushLog("[RunCode error] Remote not found: " .. path)
        return
    end
    if method == "FireUnreliable" then method = "FireServer" end
    local methodFn = remote[method]
    if type(methodFn) ~= "function" then
        pushLog("[RunCode error] No such method: " .. tostring(method))
        return
    end
    local ok, err
    if argsStr == "" or not argsStr then
        ok, err = pcall(methodFn, remote)
    else
        local loadFn = loadstring("return {" .. argsStr .. "}")
        if not loadFn then
            pushLog("[RunCode error] Invalid args: " .. tostring(argsStr))
            return
        end
        local argOk, argList = pcall(loadFn)
        if not argOk or type(argList) ~= "table" then
            pushLog("[RunCode error] Could not parse args")
            return
        end
        ok, err = pcall(methodFn, remote, table.unpack(argList))
    end
    if not ok then
        pushLog("[RunCode error] " .. tostring(err))
    end
end)

btnGetScr.MouseButton1Click:Connect(function()
    local path = extractPath(getSelected())
    if not path then return end
    local obj = getInstanceByPath(path)
    if not obj then return end
    if decompile then
        local ok, result = pcall(decompile, obj)
        copyToClipboard((ok and result) or "-- decompile failed")
    else
        copyToClipboard("-- decompile() not available in this executor")
    end
end)

btnFuncInfo.MouseButton1Click:Connect(function()
    local entry = getSelected()
    if not entry then return end
    -- Try [New] format first
    local cls, path = entry:match("^%[New%] %[(.-)%] (.+)$")
    local method, args = "?", "?"
    if not cls then
        -- Try normal fire format
        cls, path, method, args = entry:match("^%[(.-)%] (.-)  :(.-)%((.*)%)%s*$")
    end
    if not cls then
        -- Old format
        cls, path, args = entry:match("^%[(.-)%] (.-)%((.*)%)%s*$")
    end
    copyToClipboard(table.concat({
        "Class  : " .. (cls    or "?"),
        "Path   : " .. (path   or "?"),
        "Method : " .. (method or "?"),
        "Args   : " .. (args   or "?"),
        "Index  : " .. tostring(selectedIdx),
    }, "\n"))
end)

btnExclName.MouseButton1Click:Connect(function()
    local name = extractName(getSelected())
    if name then excludeNames[name] = true end
end)

btnBlkName.MouseButton1Click:Connect(function()
    local name = extractName(getSelected())
    if name then blockNames[name] = true end
end)

btnExclInst.MouseButton1Click:Connect(function()
    local path = extractPath(getSelected())
    if not path then return end
    local obj = getInstanceByPath(path)
    if obj then excludeInst[obj] = true end
end)

btnBlkInst.MouseButton1Click:Connect(function()
    local path = extractPath(getSelected())
    if not path then return end
    local obj = getInstanceByPath(path)
    if obj then blockInst[obj] = true end
end)

btnClrBl.MouseButton1Click:Connect(function()
    excludeNames = {}
    blockNames   = {}
    excludeInst  = {}
    blockInst    = {}
end)

btnClrLogs.MouseButton1Click:Connect(function()
    logs = {}
    rebuildLogUI()
end)

toggleBtn.MouseButton1Click:Connect(function()
    spyActive = not spyActive
    if spyActive then
        toggleBtn.Text             = "ACTIVE"
        toggleBtn.BackgroundColor3 = CFG.BTN_GREEN
    else
        toggleBtn.Text             = "PAUSED"
        toggleBtn.BackgroundColor3 = CFG.BTN_RED
    end
end)

closeBtn.MouseButton1Click:Connect(function()
    frameVisible = not frameVisible
    mainFrame.Visible = frameVisible
end)

-- =============================================================================
-- STARTUP DIAGNOSTICS
-- Always reports which strategy ran (and why others failed) so you don't have
-- to guess what's happening.
-- =============================================================================
if hookInstalled then
    pushLog("[RemoteSpy] Hook ACTIVE  --  strategy: " .. hookStrategyName)
    -- Per-instance scan: remotes are listed above as [Hooked] rows.
    -- Namecall debug mode is irrelevant for this strategy.
    local isPerInstance = hookStrategyName:find("per-instance") ~= nil
    if isPerInstance then
        pushLog("[RemoteSpy] Interact with the game to see remote calls appear.")
        pushLog("[RemoteSpy] New remotes added later will appear as [New] rows.")
    elseif CFG.DEBUG_NAMECALL then
        pushLog("[RemoteSpy] DEBUG MODE ON: gold rows = every __namecall fired.")
        pushLog("[RemoteSpy] No gold rows after in-game activity = hook not firing.")
        pushLog("[RemoteSpy] Set DEBUG_NAMECALL=false in CFG once confirmed working.")
    else
        pushLog("[RemoteSpy] Listening for remote calls...")
    end
else
    pushLog("[RemoteSpy] ERROR: all hook strategies failed. Nothing will be logged.")
    for _, reason in ipairs(hookFailReasons) do
        pushLog("[RemoteSpy] " .. reason)
    end
end

-- Always show which strategies were skipped/failed, even on success.
-- This helps identify partial failures (e.g. hookmetamethod worked but
-- hookfunction also failed to give useful context for other executors).
if hookInstalled and #hookFailReasons > 0 then
    pushLog("[RemoteSpy] Other strategies that were skipped:")
    for _, reason in ipairs(hookFailReasons) do
        pushLog("[RemoteSpy]   " .. reason)
    end
end
