--[[
  autofish_v4.lua - auto fishing for the Roblox game "Fisch"

  Runtime : Roblox client, Luau, through an executor (written for Delta, phone or PC)
  Run     : stand at the water's edge with your rod equipped (or in the hotbar), paste this
            whole file into Delta and press Execute. A small panel shows up: drag the title bar
            to move it, tap "-" to shrink it to a pill. Executing again replaces the old copy.

  How it plays: no remotes, only inputs a player has - hold to cast, press the shake button,
            hold / release to keep the white bar under the fish.

  New in v4
   Reel brain  : the old "chase the fish" rule is replaced by a predictive controller. It learns
                 how fast your bar speeds up (hold) and slows down (release) while you play,
                 allows for input lag (it knows which commands are still in flight), stops
                 against the track edges and brakes before it overshoots. The panel shows
                 accuracy = how much of the reel the fish was inside the white bar.
   Human timing: delays follow a skewed, reaction-time-like curve, drift with a slow "mood" and
                 tiredness, and have rare short lapses. "Human" also lets the bar sit a little
                 off-centre - only inside the safe margin, so the fish stays covered.
   Safety      : session limit, position guard (pauses if you get moved), backoff and stop after
                 repeated failed casts, nothing printed unless Debug is on (the game can read
                 the output log), random GUI name, clean replace when executed again.
   Panel       : live stage, session timer, catches, catches/hour, accuracy bar, chips for
                 Human / Breaks / Limit / Debug. Settings and position are remembered.

  Stuck?  : tap the Debug chip (or set DEBUG = true) and read the [autofish] lines in the console.
  Risk    : nothing here is ban-proof. Fisch staff are banning macro/exploit users right now,
            so use an alt account and don't leave it running for hours.
]]

