--[[
    RemoteSpy.lua  v8  --  Xeno Executor compatible.
    Paste into Xeno's script tab and execute.
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
    DBG_COLOR  = Color3.fromRGB(100, 95,  20),
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
-- =============================================================================
-- OTHER-PLAYER FILTER
-- Two complementary checks so neither timing issues nor missing APIs cause leaks.
-- =============================================================================
-- Check 1: walk parent chain using GetPlayerFromCharacter + IsA("Player").
-- Can miss in DescendantAdded if character isn't registered yet (timing race).
-- Check 1: walk parent chain using GetPlayerFromCharacter + IsA("Player").
-- Can miss in DescendantAdded if character isn't registered yet (timing race).
local function isOtherPlayerDescendant(instance)
    local obj = instance
    local count = 0
    while obj and obj ~= game and count < 20 do
        count = count + 1
        local ok, player = pcall(function() return Players:GetPlayerFromCharacter(obj) end)
        if ok and player and player ~= lp then return true end
        if obj:IsA("Player") and obj ~= lp then return true end
        obj = obj.Parent
    end
    return false
end
-- Check 2: path-based. After GetFullName(), check each segment against Players.
-- Works even when the parent chain isn't fully registered yet.
local function pathContainsOtherPlayer(path)
    for seg in path:gmatch("[^%.]+") do
        local p = Players:FindFirstChild(seg)
        if p and p ~= lp then return true end
    end
    return false
end
-- Combined: true if the remote should be skipped entirely.
local function shouldSkipRemote(instance)
    if isOtherPlayerDescendant(instance) then return true end
    local ok, path = pcall(function() return instance:GetFullName() end)
    if ok and pathContainsOtherPlayer(path) then return true end
    return false
end
-- =============================================================================
-- COMPAT SHIMS
-- =============================================================================
local function mathRound(n) return math.floor(n + 0.5) end
local function copyToClipboard(text)
    if setclipboard then pcall(setclipboard, tostring(text)) end
end
local cloneFn = clonefunction or clonefunc
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
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number" then
        if val ~= val then return "nan" end
        if math.floor(val) == val then return tostring(math.floor(val)) end
        return string.format("%.3f", val)
    elseif t == "string" then return string.format("%q", val)
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
        return ok and ("[" .. val.ClassName .. "] " .. path) or ("[" .. val.ClassName .. "] (destroyed)")
    elseif t == "table" then
        if depth >= CFG.TRUNCATE_DEPTH then return "{...}" end
        local parts = {}
        local isArr = (#val > 0)
        for k, v in (isArr and ipairs or pairs)(val) do
            local prefix = isArr and "" or (tostring(k) .. "=")
            table.insert(parts, prefix .. serialize(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "EnumItem" then return tostring(val)
    elseif t == "function" then return "function(...)"
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
local onNewLog = nil
local function pushLog(entry)
    if #logs >= CFG.MAX_LOG_LINES then table.remove(logs, 1) end
    table.insert(logs, entry)
    if onNewLog then pcall(onNewLog, #logs, entry) end
end
local REMOTE_CLASSES = {
    RemoteEvent           = true,
    RemoteFunction        = true,
    UnreliableRemoteEvent = true,
    BindableEvent         = true,
    BindableFunction      = true,
}
-- FIX: "[From] " is exactly 7 characters. All sub() calls use 7/8 consistently.
local FROM_PREFIX    = "[From] "
local FROM_PREFIX_LEN = 7   -- len("[From] ") == 7
local function logRemote(self, methodName, args, fromServer)
    if not spyActive then return end
    local clsOk, cls = pcall(function() return self.ClassName end)
    if not clsOk or not REMOTE_CLASSES[cls] then return end
    if isBlocked(self)  then return end
    if isExcluded(self) then return end
    local pathOk, path = pcall(function() return self:GetFullName() end)
    path = (pathOk and path) or self.Name
    local line = "[" .. cls .. "] " .. path .. "  :" .. methodName .. "(" .. formatArgs(args) .. ")"
    if fromServer then line = FROM_PREFIX .. line end
    pushLog(line)
end
-- =============================================================================
-- HOOK REPLACEMENT FUNCTIONS (hookfunction global strategy)
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
local function newUnreliableFireServer(self, ...)
    logRemote(self, "FireUnreliable", {...})
    return origUnreliableFireServer(self, ...)
end
-- =============================================================================
-- HOOK INSTALLATION
-- =============================================================================
local hookInstalled    = false
local hookStrategyName = "none"
local hookFailReasons  = {}
local function makeNamecallHook(originalNamecall)
    return wrapCClosure(function(self, ...)
        local method = ""
        if getnamecallmethod then
            pcall(function() method = getnamecallmethod() end)
        end
        if CFG.DEBUG_NAMECALL and spyActive then
            local selfDesc = "unknown"
            pcall(function() selfDesc = self.ClassName .. "(" .. self.Name .. ")" end)
            pushLog("[NC] " .. tostring(method) .. "  on  " .. selfDesc)
        end
        if method == "FireServer"
        or method == "InvokeServer"
        or method == "FireAllClients"
        or method == "FireClient"
        or method == "FireUnreliable"
        or method == "Invoke"
        or method == "Fire" then
            logRemote(self, method, {...})
        end
        return originalNamecall(self, ...)
    end)
end
-- ---- Strategy 1: hookmetamethod --------------------------------------------
if not hookInstalled then
    local ok, err = pcall(function()
        if not hookmetamethod then error("hookmetamethod not available") end
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
-- ---- Strategy 2: getrawmetatable -------------------------------------------
if not hookInstalled then
    local ok, err = pcall(function()
        local getRaw = getrawmetatable
            or (debug and type(debug) == "table" and rawget(debug, "getmetatable"))
        if not getRaw then error("getrawmetatable not available") end
        local mt = getRaw(game)
        if type(mt) ~= "table" then error("metatable is not a table") end
        if setreadonly    then pcall(setreadonly,    mt, false) end
        if make_readonly  then pcall(make_readonly,  mt, false) end
        if make_writeable then pcall(make_writeable, mt)        end
        local origNC = rawget(mt, "__namecall")
        if not origNC then error("__namecall not found in metatable") end
        rawset(mt, "__namecall", makeNamecallHook(origNC))
        if setreadonly   then pcall(setreadonly,   mt, true) end
        if make_readonly then pcall(make_readonly, mt, true) end
        hookInstalled    = true
        hookStrategyName = "getrawmetatable"
    end)
    if not ok then
        table.insert(hookFailReasons, "S2 getrawmetatable: " .. tostring(err))
    end
end
-- ---- Strategy 3: debug.getmetatable ----------------------------------------
if not hookInstalled then
    local ok, err = pcall(function()
        if not debug or not debug.getmetatable then error("debug.getmetatable not available") end
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
-- ---- Strategy 4: hookfunction global (self-test) ---------------------------
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
        
        -- Safest way: clone FIRST, then hook.
        -- If hookfunction returns the original, update to that.
        origFireServer     = cloneFn(fnFireServer)
        origInvokeServer   = cloneFn(fnInvokeServer)
        origFireAllClients = cloneFn(fnFireAllClients)
        origFireClient     = cloneFn(fnFireClient)
        local h1 = hookfunction(fnFireServer,     cloneFn(newFireServer))
        local h2 = hookfunction(fnInvokeServer,   cloneFn(newInvokeServer))
        local h3 = hookfunction(fnFireAllClients, cloneFn(newFireAllClients))
        local h4 = hookfunction(fnFireClient,     cloneFn(newFireClient))
        
        if h1 then origFireServer     = h1 end
        if h2 then origInvokeServer   = h2 end
        if h3 then origFireAllClients = h3 end
        if h4 then origFireClient     = h4 end
        tmpRE:Destroy()
        tmpRF:Destroy()
        local testFired   = false
        local savedActive = spyActive
        spyActive = false
        local testRE  = Instance.new("RemoteEvent")
        local savedFS = origFireServer
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
-- ---- Strategy 5: per-instance hookfunction scan ----------------------------
if not hookInstalled then
    local ok, err = pcall(function()
        if not hookfunction then error("hookfunction not available") end
        if not cloneFn      then error("clonefunction/clonefunc not available") end
        local hookedInstances = {}
        local function hookOne(remote)
            if hookedInstances[remote] then return end
            hookedInstances[remote] = true
            local cls = remote.ClassName
            if cls == "RemoteEvent" or cls == "UnreliableRemoteEvent" then
                local origFS = cloneFn(remote.FireServer)
                local hFS = hookfunction(remote.FireServer, cloneFn(function(self, ...)
                    logRemote(self, "FireServer", {...})
                    return origFS(self, ...)
                end))
                if hFS then origFS = hFS end
                pcall(function()
                    local origFAC = cloneFn(remote.FireAllClients)
                    local hFAC = hookfunction(remote.FireAllClients, cloneFn(function(self, ...)
                        logRemote(self, "FireAllClients", {...})
                        return origFAC(self, ...)
                    end))
                    if hFAC then origFAC = hFAC end
                end)
                pcall(function()
                    local origFC = cloneFn(remote.FireClient)
                    local hFC = hookfunction(remote.FireClient, cloneFn(function(self, ...)
                        logRemote(self, "FireClient", {...})
                        return origFC(self, ...)
                    end))
                    if hFC then origFC = hFC end
                end)
                pcall(function()
                    remote.OnClientEvent:Connect(function(...)
                        logRemote(remote, "OnClientEvent", {...}, true)
                    end)
                end)
            elseif cls == "RemoteFunction" then
                local origIS = cloneFn(remote.InvokeServer)
                local hIS = hookfunction(remote.InvokeServer, cloneFn(function(self, ...)
                    logRemote(self, "InvokeServer", {...})
                    return origIS(self, ...)
                end))
                if hIS then origIS = hIS end
                pcall(function()
                    local getcb = getfenv().getcallbackvalue
                    if not getcb then return end
                    local cbOk, cb = pcall(getcb, remote, "OnClientInvoke")
                    if not cbOk or type(cb) ~= "function" then return end
                    local origInv = cloneFn(cb)
                    local hInv = hookfunction(cb, cloneFn(function(...)
                        logRemote(remote, "OnClientInvoke", {...}, true)
                        return origInv(...)
                    end))
                    if hInv then origInv = hInv end
                end)
            elseif cls == "BindableEvent" then
                local origF = cloneFn(remote.Fire)
                local hF = hookfunction(remote.Fire, cloneFn(function(self, ...)
                    logRemote(self, "Fire", {...})
                    return origF(self, ...)
                end))
                if hF then origF = hF end
            elseif cls == "BindableFunction" then
                local origI = cloneFn(remote.Invoke)
                local hI = hookfunction(remote.Invoke, cloneFn(function(self, ...)
                    logRemote(self, "Invoke", {...})
                    return origI(self, ...)
                end))
                if hI then origI = hI end
            end
        end
        local function isRemoteClass(cls)
            return cls == "RemoteEvent" or cls == "RemoteFunction"
                or cls == "UnreliableRemoteEvent"
                or cls == "BindableEvent" or cls == "BindableFunction"
        end
        local foundRemotes = {}
        local foundCount   = 0
        local function addFound(remote)
            if not foundRemotes[remote] then
                foundRemotes[remote] = true
                foundCount = foundCount + 1
            end
        end
        -- Try getnilinstances (nil-parented remotes)
        local getNil = getfenv().getnilinstances
        if getNil then
            for _, v in ipairs(getNil() or {}) do
                if v and isRemoteClass(v.ClassName) and not shouldSkipRemote(v) then
                    if pcall(hookOne, v) then addFound(v) end
                end
            end
        end
        -- Try getinstances (all known instances)
        local getInst = getfenv().getinstances
        if getInst then
            for _, v in ipairs(getInst() or {}) do
                if v and isRemoteClass(v.ClassName) and not shouldSkipRemote(v) then
                    if pcall(hookOne, v) then addFound(v) end
                end
            end
        end
        -- Scan game tree
        for _, desc in ipairs(game:GetDescendants()) do
            if isRemoteClass(desc.ClassName) and not shouldSkipRemote(desc) then
                if pcall(hookOne, desc) then addFound(desc) end
            end
        end
        -- Watch for new remotes
        game.DescendantAdded:Connect(function(desc)
            if not isRemoteClass(desc.ClassName) then return end
            -- Use both checks: ancestry walk AND path-based player name check.
            -- Path check handles the timing race where GetPlayerFromCharacter
            -- hasn't linked the character model yet when DescendantAdded fires.
            if shouldSkipRemote(desc) then return end
            if pcall(hookOne, desc) then
                local ok2, path = pcall(function() return desc:GetFullName() end)
                local displayPath = (ok2 and path) or desc.Name
                -- Final path-based guard in case shouldSkipRemote missed it
                if not pathContainsOtherPlayer(displayPath) then
                    pushLog("[New] [" .. desc.ClassName .. "] " .. displayPath)
                end
            end
        end)
        hookInstalled    = true
        hookStrategyName = "per-instance-scan (" .. tostring(foundCount) .. " remotes found)"
        for remote, _ in pairs(foundRemotes) do
            local ok2, path = pcall(function() return remote:GetFullName() end)
            pushLog("[Hooked] [" .. remote.ClassName .. "] " .. (ok2 and path or remote.Name))
        end
    end)
    if not ok then
        table.insert(hookFailReasons, "S5 per-instance: " .. tostring(err))
    end
end
-- =============================================================================
-- PARSE HELPERS
-- FIX: "[From] " is 7 chars. Strip with sub(8) not sub(9).
-- All helper functions use FROM_PREFIX_LEN for consistency.
-- =============================================================================
-- Strip the [From] prefix from an entry string (if present) and return
-- the stripped string plus a boolean indicating it was present.
local function stripFrom(entry)
    -- "[From] " is 7 chars.
    if entry:sub(1, FROM_PREFIX_LEN) == FROM_PREFIX then
        return entry:sub(FROM_PREFIX_LEN + 1), true
    end
    return entry, false
end
-- Extract the full instance path from any log entry format.
local function extractPath(entry)
    if not entry then return nil end
    entry = stripFrom(entry)  -- discard the bool
    local newPath = entry:match("^%[New%] %[.-%] (.+)$")
    if newPath then return newPath end
    local p = entry:match("^%[.-%] (.-)  :")
    if p then return p end
    return entry:match("^%[.-%] (.-)%(")
end
local function extractName(entry)
    local path = extractPath(entry)
    if not path then return nil end
    return path:match("[^%.]+$") or path
end
-- Navigate game hierarchy by dot-separated path string.
local function getInstanceByPath(path)
    if not path or path == "" then return nil end
    local current = game
    for segment in path:gmatch("[^%.]+") do
        -- Handle "Workspace" vs "workspace" or other top levels safely
        -- But game:FindFirstChild is usually case sensitive?
        -- Standard Roblox objects are pascal case.
        local nextObj = current:FindFirstChild(segment)
        if not nextObj then return nil end
        current = nextObj
    end
    return current
end
-- Parse any log entry into (path, method, argsString).
-- Handles [From], [New], normal fire, and old-format entries.
local function parseLogEntry(entry)
    if not entry then return nil, nil, nil end
    local stripped, wasFrom = stripFrom(entry)
    -- Trim whitespace
    stripped = stripped:match("^%s*(.-)%s*$")
    local path, method, args
    local cls
    local newCls, newPath = stripped:match("^%[New%] %[(.-)%] (.+)$")
    if newPath then
        path   = newPath
        method = (newCls == "RemoteFunction") and "InvokeServer"
            or  (newCls == "BindableEvent" or newCls == "BindableFunction") and "Fire"
            or  "FireServer"
        args   = ""
    else
        -- Try matching standard format: [Class] Path  :Method(Args)
        -- Note: The original log format uses double space before colon "  :"
        cls, path, method, args = stripped:match("^%[(.-)%] (.-)  :(.-)%((.*)%)%s*$")
        
        -- Fallback: Relaxed spacing
        if not path then
            cls, path, method, args = stripped:match("^%[(.-)%] (.-)%s*:%s*(.-)%((.*)%)%s*$")
        end
        
        -- Fallback: Old format/Function call style
        if not path then
            cls, path, args = stripped:match("^%[(.-)%] (.-)%((.*)%)%s*$")
            method = (cls == "RemoteFunction") and "InvokeServer" or "FireServer"
        end
        
        -- [From] rows were incoming (server->client); map to outgoing so Run Code
        -- re-sends the same data back to the server.
        if wasFrom and path then
            if method == "OnClientEvent"  then method = "FireServer"   end
            if method == "OnClientInvoke" then method = "InvokeServer" end
        end
    end
    if not path then return nil, nil, nil end
    method = method or "FireServer"
    if method == "FireUnreliable" then method = "FireServer" end
    args = (args and args:match("^%s*(.-)%s*$")) or ""
    return path, method, args
end
-- =============================================================================
-- CODE GENERATOR
-- =============================================================================
local function escapeForLua(s)
    return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end
local function generateCode(entry)
    if not entry then return "-- (no entry selected)" end
    local path, method, args = parseLogEntry(entry)
    if not path or path == "" then return "-- (could not parse entry)" end
    -- Build path-walker code so it finds the exact instance, not just by name.
    local parts = {}
    for seg in path:gmatch("[^%.]+") do
        table.insert(parts, '"' .. escapeForLua(seg) .. '"')
    end
    local partsStr = "{" .. table.concat(parts, ", ") .. "}"
    return "local parts = " .. partsStr .. "\nlocal obj = game\nfor i = 1, #parts do obj = obj:FindFirstChild(parts[i]) if not obj then break end end\nif obj then obj:" .. method .. "(" .. args .. ") end"
end
-- Clean up argument string for loadstring execution.
-- Replaces [Class] Path with getInstance("Path") calls.
local function cleanArgsForRun(args)
    if not args then return "" end
    
    -- Remove "rot(x,y,z)" from CFrame strings
    args = args:gsub(" rot%([^%)]+%)", "")
    
    -- Replace [Class] Path with getInstance("Path")
    -- Handle (destroyed) cases
    args = args:gsub("%[[%w]+%] %(destroyed%)", "nil")
    
    -- Handle normal instances: [Part] Workspace.Part
    args = args:gsub("%[[%w]+%] ([%w%.]+)", 'getInstance("%1")')
    
    -- Handle "function(...)" -> nil (can't execute arbitrary funcs)
    args = args:gsub("function%(%.%.%.%)", "nil")
    
    return args
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
-- Row colour constants indexed by prefix for fast lookup in click handlers
local function rowBg(text, idx)
    if text:sub(1, 4) == "[NC]" then return CFG.DBG_COLOR end
    if text:sub(1, 6) == "[Hook" then return Color3.fromRGB(20, 50, 50) end
    if text:sub(1, FROM_PREFIX_LEN) == FROM_PREFIX then return Color3.fromRGB(25, 50, 40) end
    if text:sub(1, 5) == "[New]" then return Color3.fromRGB(40, 25, 55) end
    return (idx % 2 == 0) and CFG.ENTRY_EVEN or CFG.ENTRY_ODD
end
local function addLogRow(idx, text)
    local row = Instance.new("TextButton")
    row.LayoutOrder     = idx
    row.Size            = UDim2.new(0, 1400, 0, CFG.ROW_H)
    row.TextColor3      = CFG.TEXT_COLOR
    row.TextSize        = CFG.FONT_SIZE
    row.Font            = Enum.Font.Code
    row.Text            = text
    row.TextXAlignment  = Enum.TextXAlignment.Left
    row.TextTruncate    = Enum.TextTruncate.None
    row.BorderSizePixel = 0
    row.Parent          = logScroll
    -- Apply colour and optional style overrides per row type
    row.BackgroundColor3 = rowBg(text, idx)
    if text:sub(1, 4) == "[NC]" then
        row.TextColor3 = Color3.fromRGB(220, 210, 160)
    elseif text:sub(1, 6) == "[Hook" then
        row.TextColor3 = Color3.fromRGB(120, 170, 160)
        row.TextSize   = 11
    elseif text:sub(1, FROM_PREFIX_LEN) == FROM_PREFIX then
        row.TextColor3 = Color3.fromRGB(120, 200, 150)
    elseif text:sub(1, 5) == "[New]" then
        row.TextColor3 = Color3.fromRGB(170, 140, 200)
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
    -- [NC] and [Hooked] rows carry no actionable path, so skip click binding.
    local isInfoOnly = (text:sub(1, 4) == "[NC]" or text:sub(1, 6) == "[Hook")
    if isInfoOnly then return end
    row.MouseButton1Click:Connect(function()
        if selectedIdx and entryFrames[selectedIdx] then
            local prev = entryFrames[selectedIdx]
            prev.BackgroundColor3 = rowBg(prev.Text, selectedIdx)
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
local BGAP = 6
local BW   = math.floor((CFG.WINDOW_W - 12 - 7*BGAP) / 6)
local BH   = 24
local btnCopyCode = makeButton(ctrlPanel, "Copy Code",     BGAP+(BW+BGAP)*0, 6,  BW, BH, CFG.ACCENT)
local btnCopyRem  = makeButton(ctrlPanel, "Copy Remote",   BGAP+(BW+BGAP)*1, 6,  BW, BH, CFG.ACCENT)
local btnRunCode  = makeButton(ctrlPanel, "Run Code",      BGAP+(BW+BGAP)*2, 6,  BW, BH, CFG.ACCENT)
local btnGetScr   = makeButton(ctrlPanel, "Get Script",    BGAP+(BW+BGAP)*3, 6,  BW, BH, CFG.ACCENT)
local btnFuncInfo = makeButton(ctrlPanel, "Func Info",     BGAP+(BW+BGAP)*4, 6,  BW, BH, CFG.ACCENT)
local btnClrLogs  = makeButton(ctrlPanel, "Clr Logs",      BGAP+(BW+BGAP)*5, 6,  BW, BH, CFG.BTN_RED)
local btnExclName = makeButton(ctrlPanel, "Excl Name",     BGAP+(BW+BGAP)*0, 36, BW, BH, CFG.BTN_DIM)
local btnBlkName  = makeButton(ctrlPanel, "Block Name",    BGAP+(BW+BGAP)*1, 36, BW, BH, CFG.BTN_DIM)
local btnExclInst = makeButton(ctrlPanel, "Excl Inst",     BGAP+(BW+BGAP)*2, 36, BW, BH, CFG.BTN_DIM)
local btnBlkInst  = makeButton(ctrlPanel, "Block Inst",    BGAP+(BW+BGAP)*3, 36, BW, BH, CFG.BTN_DIM)
local btnClrBl    = makeButton(ctrlPanel, "Clr Blacklist", BGAP+(BW+BGAP)*4, 36, BW, BH, CFG.BTN_DIM)
-- ---- BUTTON CALLBACKS -------------------------------------------------------
local function getSelected() return selectedIdx and logs[selectedIdx] or nil end
btnCopyCode.MouseButton1Click:Connect(function()
    copyToClipboard(generateCode(getSelected()))
end)
btnCopyRem.MouseButton1Click:Connect(function()
    local path = extractPath(getSelected())
    if path then copyToClipboard(path) end
end)
btnRunCode.MouseButton1Click:Connect(function()
    local path, method, argsStr = parseLogEntry(getSelected())
    if not path then
        pushLog("[RunCode] Nothing selected or could not parse")
        return
    end
    local remote = getInstanceByPath(path)
    if not remote then
        pushLog("[RunCode] Remote not found: " .. path)
        return
    end
    local methodFn = remote[method]
    if type(methodFn) ~= "function" then
        pushLog("[RunCode] No such method: " .. tostring(method))
        return
    end
    local callOk, callErr
    if argsStr == "" then
        callOk, callErr = pcall(methodFn, remote)
    else
        if not loadstring then
            pushLog("[RunCode] loadstring not available")
            return
        end
        
        local cleanArgs = cleanArgsForRun(argsStr)
        
        -- Helper to find instance by path at runtime
        local runEnv = "local function getInstance(p) " ..
                       "local o=game for s in p:gmatch('[^%.]+') do o=o and o:FindFirstChild(s) end return o end "
        
        local loadFn, loadErr = loadstring(runEnv .. " return {" .. cleanArgs .. "}")
        if not loadFn then
            pushLog("[RunCode] Bad args: " .. tostring(loadErr))
            return
        end
        local argOk, argList = pcall(loadFn)
        if not argOk or type(argList) ~= "table" then
            pushLog("[RunCode] Could not evaluate args")
            return
        end
        callOk, callErr = pcall(methodFn, remote, table.unpack(argList))
    end
    if not callOk then
        pushLog("[RunCode] Error: " .. tostring(callErr))
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
    local path, method, args = parseLogEntry(entry)
    local stripped = stripFrom(entry)
    local cls = stripped:match("^%[New%] %[(.-)%]") or stripped:match("^%[(.-)%]") or "?"
    copyToClipboard(table.concat({
        "Class  : " .. cls,
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
-- =============================================================================
if hookInstalled then
    pushLog("[RemoteSpy] Hook ACTIVE  --  strategy: " .. hookStrategyName)
    if hookStrategyName:find("per-instance") then
        pushLog("[RemoteSpy] Interact with the game to see remote calls appear.")
        pushLog("[RemoteSpy] New remotes added later appear as [New] rows.")
    elseif CFG.DEBUG_NAMECALL then
        pushLog("[RemoteSpy] DEBUG MODE ON: gold rows = every __namecall fired.")
        pushLog("[RemoteSpy] Set DEBUG_NAMECALL=false in CFG once confirmed working.")
    else
        pushLog("[RemoteSpy] Listening for remote calls...")
    end
else
    pushLog("[RemoteSpy] ERROR: all hook strategies failed.")
    for _, reason in ipairs(hookFailReasons) do
        pushLog("[RemoteSpy] " .. reason)
    end
end
if hookInstalled and #hookFailReasons > 0 then
    pushLog("[RemoteSpy] Other strategies that failed:")
    for _, reason in ipairs(hookFailReasons) do
        pushLog("[RemoteSpy]   " .. reason)
    end
end
