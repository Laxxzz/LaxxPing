-------------------------------------------------------------------------------
--  LaxxPing.lua -- hold a key, left-click to open a ping wheel at the cursor,
--  flick toward an entry, release to send.
--
--  HOW IT WORKS, and why it is shaped this way. Every claim below was measured
--  in game on retail 12.1.0, 2026-08-23, with a purpose-built probe -- none of
--  it is inference.
--
--  1. The ping itself is "/ping [@cursor] N" run from a SecureActionButton's
--     macrotext. The @cursor token makes SendMacroPing take its forcePointPing
--     branch, which "pass[es] through all UI and ignore[s] units, only
--     targetting the environment (also ignores Ping Target setting)"
--     -- Blizzard_PingManager.lua. That is the whole environment-only feature;
--     no CVar is written, so there is no state to restore and nothing to leak
--     if a gesture is abandoned half way.
--
--  2. Types are addressed NUMERICALLY (1..6). The slash handler also accepts
--     localized names, but those keys are the PING_TYPE_* GlobalStrings
--     uppercased -- "/ping attack" silently degrades to an untyped ping on any
--     non-enUS client. Numbers are locale-proof. Display names still come from
--     the GlobalStrings, because those SHOULD be localized.
--
--  3. The mouse button that opens the wheel is claimed as an override binding
--     from INSIDE a secure snippet, for exactly as long as the hold key is
--     down. From Lua it would be blocked the moment the player entered combat,
--     which is when a ping matters most. Claiming it also suppresses camera
--     rotate for the duration, which is what makes a click-and-flick gesture
--     possible at all.
--
--  4. THE CLAIMED BUTTON NEEDS ITS OWN SECURE BUTTON. This is not a style
--     choice. A mouse click delivered to the same frame the held keybind is
--     routed to destroys that keybind's pending up-edge, and the release is
--     then never delivered -- so the teardown never runs and the claimed mouse
--     button stays claimed until the next press. Measured, A/B'd, and fixed
--     outright by splitting the two frames. Do not merge them back.
--
--  5. Which entry a release fires is decided INSIDE the snippet, because an
--     addon may not write a protected frame's attributes during combat. The
--     resolve is angular from the origin the opening click captured, with a
--     dead-zone floor and no outer bound -- so choosing an entry costs a flick
--     past the dead zone, not a journey out to its icon.
--
--  6. The ping lands wherever the cursor is when the macro RUNS, i.e. at the
--     release. It cannot be made to land at the opening click: Blizzard's own
--     wheel captures its target up front with C_PingSecure.SetHitTestPingTarget
--     and fires it later with SendHitTestPing, and that namespace is
--     SecureOnly. Input.SetCursorPosition would let us put the pointer back,
--     but it is RequiresLimitedInput -- "Insecure code can only call this once
--     in response to gamepad input hardware events." So the dead zone IS the
--     accuracy budget, and it is deliberately small and user-settable.
-------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME

-------------------------------------------------------------------------------
--  The ping types, in wheel order.
--
--  cmd is the NUMBER the slash handler maps to Enum.PingSubjectType; name is
--  the localized GlobalString, with an English fallback for the rare client
--  that has not got one. Never send `name` -- see note 2 in the header.
-------------------------------------------------------------------------------
ns.PING_TYPES = {
    { key = "attack",    num = 1, atlas = "Ping_Marker_Icon_Attack",    name = PING_TYPE_ATTACK    or "Attack" },
    { key = "warning",   num = 2, atlas = "Ping_Marker_Icon_Warning",   name = PING_TYPE_WARNING   or "Warning" },
    { key = "onmyway",   num = 3, atlas = "Ping_Marker_Icon_OnMyWay",   name = PING_TYPE_ON_MY_WAY or "On My Way" },
    { key = "assist",    num = 4, atlas = "Ping_Marker_Icon_Assist",    name = PING_TYPE_ASSIST    or "Assist" },
    { key = "nonthreat", num = 5, atlas = "Ping_Marker_Icon_NonThreat", name = PING_TYPE_NOT_THREAT or "Non-Threat" },
    { key = "threat",    num = 6, atlas = "Ping_Marker_Icon_Threat",    name = PING_TYPE_THREAT    or "Threat" },
}

-- One accent, one hue. Everything else the addon draws is white or black at an
-- alpha -- see LaxxPing_Options.lua.
ns.ACCENT = { 0.28, 0.55, 0.92 }