local CFG = {
    -- names the game uses (case doesn't matter, a close match is tried too)
    GUI_SHAKE    = "shakeui",
    SHAKE_BUTTON = "button",
    GUI_REEL     = "reel",
    BAR_NAME     = "playerbar",   -- the white bar you control
    FISH_NAME    = "fish",        -- the fish icon it has to cover
    ROD_NAME     = nil,           -- exact rod name, e.g. "Training Rod"; nil = first rod found

    -- input methods, tried in this order; the one that works is kept
    CAST_ORDER   = { "mouse", "mouse2", "touch", "activate" },
    SHAKE_ORDER  = { "nav", "click", "tap", "signal" },
    HOLD_ORDER   = { "mouse", "space", "touch", "mouse2" },   -- reel: holding moves the bar right

    -- timing in seconds; { min, max } is re-rolled every time
    CAST_HOLD    = { 1.0, 1.5 },
    CAST_VERIFY  = 5,             -- how long to wait for the bobber / shake GUI after a cast
    SHAKE_FIRST  = { 0.20, 0.55 },-- reaction time before the first shake press
    SHAKE_GAP    = { 0.10, 0.28 },
    REEL_START   = { 0.15, 0.45 },-- reaction time before the reel starts (Human on)
    COOLDOWN     = { 1.5, 3.5 },
    TIMEOUT      = 40,            -- no bite after this long -> pull the line back and recast
    REEL_TIMEOUT = 60,

    HUMAN        = true,          -- skewed timing, mood/tiredness, bar a bit off-centre; off = max precision
    LAPSE        = 0.04,          -- chance of a short "looked away" pause before a shake press
    BREAKS       = true,          -- pause now and then like a person would
    BREAK_EVERY  = { 1500, 3000 },
    BREAK_LEN    = { 45, 180 },
    SESSION      = true,          -- stop by itself after a while
    SESSION_LEN  = { 150, 210 },  -- minutes
    GUARD        = true,          -- pause if the character gets moved away from the spot
    GUARD_STUDS  = 18,
    MAX_FAILS    = 6,             -- failed casts / no bites in a row before it stops
    TARGET        = 0,    -- 0 = off; N = fish until N are caught, never stops on its own
    CATCH_MIN_ACC = 0.5,  -- a reel counts as caught if the fish was in the bar this much
    WALK_HOME     = true, -- when moved away from the spot, walk back instead of pausing
    WATCHDOG      = 240,  -- seconds without a finished reel before self-repair starts (0 = off)

    ANTI_AFK     = true,
    SAVE         = true,          -- remember panel position and chips (needs writefile)
    DEBUG        = false,         -- print [autofish] lines (the game can read the output log)
}

local Players      = game:GetService("Players")
local VIM          = game:GetService("VirtualInputManager")
local VU           = game:GetService("VirtualUser")
local GuiService   = game:GetService("GuiService")
local UIS          = game:GetService("UserInputService")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")
local lp           = Players.LocalPlayer
local pg           = lp:WaitForChild("PlayerGui")

-- executing again (v3 or v4) shuts the old copy down first
local env = (getgenv and getgenv()) or _G
if type(env.__autofish_stop) == "function" then pcall(env.__autofish_stop) end

local running, count, stage, stopped = true, 0, "start", false
local gui, ui, afk, dbg
local note = ""
local sessionStart, restedAt, sessionEnd = os.clock(), os.clock(), nil
local curAcc, lastAcc, accHit, accAll = nil, nil, 0, 0
local fails, home, mood = 0, nil, 1

---------------------------------------------------------------- helpers

-- the last line shows in the panel; it only reaches the console when Debug is on
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    note = table.concat(parts, " ")
    if CFG.DEBUG then print("[autofish]", note) end
end

local function rand(t)
    if type(t) == "table" then return t[1] + math.random() * (t[2] - t[1]) end
    return t
end

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

local function gauss()
    return math.sqrt(-2 * math.log(math.random() + 1e-9)) * math.cos(2 * math.pi * math.random())
end

-- a delay in { min, max }: uniform with Human off; with Human on it is right-skewed like a real
-- reaction time (most near the low-middle, the odd slow one), scaled by mood and tiredness
local function human(t)
    if type(t) ~= "table" then return t end
    local lo, hi = t[1], t[2]
    if not CFG.HUMAN then return lo + math.random() * (hi - lo) end
    local x = 0.32 + 0.17 * gauss()
    if math.random() < 0.06 then x = x + 0.3 + math.random() * 0.4 end
    x = clamp(x, 0, 1.3)
    local tired = 1 + 0.2 * math.min(1, (os.clock() - restedAt) / 7200)
    return (lo + (hi - lo) * x) * mood * tired
end

local function pause(t) task.wait(human(t)) end

-- now and then a person looks away for a moment
local function lapse(extra)
    if CFG.HUMAN and math.random() < CFG.LAPSE then
        local t = 0.6 + math.random() * extra
        log(string.format("lapse %.1fs", t))
        task.wait(t)
    end
end

local function px(v) return math.floor(v + 0.5) end

-- exists, is parented and, for a ScreenGui, is switched on
local function up(g)
    return g ~= nil and g.Parent ~= nil and (not g:IsA("ScreenGui") or g.Enabled)
end

-- false once this copy has been shut down (executing again, or the panel was destroyed)
local function alive()
    return not stopped and (gui == nil or gui.Parent ~= nil)
end

local function names(inst)
    local t = {}
    for _, c in ipairs(inst:GetChildren()) do t[#t + 1] = c.Name end
    return table.concat(t, ", ")
end

local function tree(inst, depth, budget)
    for _, c in ipairs(inst:GetChildren()) do
        if budget[1] <= 0 then return end
        budget[1] = budget[1] - 1
        log(string.rep("  ", depth) .. c.Name .. " (" .. c.ClassName .. ")")
        tree(c, depth + 1, budget)
    end
end

-- FindFirstChild that ignores case
local function find(parent, name, deep)
    local c = parent:FindFirstChild(name, deep)
    if c then return c end
    local want = name:lower()
    for _, d in ipairs(deep and parent:GetDescendants() or parent:GetChildren()) do
        if d.Name:lower() == want then return d end
    end
    return nil
end

-- first GuiObject below parent whose name contains key
local function like(parent, key)
    for _, d in ipairs(parent:GetDescendants()) do
        if d:IsA("GuiObject") and d.Name:lower():find(key, 1, true) then return d end
    end
    return nil
end

-- an enabled ScreenGui in PlayerGui: exact name first, then one that merely contains it
local function getGui(key)
    local k, close = key:lower(), nil
    for _, c in ipairs(pg:GetChildren()) do
        if c:IsA("ScreenGui") and c.Enabled then
            local n = c.Name:lower()
            if n == k then return c end
            if not close and n:find(k, 1, true) then close = c end
        end
    end
    return close
end

local function viewport()
    local c = workspace.CurrentCamera
    return c and c.ViewportSize or Vector2.new(1280, 720)
end

local function inset()
    local ok, v = pcall(function() return (GuiService:GetGuiInset()) end)
    return ok and v or Vector2.zero
end

local function randName()
    local t = {}
    for i = 1, 10 + math.random(0, 6) do
        local r = math.random(1, 3)
        t[i] = string.char(r == 1 and math.random(65, 90) or r == 2 and math.random(97, 122) or math.random(48, 57))
    end
    return table.concat(t)
end

---------------------------------------------------------------- settings + session

local SAVE_FILE = "autofish_v4.json"
local saved = {}
if CFG.SAVE and type(isfile) == "function" and type(readfile) == "function" then
    pcall(function()
        if isfile(SAVE_FILE) then
            local d = HttpService:JSONDecode(readfile(SAVE_FILE))
            if type(d) == "table" then saved = d end
        end
    end)
end
for _, k in ipairs({ "HUMAN", "BREAKS", "SESSION" }) do
    if type(saved[k]) == "boolean" then CFG[k] = saved[k] end
end
if type(saved.TARGET) == "number" then CFG.TARGET = math.max(0, math.floor(saved.TARGET)) end

local function save()
    if not (CFG.SAVE and type(writefile) == "function") then return end
    pcall(function()
        local c = ui and ui.card
        writefile(SAVE_FILE, HttpService:JSONEncode({
            HUMAN = CFG.HUMAN, BREAKS = CFG.BREAKS, SESSION = CFG.SESSION, TARGET = CFG.TARGET,
            min = ui and ui.collapsed or false,
            x = c and c.Position.X.Offset, y = c and c.Position.Y.Offset,
        }))
    end)
end

local function newSession()
    sessionStart, restedAt = os.clock(), os.clock()
    sessionEnd = CFG.SESSION and (os.clock() + rand(CFG.SESSION_LEN) * 60) or nil
    count, lastAcc, curAcc, accHit, accAll, fails = 0, nil, nil, 0, 0, 0
end
newSession()

---------------------------------------------------------------- panel

local PAL = {
    bg0   = Color3.fromRGB(31, 35, 50),  bg1   = Color3.fromRGB(14, 16, 23),
    line  = Color3.fromRGB(72, 80, 108), cell  = Color3.fromRGB(23, 26, 37),
    track = Color3.fromRGB(40, 45, 61),  text  = Color3.fromRGB(238, 241, 249),
    dim   = Color3.fromRGB(130, 139, 163),
    good  = Color3.fromRGB(62, 207, 128), warn = Color3.fromRGB(255, 190, 70), bad = Color3.fromRGB(236, 90, 90),
    onBtn = Color3.fromRGB(28, 124, 80), offBtn = Color3.fromRGB(174, 56, 56), chipOn = Color3.fromRGB(40, 94, 142),
}

local STAGES = {
    start    = { "Starting",              Color3.fromRGB(150, 160, 186) },
    cast     = { "Casting",               Color3.fromRGB(88, 160, 255) },
    wait     = { "Waiting for a bite",    Color3.fromRGB(255, 196, 70) },
    shake    = { "Shaking",               Color3.fromRGB(176, 128, 255) },
    reel     = { "Reeling",               Color3.fromRGB(62, 214, 130) },
    cooldown = { "Cooldown",              Color3.fromRGB(120, 134, 164) },
    ["break"] = { "Taking a break",       Color3.fromRGB(70, 204, 204) },
    paused   = { "Paused",                Color3.fromRGB(236, 90, 90) },
    limit    = { "Session limit reached", Color3.fromRGB(255, 150, 60) },
    guard    = { "Moved - paused",        Color3.fromRGB(236, 90, 90) },
    stopped  = { "Stopped",               Color3.fromRGB(236, 90, 90) },
    done = { "Target reached", Color3.fromRGB(62, 207, 128) },
    walk = { "Walking back",   Color3.fromRGB(70, 204, 204) },
    fix  = { "Repairing",      Color3.fromRGB(255, 150, 60) },
}

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function round(o, r) return mk("UICorner", { CornerRadius = UDim.new(0, r) }, o) end

local function label(parent, s, size, font, color, pos, sz, align)
    return mk("TextLabel", {
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = s, TextSize = size, Font = font,
        TextColor3 = color, Position = pos, Size = sz, TextTruncate = Enum.TextTruncate.AtEnd,
        TextXAlignment = align or Enum.TextXAlignment.Left,
    }, parent)
end

local function tween(o, props, t)
    pcall(function()
        TweenService:Create(o, TweenInfo.new(t or 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
    end)
end

local shownText = setmetatable({}, { __mode = "k" })
local function setText(o, s)       -- only touch the property when it changed
    if shownText[o] ~= s then
        shownText[o] = s
        o.Text = s
    end
end

local function fmtTime(s)
    s = math.max(0, math.floor(s))
    return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end

local function accColor(a)
    if a == nil then return PAL.dim end
    if a >= 0.9 then return PAL.good elseif a >= 0.75 then return PAL.warn end
    return PAL.bad
end

local function buildPanel(root)
    local W, HF, WM, HM = 232, 240, 190, 36
    local u = { collapsed = saved.min == true }
    local sg = mk("ScreenGui", {
        Name = randName(), ResetOnSpawn = false, DisplayOrder = 999,
        IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    local v = viewport()
    local x0 = clamp(tonumber(saved.x) or 10, 0, math.max(0, v.X - 120))
    local y0 = clamp(tonumber(saved.y) or 58, 0, math.max(0, v.Y - 60))

    local card = mk("Frame", {
        Name = "c", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Active = true,
        ClipsDescendants = true, Position = UDim2.fromOffset(x0, y0),
        Size = UDim2.fromOffset(u.collapsed and WM or W, u.collapsed and HM or HF),
    }, sg)
    round(card, 14)
    mk("UIGradient", { Color = ColorSequence.new(PAL.bg0, PAL.bg1), Rotation = 90 }, card)
    u.stroke = mk("UIStroke", { Color = PAL.line, Thickness = 1.2, Transparency = 0.15 }, card)

    -- header: dot, title (or the pill text when shrunk), shrink button; also the drag handle
    local head = mk("Frame", { BackgroundTransparency = 1, Active = true, Size = UDim2.new(1, 0, 0, HM) }, card)
    u.dot = mk("Frame", {
        BackgroundColor3 = PAL.dim, BorderSizePixel = 0,
        Position = UDim2.fromOffset(13, 13), Size = UDim2.fromOffset(10, 10),
    }, head)
    round(u.dot, 5)
    u.title = label(head, "AutoFish", 14, Enum.Font.GothamBold, PAL.text, UDim2.fromOffset(31, 0), UDim2.new(0, 70, 1, 0))
    u.tag   = label(head, "v4", 11, Enum.Font.GothamMedium, PAL.dim, UDim2.fromOffset(98, 1), UDim2.new(0, 40, 1, 0))
    u.pill  = label(head, "", 12, Enum.Font.GothamBold, PAL.text, UDim2.fromOffset(31, 0), UDim2.new(1, -66, 1, 0))
    u.min = mk("TextButton", {
        AutoButtonColor = false, BackgroundColor3 = PAL.cell, BorderSizePixel = 0, Text = "-",
        TextSize = 16, Font = Enum.Font.GothamBold, TextColor3 = PAL.dim,
        Position = UDim2.new(1, -36, 0, 5), Size = UDim2.fromOffset(28, 26),
    }, head)
    round(u.min, 8)

    -- body
    local body = mk("Frame", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(0, HM), Size = UDim2.new(1, 0, 1, -HM),
    }, card)
    u.body = body
    u.stage = label(body, "Starting", 13, Enum.Font.GothamBold, PAL.dim, UDim2.fromOffset(12, 0), UDim2.fromOffset(140, 22))
    u.time  = label(body, "00:00:00", 11, Enum.Font.GothamMedium, PAL.dim, UDim2.new(1, -92, 0, 0),
        UDim2.fromOffset(80, 22), Enum.TextXAlignment.Right)

    local function cell(i, caption)
        local c = mk("Frame", {
            BackgroundColor3 = PAL.cell, BorderSizePixel = 0,
            Position = UDim2.fromOffset(12 + (i - 1) * 72, 26), Size = UDim2.fromOffset(66, 40),
        }, body)
        round(c, 9)
        label(c, caption, 9, Enum.Font.GothamMedium, PAL.dim, UDim2.fromOffset(8, 4), UDim2.new(1, -16, 0, 12))
        return label(c, "-", 17, Enum.Font.GothamBold, PAL.text, UDim2.fromOffset(8, 16), UDim2.new(1, -16, 0, 20))
    end
    u.caught = cell(1, "CAUGHT")
    u.rate   = cell(2, "PER HOUR")
    u.acc    = cell(3, "ACCURACY")

    local bar = mk("Frame", {
        BackgroundColor3 = PAL.track, BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 73), Size = UDim2.fromOffset(208, 4), ClipsDescendants = true,
    }, body)
    round(bar, 2)
    u.fill = mk("Frame", { BackgroundColor3 = PAL.dim, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0) }, bar)

    u.btn = mk("TextButton", {
        AutoButtonColor = false, BackgroundColor3 = PAL.onBtn, BorderSizePixel = 0, Text = "RUNNING",
        TextSize = 12, Font = Enum.Font.GothamBold, TextColor3 = PAL.text,
        Position = UDim2.fromOffset(12, 84), Size = UDim2.fromOffset(208, 32),
    }, body)
    round(u.btn, 9)

    local defs = { { "Human", "HUMAN" }, { "Breaks", "BREAKS" }, { "Limit", "SESSION" }, { "Debug", "DEBUG" } }
    for i, d in ipairs(defs) do
        local chip = mk("TextButton", {
            AutoButtonColor = false, BorderSizePixel = 0, Text = d[1], TextSize = 11, Font = Enum.Font.GothamMedium,
            Position = UDim2.fromOffset(12 + (i - 1) * 53, 124), Size = UDim2.fromOffset(49, 24),
        }, body)
        round(chip, 8)
        local function look()
            local on = CFG[d[2]]
            chip.BackgroundColor3 = on and PAL.chipOn or PAL.cell
            chip.TextColor3 = on and PAL.text or PAL.dim
        end
        look()
        chip.Activated:Connect(function()
            CFG[d[2]] = not CFG[d[2]]
            if d[2] == "SESSION" and CFG.SESSION then sessionEnd = os.clock() + rand(CFG.SESSION_LEN) * 60 end
            look()
            save()
        end)
    end

    -- target stepper:  [-]  Target 12 / 100  [+]
    local function stepBtn(txt, x, w)
        local b = mk("TextButton", {
            AutoButtonColor = false, BackgroundColor3 = PAL.cell, BorderSizePixel = 0, Text = txt,
            TextSize = 14, Font = Enum.Font.GothamBold, TextColor3 = PAL.text,
            Position = UDim2.fromOffset(x, 154), Size = UDim2.fromOffset(w, 24),
        }, body)
        round(b, 8)
        return b
    end
    local minus, plus = stepBtn("-", 12, 44), stepBtn("+", 176, 44)
    u.tgt = stepBtn("Target: off", 60, 112)
    u.tgt.TextSize, u.tgt.Font = 11, Enum.Font.GothamMedium
    local lastTarget = CFG.TARGET > 0 and CFG.TARGET or 100
    local function setTarget(v)
        CFG.TARGET = math.max(0, math.min(9999, v))
        if CFG.TARGET > 0 then lastTarget = CFG.TARGET end
        save()
    end
    local function stepOf(v, dir)
        if dir > 0 then return v < 100 and 10 or 50 end
        return v <= 100 and 10 or 50
    end
    minus.Activated:Connect(function() setTarget(CFG.TARGET - stepOf(CFG.TARGET, -1)) end)
    plus.Activated:Connect(function() setTarget(CFG.TARGET + stepOf(CFG.TARGET, 1)) end)
    u.tgt.Activated:Connect(function() setTarget(CFG.TARGET > 0 and 0 or lastTarget) end)

    u.note = label(body, "", 10, Enum.Font.Gotham, PAL.dim, UDim2.fromOffset(12, 182), UDim2.fromOffset(208, 14))

    -- shrink / expand
    local function setCollapsed(c)
        u.collapsed = c
        body.Visible = not c
        u.title.Visible, u.tag.Visible, u.pill.Visible = not c, not c, c
        u.min.Text = c and "+" or "-"
        tween(card, { Size = UDim2.fromOffset(c and WM or W, c and HM or HF) }, 0.18)
    end
    u.min.Activated:Connect(function()
        setCollapsed(not u.collapsed)
        save()
    end)
    setCollapsed(u.collapsed)

    -- drag by the header
    local dragging, from, startPos = false, nil, nil
    head.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, from, startPos = true, i.Position, card.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    save()
                end
            end)
        end
    end)
    u.conn = UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d, vp = i.Position - from, viewport()
            card.Position = UDim2.fromOffset(
                clamp(startPos.X.Offset + d.X, 0, math.max(0, vp.X - 80)),
                clamp(startPos.Y.Offset + d.Y, 0, math.max(0, vp.Y - 40)))
        end
    end)

    u.card, u.gui = card, sg
    sg.Parent = root
    return u
end

local function paint()
    if not ui then return end
    local st = STAGES[stage] or STAGES.start
    local col = st[2]
    if ui.col ~= col then
        ui.col = col
        tween(ui.dot, { BackgroundColor3 = col })
        tween(ui.stage, { TextColor3 = col })
        tween(ui.stroke, { Color = col })
    end
    local el = os.clock() - sessionStart
    local a = (stage == "reel" and curAcc) or lastAcc
    setText(ui.stage, st[1])
    setText(ui.pill, string.format("%s - %d", st[1], count))
    setText(ui.time, fmtTime(el))
    setText(ui.caught, tostring(count))
    setText(ui.rate, (count > 0 and el > 90) and tostring(px(count / (el / 3600))) or "-")
    setText(ui.acc, a and string.format("%d%%", px(a * 100)) or "-")
    ui.acc.TextColor3 = accColor(a)
    ui.fill.BackgroundColor3 = accColor(a)
    ui.fill.Size = UDim2.new(a or 0, 0, 1, 0)
    setText(ui.btn, running and "RUNNING  -  tap to pause" or "PAUSED  -  tap to resume")
    ui.btn.BackgroundColor3 = running and PAL.onBtn or PAL.offBtn
    setText(ui.note, note)
    if ui.tgt then
        local on = CFG.TARGET > 0
        setText(ui.tgt, on and string.format("Target %d / %d", count, CFG.TARGET) or "Target: off")
        ui.tgt.BackgroundColor3 = on and PAL.chipOn or PAL.cell
        ui.tgt.TextColor3 = on and PAL.text or PAL.dim
    end