ns.MIN_DEAD_ZONE, ns.MAX_DEAD_ZONE = 4, 48
ns.MIN_RADIUS, ns.MAX_RADIUS = 60, 200

-- The mouse-button token the claimed key arrives under, so the snippet can
-- tell it from the hold key (which arrives as "LeftButton",
-- SetOverrideBindingClick's default). A REAL button name rather than an
-- invented token: RegisterForClicks("AnyDown","AnyUp") covers it for certain,
-- and both buttons are EnableMouse(false), so no physical button 4 can reach
-- them and be mistaken for it.
local CLICK_TOKEN = "Button4"

-- The physical button the wheel claims while the hold key is down. Claiming it
-- is also what suppresses camera rotate, which is what makes a click-and-flick
-- gesture possible at all.
local OPEN_KEY = "BUTTON1"

-- How long a claim may stand before the backstop in Tick assumes an edge was
-- lost and hands the mouse button back. Generous: a player may legitimately
-- hold the wheel open while deciding.
local STUCK_SECONDS = 20

-- Blizzard's plate/border values for a ping wheel entry, matched deliberately
-- so this reads as the same family of control rather than as a second opinion.
local PLATE_IDLE = { 0.05, 0.05, 0.06, 0.65 }
local PLATE_SEL_ALPHA = 0.9
local PLATE_SEL_MUL = 0.22
local BORDER_IDLE = 2
local BORDER_SEL = 2
local HUB_SIZE = 40

local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-------------------------------------------------------------------------------
--  Saved variables
--
--  Nil-safe on a fresh install and KEY-safe on upgrade: a DB written by an
--  older version is missing every key added since, and `DB = DB or {}` does
--  not cover that. The merge walks the defaults, so a new key appears with its
--  default and a key the user has set is left alone.
-------------------------------------------------------------------------------
local DEFAULTS = {
    enabled = true,
    -- The accuracy budget. 12 is a deliberate middle: large enough that the
    -- direction of a flick is unambiguous and hand jitter cannot pick an entry,
    -- small enough that the ping lands within a few pixels of the click. Near
    -- the centre the pointer's angle is too unstable to select by, which is
    -- why MIN_DEAD_ZONE is not 1.
    deadZone = 12,
    radius = 100,
    iconSize = 40,
    -- Release without moving -> an untyped contextual ping at exactly the
    -- click point. The only gesture with zero displacement, and the most
    -- common ping, so it is on by default. Off makes a no-move release cancel.
    plainOnNoMove = true,
    -- The whole point of the addon, but switchable: off sends ordinary pings
    -- that obey the pingTarget setting and can land on units.
    environmentOnly = true,
    enabledTypes = {
        attack = true, warning = true, onmyway = true,
        assist = true, nonthreat = true, threat = false,
    },
}
ns.DEFAULTS = DEFAULTS

local db

local function MergeDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            MergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function ns.DB()
    return db
end

-------------------------------------------------------------------------------
--  One physical pixel, in a given frame's own space.
--
--  Height, not width: WoW's UI space is 768 units tall whatever the aspect
--  ratio, so the height ratio is exact where a width ratio only agrees at 4:3.
--  The last known-good height is kept because GetPhysicalScreenSize returns 0
--  or nil during a display-mode change, and dividing by that makes every
--  snapped size NaN long after the change that caused it.
-------------------------------------------------------------------------------
local perfect, physH

local function RefreshPhysical()
    local _, h = GetPhysicalScreenSize()
    if h and h > 0 then physH = h
    elseif not physH then physH = 1080 end
    perfect = 768 / physH
end
RefreshPhysical()
ns.RefreshPhysical = RefreshPhysical

local function OnePixel(frame)
    local s = frame and frame:GetEffectiveScale() or 1
    if s <= 0 then s = 1 end
    return perfect / s
end
ns.OnePixel = OnePixel

-- Four flat strips in a container of their own, not BackdropTemplate: an
-- edgeFile scales with its frame, so a "1px" edge is 1px at exactly one size.
-- The container gives one object to show, recolour and re-thickness instead of
-- four loose textures every caller has to track.
local function CreateBorder(host, level)
    local c = CreateFrame("Frame", nil, host)
    c:SetAllPoints(host)
    c:SetFrameLevel(host:GetFrameLevel() + (level or 1))
    c.edges = {}
    local function edge(p1, p2)
        local t = c:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 1)
        t:SetSnapToPixelGrid(false)
        t:SetTexelSnappingBias(0)
        t:SetPoint(p1)
        t:SetPoint(p2)
        c.edges[#c.edges + 1] = t
        return t
    end
    c.top = edge("TOPLEFT", "TOPRIGHT")
    c.bottom = edge("BOTTOMLEFT", "BOTTOMRIGHT")
    c.left = edge("TOPLEFT", "BOTTOMLEFT")
    c.right = edge("TOPRIGHT", "BOTTOMRIGHT")
    return c
end
ns.CreateBorder = CreateBorder

local function UpdateBorder(c, thickness, r, g, b, a)
    local px = OnePixel(c) * (thickness or 1)
    c.top:SetHeight(px)
    c.bottom:SetHeight(px)
    c.left:SetWidth(px)
    c.right:SetWidth(px)
    for i = 1, #c.edges do
        c.edges[i]:SetVertexColor(r, g, b, a)
    end
end
ns.UpdateBorder = UpdateBorder

-------------------------------------------------------------------------------
--  Which entries are on the wheel right now.
--
--  ONE list, read by both the drawing and the secure push, so the icon the
--  player flicks at and the command the snippet fires can never disagree.
-------------------------------------------------------------------------------
local entries = {}

local function RebuildEntries()
    wipe(entries)
    for _, t in ipairs(ns.PING_TYPES) do
        if db.enabledTypes[t.key] then
            entries[#entries + 1] = t
        end
    end
    return entries
end
ns.Entries = function() return entries end

local function PingCommand(num)
    local target = db.environmentOnly and "[@cursor] " or ""
    if num then return "/ping " .. target .. num end
    return "/ping " .. (db.environmentOnly and "[@cursor]" or "")
end

-------------------------------------------------------------------------------
--  The wheel. Insecure and unprotected: it decides nothing, it only draws what
--  the snippet will independently work out for itself, so it is free to be an
--  ordinary frame that can be shown and moved during combat.
-------------------------------------------------------------------------------
local wheel, clickBtn, holdBtn, claimer, header

local function BuildHub(parent)
    local hub = CreateFrame("Frame", nil, parent)
    hub:SetSize(HUB_SIZE, HUB_SIZE)
    hub:SetPoint("CENTER")

    -- A filled disc is a white texture with a circular mask. Two of them, the
    -- inner one a touch smaller and dark, leaves the accent showing as a ring.
    local function disc(size, layer, sublevel)
        local t = hub:CreateTexture(nil, layer, nil, sublevel)
        t:SetColorTexture(1, 1, 1, 1)
        t:SetSize(size, size)
        t:SetPoint("CENTER")
        local m = hub:CreateMaskTexture()
        m:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetSize(size, size)
        m:SetPoint("CENTER")
        t:AddMaskTexture(m)
        return t
    end

    hub.ring = disc(HUB_SIZE, "ARTWORK", 1)
    hub.fill = disc(HUB_SIZE - 4, "ARTWORK", 2)

    -- The L, as two strips. Bounding box 10 x 16 about the hub's centre, so
    -- the glyph is optically centred inside the ring without a media file.
    local function stroke(w, h)
        local t = hub:CreateTexture(nil, "ARTWORK", nil, 3)
        t:SetColorTexture(1, 1, 1, 1)
        t:SetSnapToPixelGrid(false)
        t:SetTexelSnappingBias(0)
        t:SetSize(w, h)
        t:SetPoint("BOTTOMLEFT", hub, "CENTER", -5, -8)
        return t
    end
    hub.stem = stroke(3, 16)
    hub.foot = stroke(10, 3)

    return hub
end

local function BuildWheel()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetSize(1, 1)
    f:EnableMouse(false)
    f:Hide()

    -- The dead zone, drawn. Showing the budget is what lets a player learn how
    -- small a flick actually is instead of over-travelling every time.
    f.dz = f:CreateTexture(nil, "BACKGROUND")
    f.dz:SetColorTexture(1, 1, 1, 0.06)
    f.dz:SetPoint("CENTER")
    local dzMask = f:CreateMaskTexture()
    dzMask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    dzMask:SetPoint("CENTER")
    f.dz:AddMaskTexture(dzMask)
    f.dzMask = dzMask

    -- The connector, from the hub to whatever is selected. A plain strip whose
    -- centre sits at the midpoint and which is rotated to face the entry: an
    -- unrotated texture points along +y, so the rotation is the entry's angle
    -- less a quarter turn.
    f.needle = f:CreateTexture(nil, "BACKGROUND")
    f.needle:SetColorTexture(1, 1, 1, 1)
    f.needle:SetSnapToPixelGrid(false)
    f.needle:SetTexelSnappingBias(0)
    f.needle:Hide()

    f.hub = BuildHub(f)
    f.slots = {}
    return f
end

-- One entry. Plate, cropped icon, border -- the same three layers Blizzard's
-- own wheel entries carry, at the same weights.
local function AcquireSlot(i)
    local s = wheel.slots[i]
    if s then return s end

    s = CreateFrame("Frame", nil, wheel)
    s.bg = s:CreateTexture(nil, "BACKGROUND")
    s.bg:SetColorTexture(1, 1, 1, 1)
    s.bg:SetAllPoints(s)

    s.icon = s:CreateTexture(nil, "ARTWORK")
    s.icon:SetPoint("TOPLEFT", 2, -2)
    s.icon:SetPoint("BOTTOMRIGHT", -2, 2)

    s.border = CreateBorder(s, 1)
    wheel.slots[i] = s
    return s
end

local function LayoutWheel()
    local n = #entries
    local radius = db.radius
    local size = db.iconSize
    local dz = db.deadZone

    wheel.dz:SetSize(dz * 2, dz * 2)
    wheel.dzMask:SetSize(dz * 2, dz * 2)

    for i = 1, math.max(n, #wheel.slots) do
        local s = wheel.slots[i]
        if i > n then
            if s then s:Hide() end
        else
            s = AcquireSlot(i)
            local a = math.rad(90 - (i - 1) * (360 / n))
            s:SetSize(size, size)
            s:ClearAllPoints()
            s:SetPoint("CENTER", wheel, "CENTER",
                math.cos(a) * radius, math.sin(a) * radius)
            s.icon:SetAtlas(entries[i].atlas)
            s.angle = a
            s:Show()
        end
    end
end

local function PaintWheel(selected)
    local ar, ag, ab = ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3]

    wheel.hub.ring:SetVertexColor(ar, ag, ab, 1)
    wheel.hub.fill:SetVertexColor(0.05, 0.05, 0.06, 0.95)
    wheel.hub.stem:SetVertexColor(ar, ag, ab, 1)
    wheel.hub.foot:SetVertexColor(ar, ag, ab, 1)

    for i = 1, #entries do
        local s = wheel.slots[i]
        if s then
            if i == selected then
                s.bg:SetVertexColor(ar * PLATE_SEL_MUL, ag * PLATE_SEL_MUL,
                    ab * PLATE_SEL_MUL, PLATE_SEL_ALPHA)
                UpdateBorder(s.border, BORDER_SEL, ar, ag, ab, 1)
            else
                s.bg:SetVertexColor(PLATE_IDLE[1], PLATE_IDLE[2], PLATE_IDLE[3], PLATE_IDLE[4])
                UpdateBorder(s.border, BORDER_IDLE, 0, 0, 0, 0.9)
            end
        end
    end

    local s = selected and wheel.slots[selected]
    if s and s.angle then
        local d = db.radius - db.iconSize * 0.5
        wheel.needle:SetVertexColor(ar, ag, ab, 0.55)
        wheel.needle:SetSize(math.max(OnePixel(wheel) * 2, 1), math.max(d, 1))
        wheel.needle:ClearAllPoints()
        wheel.needle:SetPoint("CENTER", wheel, "CENTER",
            math.cos(s.angle) * d * 0.5, math.sin(s.angle) * d * 0.5)
        wheel.needle:SetRotation(s.angle - math.pi * 0.5)
        wheel.needle:Show()
    else
        wheel.needle:Hide()
    end
end

-- The same resolve the snippet performs, for drawing only. Kept beside it
-- rather than shared, because the snippet's copy may not call out to Lua --
-- if these two ever disagree the drawing is wrong, never the ping.
local function SelectedFromCursor()
    local n = #entries
    if n == 0 then return nil end
    local ox = tonumber(clickBtn:GetAttribute("lpOX"))
    local oy = tonumber(clickBtn:GetAttribute("lpOY"))
    if not (ox and oy) then return nil end
    local cx, cy = InputUtil.GetCursorPosition(UIParent)
    local dx, dy = cx - ox, cy - oy
    if math.sqrt(dx * dx + dy * dy) < db.deadZone then return nil end
    local rel = (90 - math.deg(math.atan2(dy, dx))) % 360
    return (math.floor(rel / (360 / n) + 0.5) % n) + 1
end

local function ShowWheel()
    local ox = tonumber(clickBtn:GetAttribute("lpOX"))
    local oy = tonumber(clickBtn:GetAttribute("lpOY"))
    if not (ox and oy) then return end
    LayoutWheel()
    wheel:ClearAllPoints()
    wheel:SetPoint("CENTER", UIParent, "BOTTOMLEFT", ox, oy)
    PaintWheel(nil)
    wheel:Show()
end

local function HideWheel()
    if wheel then wheel:Hide() end
end

-------------------------------------------------------------------------------
--  Secure activation
-------------------------------------------------------------------------------

-- Wrapped_Click compiles a pre-body against the fixed signature
-- "self,button,down" (SecureHandlers.lua), so those names are already locals
-- here -- "local button, down = ..." is a compile error that only surfaces the
-- first time the snippet runs in game. Returning false as the FIRST value
-- aborts the click; we return nil, 1 to keep the button and hand the post-body
-- a message.
local SNIPPET_HOLD = [==[
    local claim = self:GetFrameRef("claimer")
    local target = self:GetFrameRef("clickbtn")
    self:SetAttribute("type", nil)
    if button ~= "LeftButton" then return nil, 1 end

    if down then
        if claim and target then
            -- Clear any deferred release left by a previous gesture: pressing
            -- the hold key again mid-click means the player wants the wheel,
            -- and an old pending flag would drop the claim on the next mouse-up
            -- while the key is still down.
            target:SetAttribute("lpReleasePending", nil)
            claim:SetBindingClick(true, self:GetAttribute("lpOpenKey"), target, "__TOKEN__")
        end
    elseif claim then
        -- THE GESTURE OUTLIVES THE KEY. If the opening click is still held, the
        -- player is mid-flick and the ping has not been sent yet -- dropping
        -- the binding here would take the mouse-up away from the button that
        -- fires it, leaving the wheel on screen and no ping behind it. So the
        -- release is deferred to whoever completes the gesture, and the click's
        -- own up-edge performs it.
        if target and target:GetAttribute("lpOpen") then
            target:SetAttribute("lpReleasePending", 1)
        else
            claim:ClearBindings()
        end
    end
    return nil, 1
]==]

local SNIPPET_CLICK = [==[
    local ui = self:GetFrameRef("ui")
    local mx, my = -1, -1
    if ui then
        local x, y = ui:GetMousePosition()
        if x then mx, my = x * ui:GetWidth(), y * ui:GetHeight() end
    end

    if button ~= "__TOKEN__" then
        self:SetAttribute("type", nil)
        return nil, 1
    end

    if down then
        -- The origin every release measures against, and where the wheel is
        -- drawn. Captured here rather than at the hold, so the wheel opens
        -- where the player clicked rather than where they happened to be
        -- standing when they reached for the key.
        self:SetAttribute("lpOX", mx)
        self:SetAttribute("lpOY", my)
        self:SetAttribute("type", nil)
        self:SetAttribute("lpOpen", 1)
        return nil, 1
    end

    self:SetAttribute("lpOpen", nil)

    local ox = tonumber(self:GetAttribute("lpOX"))
    local oy = tonumber(self:GetAttribute("lpOY"))
    local n = tonumber(self:GetAttribute("lpN")) or 0
    local dz = tonumber(self:GetAttribute("lpDeadZone")) or 12
    local idx

    if ox and oy and mx >= 0 and n > 0 then
        local dx, dy = mx - ox, my - oy
        -- sqrt is not on the sandbox whitelist; ^0.5 is the same thing.
        local dist = (dx * dx + dy * dy) ^ 0.5
        if dist >= dz then
            -- The sandbox's atan2 is WoW's global one, which answers in
            -- DEGREES. math.atan2 answers in radians, and mixing them is a
            -- silent 57x error. Entry 1 sits at +90 and each next entry is one
            -- step clockwise, i.e. decreasing angle.
            local rel = (90 - atan2(dy, dx)) % 360
            idx = (floor(rel / (360 / n) + 0.5) % n) + 1
        end
    end

    self:SetAttribute("lpIdx", idx or 0)
    if idx then
        self:SetAttribute("type", "macro")
        self:SetAttribute("macrotext", self:GetAttribute("lpCmd" .. idx))
    elseif self:GetAttribute("lpPlain") then
        self:SetAttribute("type", "macro")
        self:SetAttribute("macrotext", self:GetAttribute("lpCmdPlain"))
    else
        self:SetAttribute("type", nil)
    end

    -- The hold key was let go mid-gesture and handed us its teardown. Done
    -- AFTER the action above is written, so this click still fires: the
    -- attributes are read by SecureActionButton_OnClick once this pre-body
    -- returns, and dropping the binding does not cancel a click already in
    -- flight.
    if self:GetAttribute("lpReleasePending") then
        self:SetAttribute("lpReleasePending", nil)
        local claim = self:GetFrameRef("claimer")
        if claim then claim:ClearBindings() end
    end
    return nil, 1
]==]

SNIPPET_HOLD = SNIPPET_HOLD:gsub("__TOKEN__", CLICK_TOKEN)
SNIPPET_CLICK = SNIPPET_CLICK:gsub("__TOKEN__", CLICK_TOKEN)

local function OnClickPost(self, button, down)
    if button ~= CLICK_TOKEN then return end
    if down then ShowWheel() else HideWheel() end
end

local function MakeSecureButton(name, post)
    local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyDown", "AnyUp")
    -- Pin the acting edge to UP whatever the ActionButtonUseKeyDown CVar says.
    b:SetAttribute("useOnKeyDown", false)
    b:EnableMouse(false)
    b:SetSize(1, 1)
    b:SetAlpha(0)
    b:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -400, 100)
    b:Show()
    if post then b:SetScript("PostClick", post) end
    SecureHandlerSetFrameRef(b, "ui", UIParent)
    return b
end

local function BuildSecure()
    if holdBtn then return end
    header = CreateFrame("Frame", "LaxxPingHeader", UIParent, "SecureHandlerBaseTemplate")

    -- Protected by inheritance from SecureFrameTemplate, which is what lets the
    -- snippet take its handle in combat: GetHandleFrame refuses a handle to an
    -- unprotected frame once the player is fighting. Also the binding OWNER, so
    -- one ClearBindings hands everything back at once.
    claimer = CreateFrame("Frame", "LaxxPingClaimer", UIParent, "SecureHandlerBaseTemplate")
    claimer:Hide()

    holdBtn = MakeSecureButton("LaxxPingHoldButton", nil)
    clickBtn = MakeSecureButton("LaxxPingClickButton", OnClickPost)

    SecureHandlerSetFrameRef(holdBtn, "claimer", claimer)
    SecureHandlerSetFrameRef(holdBtn, "clickbtn", clickBtn)
    -- The click button performs the deferred release when the hold key was let
    -- go mid-gesture, so it needs the owner too.
    SecureHandlerSetFrameRef(clickBtn, "claimer", claimer)
    SecureHandlerWrapScript(holdBtn, "OnClick", header, SNIPPET_HOLD)
    SecureHandlerWrapScript(clickBtn, "OnClick", header, SNIPPET_CLICK)
end

-------------------------------------------------------------------------------
--  Pushing settings to the secure side.
--
--  Out of combat ONLY: these are ordinary insecure writes to a protected frame,
--  which is precisely what combat forbids. A change made mid-fight is held and
--  applied at PLAYER_REGEN_ENABLED -- the wheel keeps firing its previous
--  contents until the fight ends, which is the same bargain every secure addon
--  makes with its keybinds.
-------------------------------------------------------------------------------
local pushPending = false

local function Push()
    if InCombatLockdown() then pushPending = true return end
    pushPending = false
    BuildSecure()
    RebuildEntries()

    holdBtn:SetAttribute("lpOpenKey", OPEN_KEY)
    clickBtn:SetAttribute("lpN", #entries)
    clickBtn:SetAttribute("lpDeadZone", db.deadZone)
    clickBtn:SetAttribute("lpPlain", db.plainOnNoMove and 1 or nil)
    clickBtn:SetAttribute("lpCmdPlain", PingCommand(nil))
    -- Clear beyond the current count as well: a wheel that lost an entry must
    -- not leave the command that entry used to fire sitting where a later,
    -- larger wheel would read it.
    for i = 1, #ns.PING_TYPES do
        clickBtn:SetAttribute("lpCmd" .. i, entries[i] and PingCommand(entries[i].num) or nil)
    end

    if wheel and wheel:IsShown() then LayoutWheel() end
end
ns.Push = Push

-------------------------------------------------------------------------------
--  Bindings. Insecure, so out of combat only, same as the push.
-------------------------------------------------------------------------------
local bindOwner

local function ApplyBindings()
    if InCombatLockdown() then pushPending = true return end
    BuildSecure()
    if not bindOwner then
        bindOwner = CreateFrame("Frame", "LaxxPingBindOwner", UIParent)
    end
    ClearOverrideBindings(bindOwner)
    if not db.enabled then return end
    for i = 1, select("#", GetBindingKey("LAXXPING_HOLD")) do
        local key = select(i, GetBindingKey("LAXXPING_HOLD"))
        if key then
            SetOverrideBindingClick(bindOwner, true, key, "LaxxPingHoldButton")
        end
    end
end
ns.ApplyBindings = ApplyBindings

function ns.Refresh()
    Push()
    ApplyBindings()
end

-------------------------------------------------------------------------------
--  Driving the drawing while the wheel is up.
--
--  A ticker rather than an OnUpdate on the wheel: it also has to notice a hold
--  whose key-up never arrived -- alt-tab, a taxi, a loading screen -- and take
--  the wheel down, which an OnUpdate on a hidden frame cannot.
-------------------------------------------------------------------------------
local claimSince

local function Tick()
    if not clickBtn then return end
    if wheel and wheel:IsShown() then
        if not clickBtn:GetAttribute("lpOpen") then
            HideWheel()
        else
            PaintWheel(SelectedFromCursor())
        end
    end

    -- The net under every lost edge. A claim that outlives its gesture leaves
    -- the player without a left mouse button, which is the worst failure this
    -- addon can produce -- and an edge swallowed by alt-tab, a loading screen
    -- or a taxi is not something the snippet can ever be told about. Reading a
    -- binding is unrestricted, so this works in combat; the clear itself is
    -- protected, so it waits for a quiet moment.
    local held = GetBindingAction(OPEN_KEY)
    if held and held ~= "" and held:find("LaxxPingClickButton", 1, true) then
        claimSince = claimSince or GetTime()
        if (GetTime() - claimSince) > STUCK_SECONDS and not InCombatLockdown() then
            ClearOverrideBindings(claimer)
            HideWheel()
            claimSince = nil
        end
    else
        claimSince = nil
    end
end

-------------------------------------------------------------------------------
--  Lifecycle
-------------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UPDATE_BINDINGS")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("DISPLAY_SIZE_CHANGED")
f:RegisterEvent("UI_SCALE_CHANGED")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        LaxxPingDB = LaxxPingDB or {}
        MergeDefaults(LaxxPingDB, DEFAULTS)
        db = LaxxPingDB
        ns.db = db

    elseif event == "PLAYER_LOGIN" then
        RefreshPhysical()
        wheel = BuildWheel()
        ns.Refresh()
        C_Timer.NewTicker(0.03, Tick)
        if not GetBindingKey("LAXXPING_HOLD") then
            print("|cff4a8ceaLaxxPing|r: bind |cffffffffPing Wheel|r under Key Bindings, then hold it and left-click. |cffffffff/laxxping|r for options.")
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pushPending then ns.Refresh() end

    elseif event == "UPDATE_BINDINGS" then
        ApplyBindings()
        -- The options window's keybind row reads the live binding rather than
        -- a copy, so it has to be told when the binding moved -- including
        -- when it moved from Blizzard's own Key Bindings panel.
        if ns.RefreshPage then ns.RefreshPage() end

    else
        RefreshPhysical()
    end
end)

_G.BINDING_HEADER_LAXXPING = "LaxxPing"
_G.BINDING_NAME_LAXXPING_HOLD = "Ping Wheel (hold, then left-click)"

SLASH_LAXXPING1 = "/laxxping"
SLASH_LAXXPING2 = "/lping"
SlashCmdList["LAXXPING"] = function()
    if ns.ToggleOptions then ns.ToggleOptions() end
end

function _G.LaxxPing_OnCompartmentClick()
    if ns.ToggleOptions then ns.ToggleOptions() end
end