end

local function setRunning(v)
    if v == running then return end
    local midReel = (stage == "reel")
    running = v
    if v then
        if stage == "limit" or stage == "stopped" or stage == "done" then newSession() end
        fails, home = 0, nil
        stage = "start"
    else
        stage = "paused"
        if midReel then log("finishing this reel, then pausing") end
    end
    paint()
end

-- the panel lives in a hidden UI container, never inside PlayerGui
local okHost, root = pcall(function() return (gethui and gethui()) or game:GetService("CoreGui") end)
if okHost and root then
    pcall(function()
        local old = root:FindFirstChild("AutoFishToggle")   -- left behind by v3
        if old then old:Destroy() end
    end)
    local okUi, res = pcall(buildPanel, root)
    if okUi then
        ui, gui = res, res.gui
        ui.btn.Activated:Connect(function() setRunning(not running) end)
    else
        log("panel failed: " .. tostring(res))
    end
else
    log("no hidden UI container on this executor - running without the panel")
end
paint()

if CFG.ANTI_AFK then
    afk = lp.Idled:Connect(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.new())
    end)
end

if CFG.DEBUG then
    local seen = {}
    dbg = pg.ChildAdded:Connect(function(c)
        if not seen[c.Name] then
            seen[c.Name] = true
            log("new GUI:", c.Name, c.ClassName)
        end
    end)
    local okx, ex = pcall(function() return identifyexecutor() end)
    log("v4 | executor:", okx and ex or "?", "| touch:", UIS.TouchEnabled,
        "| keyboard:", UIS.KeyboardEnabled, "| firesignal:", type(firesignal) == "function")
    log("PlayerGui right now:", names(pg))
end

env.__autofish_stop = function()
    stopped, running = true, false
    if afk then afk:Disconnect() end
    if dbg then dbg:Disconnect() end
    if ui and ui.conn then ui.conn:Disconnect() end
    if gui then pcall(function() gui:Destroy() end) end
end

---------------------------------------------------------------- input

-- is something that swallows clicks (a button, an Active frame) drawn at this spot?
local function blocked(x, y)
    local ins = inset()
    for _, yy in ipairs({ y, px(y - ins.Y) }) do
        local ok, list = pcall(function() return pg:GetGuiObjectsAtPosition(x, yy) end)
        if ok then
            for _, o in ipairs(list) do
                if o.Visible and (o.Active or o:IsA("GuiButton") or o:IsA("TextBox")) then return true end
            end
        end
    end
    return false
end

-- is our own panel in the way? (it is not in PlayerGui, so blocked() cannot see it)
local function overUs(x, y)
    if not (ui and ui.card and ui.card.Parent) then return false end
    local p, s, ins = ui.card.AbsolutePosition, ui.card.AbsoluteSize, inset()
    for _, yy in ipairs({ y, y - ins.Y }) do
        if x >= p.X - 12 and x <= p.X + s.X + 12 and yy >= p.Y - 12 and yy <= p.Y + s.Y + 12 then return true end
    end
    return false
end

local SPOTS = {
    { 0.5, 0.42 }, { 0.5, 0.30 }, { 0.36, 0.40 }, { 0.64, 0.40 }, { 0.5, 0.58 },
    { 0.75, 0.5 }, { 0.62, 0.30 }, { 0.25, 0.5 }, { 0.72, 0.62 },
}

-- a spot on the 3D world that no GUI covers, a little different every time
local function point()
    local v = viewport()
    for _, s in ipairs(SPOTS) do
        local x = px(v.X * (s[1] + (math.random() - 0.5) * 0.04))
        local y = px(v.Y * (s[2] + (math.random() - 0.5) * 0.04))
        if not blocked(x, y) and not overUs(x, y) then return x, y end
    end
    return px(v.X * 0.5), px(v.Y * 0.45)
end

-- press / release, one function per way of sending it
local PRESS = {
    mouse  = function(down, x, y) VIM:SendMouseButtonEvent(x, y, 0, down, game, 1) end,
    mouse2 = function(down, x, y) VIM:SendMouseButtonEvent(x, y, 0, down, lp, 0) end,
    touch  = function(down, x, y) VIM:SendTouchEvent(5, down and 0 or 2, x, y) end,
    space  = function(down) VIM:SendKeyEvent(down, Enum.KeyCode.Space, false, game) end,
}

-- somewhere inside a GUI button, in screen coordinates (the top-bar inset is added when needed)
local function btnPoint(b)
    local sg = b:FindFirstAncestorOfClass("ScreenGui")
    local ins = (sg and sg.IgnoreGuiInset) and Vector2.zero or inset()
    local p, s = b.AbsolutePosition, b.AbsoluteSize
    return px(p.X + s.X * (0.3 + math.random() * 0.4) + ins.X),
           px(p.Y + s.Y * (0.3 + math.random() * 0.4) + ins.Y)
end

local SHAKE = {
    nav = function(b)      -- select the button and hit Enter, no coordinates involved
        GuiService.SelectedObject = b
        VIM:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        task.wait(0.03)
        VIM:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
        task.wait(0.03)
        GuiService.SelectedObject = nil
    end,
    click = function(b)
        local x, y = btnPoint(b)
        PRESS.mouse(true, x, y)
        task.wait(0.03 + math.random() * 0.05)
        PRESS.mouse(false, x, y)
    end,
    tap = function(b)
        local x, y = btnPoint(b)
        PRESS.touch(true, x, y)
        task.wait(0.04 + math.random() * 0.04)
        PRESS.touch(false, x, y)
    end,
    signal = function(b)   -- only if the executor has firesignal
        firesignal(b.MouseButton1Click)
        firesignal(b.Activated)
    end,
}

local function castWith(name, rod, x, y)
    if name == "activate" then
        rod:Activate()
        task.wait(rand(CFG.CAST_HOLD))
        pcall(function() rod:Deactivate() end)
    else
        PRESS[name](true, x, y)
        task.wait(rand(CFG.CAST_HOLD))
        PRESS[name](false, x, y)
    end
end

-- keeps one working method per job; after `need` misses in a row it moves to the next one
local function chooser(list, need)
    local c = { i = 1, wins = {}, fails = {} }
    function c.cur() return list[c.i] end
    function c.ok()
        local k = list[c.i]
        c.wins[k] = (c.wins[k] or 0) + 1
        c.fails[k] = 0
    end
    function c.bad()
        local k = list[c.i]
        c.fails[k] = (c.fails[k] or 0) + 1
        if c.fails[k] >= need + ((c.wins[k] or 0) > 0 and 2 or 0) then
            c.fails[k] = 0
            c.i = c.i % #list + 1
            log("switching to", list[c.i])
        end
    end
    return c
end

local C = chooser(CFG.CAST_ORDER, 1)
local S = chooser(CFG.SHAKE_ORDER, 3)
local H = chooser(CFG.HOLD_ORDER, 2)

---------------------------------------------------------------- game logic

local function isRod(t)
    if not t:IsA("Tool") then return false end
    local n = t.Name:lower()
    if CFG.ROD_NAME then return n == CFG.ROD_NAME:lower() end
    if n:find("rod", 1, true) then return true end
    return t:FindFirstChild("events") ~= nil and t:FindFirstChild("values") ~= nil
        and not n:find("harpoon", 1, true) and not n:find("spear", 1, true)
end

-- the rod in your hand, or the first one in the backpack (gets equipped)
local function getRod()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    for _, t in ipairs(char:GetChildren()) do
        if isRod(t) then return t, hum end
    end
    local bp = lp:FindFirstChildOfClass("Backpack")
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if isRod(t) then
                hum:EquipTool(t)
                task.wait(0.5)
                return t, hum
            end
        end
    end
    return nil
end

local useBobber = true

-- the game puts a "bobber" inside the rod while the line is out
local function lineOut(rod)
    return useBobber and rod.Parent ~= nil and rod:FindFirstChild("bobber") ~= nil
end

local function getShake()
    return getGui(CFG.GUI_SHAKE)
end

-- visible all the way up to its ScreenGui?
local function shown(o)
    while o and not o:IsA("ScreenGui") do
        if o:IsA("GuiObject") and not o.Visible then return false end
        o = o.Parent
    end
    return o ~= nil
end

-- returns the reel GUI plus the white bar and the fish icon (nil while they aren't on screen)
local function getReel()
    local g = getGui(CFG.GUI_REEL)
    if not g then return nil end
    local bar  = find(g, CFG.BAR_NAME, true) or like(g, "player")
    local fish = find(g, CFG.FISH_NAME, true) or like(g, "fish")
    if bar and not (shown(bar) and bar.AbsoluteSize.X > 2) then bar = nil end
    if fish and not shown(fish) then fish = nil end
    return g, bar, fish
end

local function reelReady()
    local g, bar, fish = getReel()
    return g ~= nil and bar ~= nil and fish ~= nil
end

-- cast and wait until something proves it worked; otherwise try the next method
local function castLine(rod)
    for _ = 1, #CFG.CAST_ORDER * 2 do
        if not (alive() and running) then return false end
        local m = C.cur()
        local x, y = point()
        log("cast via", m)
        local ok, err = pcall(castWith, m, rod, x, y)
        if not ok then
            log("cast method failed:", m, err)
            if m ~= "activate" then pcall(PRESS[m], false, x, y) end
            C.bad()
        else
            local t, seen = os.clock(), false
            while alive() and running and os.clock() - t < CFG.CAST_VERIFY do
                if lineOut(rod) or getShake() or reelReady() then
                    seen = true
                    break
                end
                task.wait(0.1)
            end
            if seen then
                C.ok()
                return true
            end
            log("cast via", m, "did nothing")
            C.bad()
            task.wait(0.6)
        end
    end
    return false
end

-- one shake press; counts as a hit if the button vanished, closed or moved
local function shakeOnce(shake)
    local b = find(shake, CFG.SHAKE_BUTTON, true)
    if not (b and b.Visible and b.AbsoluteSize.X > 2) then return end
    local m = S.cur()
    local p0 = b.AbsolutePosition
    local ok, err = pcall(SHAKE[m], b)
    if not ok then
        log("shake method failed:", m, err)
        S.bad()
        return
    end
    local t, hit = os.clock(), false
    while os.clock() - t < 0.4 do
        task.wait(0.03)
        if not up(shake) or not b.Parent or not b.Visible or (b.AbsolutePosition - p0).Magnitude > 2 then
            hit = true
            break
        end
    end
    if hit then
        S.ok()
    else
        log("shake via", m, "had no effect")
        S.bad()
    end
end

---------------------------------------------------------------- reel brain
-- Pure maths, no Roblox calls. Each frame it gets where the fish and the bar are and answers
-- "hold or release?". It learns how fast the bar speeds up (hold) and slows down (release), keeps
-- track of the commands still in flight (input lag), aims at where the fish will be, stays inside
-- the track and brakes early enough not to overshoot.
local function newBrain(opts)
    opts = opts or {}
    local human = opts.human
    local B = {}
    local clamp = function(v, a, b) if v < a then return a elseif v > b then return b end return v end

    local ts, fs, bs, n = {}, {}, {}, 0          -- recent samples
    local aHold, aRel = nil, nil                 -- learned accelerations (px/s^2), kept between reels
    if opts.mem then aHold, aRel = opts.mem.aHold, opts.mem.aRel end
    local holdNow, since, lastSwitch = false, 0, -1
    local fv, bv, avgDt = 0, 0, 1 / 60
    local vmax, vR, vL = 0, 0, 0
    local wob, wobT = 0, 0
    local stable = 0                              -- seconds the command has been unchanged
    local hist = {}                               -- { time, command } every time the command changed
    local function cmdAt(tau)
        for i = #hist, 1, -1 do
            if hist[i][1] <= tau then return hist[i][2] end
        end
        return false
    end

    local function slope(arr, from)
        -- least squares slope of arr[from..n] against ts
        local cnt = n - from + 1
        if cnt < 2 then return 0 end
        local mt, mx = 0, 0
        for i = from, n do mt = mt + ts[i]; mx = mx + arr[i] end
        mt, mx = mt / cnt, mx / cnt
        local num, den = 0, 0
        for i = from, n do
            local dt = ts[i] - mt
            num = num + dt * (arr[i] - mx)
            den = den + dt * dt
        end
        if den < 1e-9 then return 0 end
        return num / den
    end

    -- now, fish centre, bar centre, bar width, fish width, track left, track right
    function B.step(now, f, b, bw, fw, L, R)
        n = n + 1
        ts[n], fs[n], bs[n] = now, f, b
        if n > 8 then
            table.remove(ts, 1); table.remove(fs, 1); table.remove(bs, 1); n = 8
        end
        if n >= 2 then
            local d = ts[n] - ts[n - 1]
            if d > 0 and d < 0.25 then avgDt = avgDt * 0.9 + d * 0.1 end
        end
        -- window: last ~80 ms, at least 3 samples when available
        local from = n
        while from > 1 and (ts[n] - ts[from - 1]) <= 0.085 and n - from < 5 do from = from - 1 end
        if n - from < 2 and from > 1 then from = math.max(1, n - 2) end
        local newFv, newBv = slope(fs, from), slope(bs, from)
        local prevBv = bv
        fv, bv = newFv, newBv
        if math.abs(bv) > vmax then vmax = math.abs(bv) end
        if bv > vR then vR = bv end
        if -bv > vL then vL = -bv end

        local len = math.max(R - L, 50)
        local a0 = len * 4
        if not aHold then aHold, aRel = a0, a0 end

        -- learn the bar's response from stretches where the command was stable
        stable = stable + avgDt
        local dtv = (n >= 2) and (ts[n] - ts[n - 1]) or avgDt
        if stable > (0.04 + 2.5 * avgDt) and dtv > 0 then
            local acc = (bv - prevBv) / dtv
            local pinned = (b - bw / 2 <= L + 2) or (b + bw / 2 >= R - 2)
            if not pinned and math.abs(bv) < 0.8 * math.max(vmax, 1) + 1 then
                if holdNow and acc > 0 then
                    aHold = clamp(aHold * 0.93 + acc * 0.07, a0 * 0.15, a0 * 12)
                elseif (not holdNow) and acc < 0 then
                    aRel = clamp(aRel * 0.93 - acc * 0.07, a0 * 0.15, a0 * 12)
                end
            end
        end

        -- where do we want the bar? the fish, nudged a little inside the safe margin
        local margin = math.max(0, bw / 2 - fw / 2)
        if human then
            if now > wobT then
                wob = (math.random() * 2 - 1) * 0.35 * margin
                wobT = now + 0.35 + math.random() * 0.8
            end
        else
            wob = 0
        end
        local lat = clamp(0.03 + 1.6 * avgDt, 0.04, 0.17)
        local lo, hi = L + bw / 2, R - bw / 2
        local fP = f + fv * lat
        local comfort = clamp(1 - math.abs(f - b) / math.max(margin * 0.7, 1), 0, 1)
        local raw = fP + wob * comfort
        local tgt = clamp(raw, lo, hi)
        local tv = (raw < lo or raw > hi) and 0 or fv      -- a target pinned to a wall stands still

        -- where the bar will be once the commands already in flight have landed
        local capR = (vR > len * 0.15) and vR * 1.03 or len * 0.8
        local capL = (vL > len * 0.15) and vL * 1.03 or len * 0.8
        local steps, h = 6, lat / 6
        local bP, bvP = b, bv
        for i = 1, steps do
            local c = cmdAt(now + (i - 1) * h - lat)
            bvP = clamp(bvP + (c and aHold or -aRel) * h, -capL, capR)
            bP = bP + bvP * h
        end
        local rv = bvP - tv
        local stop
        if rv > 0 then stop = rv * rv / (2 * aRel) else stop = -rv * rv / (2 * aHold) end
        stop = clamp(stop, -len * 0.6, len * 0.6)
        local e = tgt - (bP + stop)               -- >0: bar will stop short of the target -> hold

        local band = math.max(1, bw * 0.03)
        local want = holdNow
        if e > band then want = true elseif e < -band then want = false end
        -- sitting on a wall with the target beyond it: just keep pushing
        if tgt >= hi - 0.5 and fP >= hi then want = true end
        if tgt <= lo + 0.5 and fP <= lo then want = false end
        if want ~= holdNow then
            lastSwitch = now; stable = 0
            hist[#hist + 1] = { now, want }
            if #hist > 24 then table.remove(hist, 1) end
        end
        holdNow = want
        if opts.mem then opts.mem.aHold, opts.mem.aRel = aHold, aRel end
        return want, { zone = math.abs(f - b) <= bw / 2, bv = bv, fv = fv, aHold = aHold, aRel = aRel }
    end
    return B
end

local brainMem = {}   -- what the brain learned about your bar; kept between reels

-- the minigame: keep the white bar under the fish icon until the GUI closes
local function playReel(reel, bar, fish)
    local track = bar.Parent
    local hx, hy = point()
    local function mid(g) return g.AbsolutePosition.X + g.AbsoluteSize.X / 2 end

    local cur, down, holdT, peak = nil, false, 0, 0
    local function setHold(want)
        local name = H.cur()
        if down and (not want or name ~= cur) then
            pcall(PRESS[cur], false, hx, hy)
            down = false
        end
        if want and not down and up(reel) then
            cur = name
            if pcall(PRESS[name], true, hx, hy) then
                down, holdT, peak = true, os.clock(), 0
            else
                H.bad()
            end
        end
    end

    pause(CFG.HUMAN and CFG.REEL_START or { 0.03, 0.09 })   -- a person needs a moment to react
    local brain = newBrain({ human = CFG.HUMAN, mem = brainMem })
    local t0 = os.clock()
    local last, lastPaint, hit, all = t0, t0, 0, 0
    local ok, err = pcall(function()
        while alive() and up(reel) and os.clock() - t0 < CFG.REEL_TIMEOUT do   -- finishes even if paused mid-reel
            if not (bar.Parent and fish.Parent) then break end
            local now = os.clock()
            local bw, fw = bar.AbsoluteSize.X, fish.AbsoluteSize.X
            local f, b = mid(fish), mid(bar)
            local L, R
            if track and track.AbsoluteSize.X > 2 then
                L = track.AbsolutePosition.X
                R = L + track.AbsoluteSize.X
            else
                L, R = 0, viewport().X
            end

            local want, info = brain.step(now, f, b, bw, fw, L, R)
            setHold(want)

            local dt = now - last
            last = now
            if dt > 0 and dt < 0.5 then
                all = all + dt
                if info.zone then hit = hit + dt end
            end
            if now - lastPaint > 0.25 and all > 0 then
                curAcc, lastPaint = hit / all, now
            end

            -- is the hold doing anything? if the bar never speeds up to the right, switch input method
            if down then
                if info.bv > peak then peak = info.bv end
                if now - holdT > 0.6 then
                    local edge = b + bw / 2 >= R - 3
                    if peak > math.max(40, (R - L) * 0.1) then H.ok() elseif not edge then H.bad() end
                    holdT, peak = now, 0
                end
            end
            RunService.Heartbeat:Wait()
        end
    end)
    setHold(false)
    if all > 0.5 then
        lastAcc = hit / all
        accHit, accAll = accHit + hit, accAll + all
        log(string.format("reel done - accuracy %d%%", px(lastAcc * 100)))
    end
    curAcc = nil
    if not ok then log("reel: " .. tostring(err)) end
end

local nextBreak = os.clock() + rand(CFG.BREAK_EVERY)

local function maybeBreak()
    if CFG.BREAKS and os.clock() >= nextBreak then
        local len = rand(CFG.BREAK_LEN)
        log(string.format("break for %ds", math.floor(len)))
        stage = "break"
        local t = os.clock()
        while alive() and running and os.clock() - t < len do task.wait(0.5) end
        nextBreak = os.clock() + rand(CFG.BREAK_EVERY)
        restedAt = os.clock()
    end
end

---------------------------------------------------------------- self-repair

local homeLook, pulse, rung = nil, os.clock(), 0

local function releaseAll()
    local x, y = point()
    for _, m in ipairs({ "mouse", "mouse2", "touch", "space" }) do
        pcall(PRESS[m], false, x, y)
    end
end

-- walk back to the spot, ending up facing the way you started; true if it got there
local function goHome(hum, root)
    if not (home and hum and root) then return false end
    stage = "walk"
    log("walking back to the spot")
    local function walk(to, tol, secs)
        local t0 = os.clock()
        while alive() and running and os.clock() - t0 < secs do
            if (root.Position - to).Magnitude <= tol then return true end
            hum:MoveTo(to)
            task.wait(0.3)
        end
        return (root.Position - to).Magnitude <= tol
    end
    local look = homeLook and Vector3.new(homeLook.X, 0, homeLook.Z) or Vector3.zero
    if look.Magnitude > 0.1 and not walk(home - look.Unit * 6, 4, 40) then return false end
    return walk(home, 2.5, 10)
end

-- one repair step per call, each step stronger; true only when it gives up for good
local function recover(why)
    rung = rung + 1
    stage = "fix"
    log(string.format("%s - repair step %d", why, rung))
    releaseAll()
    if rung >= 2 then
        for _, c in ipairs({ C, S, H }) do c.i, c.wins, c.fails = 1, {}, {} end
        useBobber = true
    end
    local rod, hum = getRod()
    if rod and hum then
        pcall(function()
            hum:UnequipTools()
            task.wait(0.6)
            hum:EquipTool(rod)
            task.wait(0.6)
        end)
        if rung >= 3 and home then
            local c = lp.Character
            local r = c and c:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - home).Magnitude > 4 then goHome(hum, r) end
        end
    end
    if rung >= 4 then
        local t = 120 + math.random() * 90
        log(string.format("resting %ds, then trying again", math.floor(t)))
        local t0 = os.clock()
        while alive() and running and os.clock() - t0 < t do task.wait(0.5) end
        if CFG.TARGET > 0 then
            rung = 0
            return false
        end
        running, stage = false, "stopped"
        log("stopped: all repair steps used - check spot, rod and bag")
        return true
    end
    return false
end

-- one miss; true when it is time to stop for good
local function failed(why)
    fails = fails + 1
    if fails >= CFG.MAX_FAILS then
        fails = 0
        return recover(why)
    end
    if fails >= 3 then
        local t = 15 + math.random() * 25
        log(string.format("%s - waiting %ds", why, math.floor(t)))
        local t0 = os.clock()
        while alive() and running and os.clock() - t0 < t do task.wait(0.5) end
    end
    return false
end

local function cycle()
    local rod, hum = getRod()
    if not rod then
        log("no rod in your hands or backpack - equip one and I'll carry on")
        task.wait(3)
        return
    end

    if CFG.GUARD then
        local c = lp.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if r then
            if not home then
                home, homeLook = r.Position, r.CFrame.LookVector
            elseif (r.Position - home).Magnitude > CFG.GUARD_STUDS then
                local far = math.floor((r.Position - home).Magnitude)
                if CFG.WALK_HOME and goHome(hum, r) then
                    log("back on the spot")
                elseif CFG.TARGET > 0 then
                    recover("moved " .. far .. " studs")
                    return
                else
                    running, stage = false, "guard"
                    log(string.format("moved %d studs from the spot - paused", far))
                    return
                end
            end
        end
    end

    mood = clamp(mood + (math.random() - 0.5) * 0.14, 0.85, 1.25)

    if not (reelReady() or getShake()) then
        if lineOut(rod) then pause({ 1.0, 1.6 }) end   -- may still be reeling in the last catch
        if not lineOut(rod) then                        -- (a line already out = script started mid-cast)
            stage = "cast"
            if not castLine(rod) then
                if alive() and running then
                    log("the cast never registers - face the water and check the rod")
                    failed("cast failed")
                end
                task.wait(3)
                return
            end
        end
    end

    stage = "wait"
    local t0, done, warned, shaken = os.clock(), false, false, false
    while alive() and running and os.clock() - t0 < CFG.TIMEOUT do
        local reel, bar, fish = getReel()
        if reel and bar and fish then
            stage = "reel"
            log("reel minigame")
            local a0, h0 = accAll, accHit
            playReel(reel, bar, fish)
            local acc = (accAll > a0) and (accHit - h0) / (accAll - a0) or nil
            pulse = os.clock()
            if acc == nil or acc >= CFG.CATCH_MIN_ACC then
                count, rung = count + 1, 0
            else
                log(string.format("fish got away (%d%%) - not counted", px(acc * 100)))
            end
            done = true
            local t1 = os.clock()
            while up(reel) and os.clock() - t1 < 8 do task.wait(0.2) end
            break
        else
            if reel and not warned then
                warned = true
                log("reel GUI is up but '" .. CFG.BAR_NAME .. "' / '" .. CFG.FISH_NAME .. "' not found, GUI tree below")
                tree(reel, 0, { 40 })
            end
            local shake = getShake()
            if shake then
                stage = "shake"
                if not shaken then
                    shaken = true
                    pause(CFG.SHAKE_FIRST)   -- nobody presses the instant it shows up
                    lapse(1.2)
                end
                shakeOnce(shake)
                pause(CFG.SHAKE_GAP)
            else
                task.wait(0.1)
            end
        end
    end

    if alive() and running then
        if done then
            fails = 0
        else
            log("nothing after " .. CFG.TIMEOUT .. "s - pulling the line back")
            pcall(function()
                hum:UnequipTools()
                task.wait(0.5)
                hum:EquipTool(rod)
                task.wait(0.5)
            end)
            if failed("no bite") then return end
        end
    end

    stage = "cooldown"
    pause(CFG.COOLDOWN)
    if done then   -- a catch just ended, so the line is in: a bobber that stays is a stale one
        local t2 = os.clock()
        while lineOut(rod) and os.clock() - t2 < 2 do task.wait(0.2) end
        if lineOut(rod) then
            useBobber = false
            log("bobber stays after a catch - not trusting the bobber check any more")
        end
    end
    maybeBreak()

    if CFG.TARGET > 0 and count >= CFG.TARGET and running then
        running, stage = false, "done"
        log("target reached: " .. count .. " caught")
    elseif CFG.SESSION and CFG.TARGET <= 0 and sessionEnd and os.clock() >= sessionEnd and running then
        running, stage = false, "limit"
        log("session limit reached - resume for a fresh one")
    end
end

---------------------------------------------------------------- go

task.spawn(function()
    while alive() do
        paint()
        task.wait(0.25)
    end
end)

local main
local function startMain()
    main = task.spawn(function()
        while alive() do
            if running then
                local ok, err = pcall(cycle)
                if not ok then
                    log("error: " .. tostring(err))
                    task.wait(2)
                end
            else
                task.wait(0.3)
            end
        end
        if afk then afk:Disconnect() end
        if dbg then dbg:Disconnect() end
        if ui and ui.conn then ui.conn:Disconnect() end
    end)
end
startMain()

-- watchdog: no finished reel for CFG.WATCHDOG seconds -> kill the loop, repair, restart it
task.spawn(function()
    while alive() do
        task.wait(2)
        local idle = (not running) or stage == "break" or stage == "walk" or stage == "fix"
        if idle or CFG.WATCHDOG <= 0 then
            pulse = os.clock()
        elseif os.clock() - pulse > CFG.WATCHDOG then
            log("watchdog: nothing finished for " .. CFG.WATCHDOG .. "s")
            if main then pcall(task.cancel, main) end
            recover("watchdog")
            pulse = os.clock()
            if alive() then startMain() end
        end
    end
end)

log("started - tap the panel button to pause")
