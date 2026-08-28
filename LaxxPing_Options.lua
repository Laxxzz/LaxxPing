-------------------------------------------------------------------------------
--  LaxxPing_Options.lua -- the options window.
--
--  Built as a FIXED DESIGN CANVAS: the window is sized in physical pixels and
--  its scale is set so one design unit maps to one physical pixel. That is why
--  every number in here is a round one -- they are pixel counts, not values
--  that happened to look right at one resolution. The scale is set exactly
--  once, by the window itself; nothing inside it sets a scale, because scale
--  compounds and a child that re-applies the canvas factor renders at the
--  square of it.
--
--  Two rules do the heavy lifting and are worth stating before the code:
--
--    * EVERY BUILDER RETURNS THE VERTICAL SPACE IT CONSUMED, and the page is a
--      cursor that only ever subtracts. No call site knows a row's height, so
--      no call site can guess one wrong, and a row that grows moves everything
--      below it without a single edit. Whitespace goes through the same
--      channel -- a Spacer that returns its height -- so the cursor stays the
--      one source of truth.
--    * EVERY ROW ANCHORS TO BOTH EDGES, and every FontString is bounded on
--      both sides with SetWordWrap(false). A text region free to grow is what
--      turns a long localized string into an overlap.
--
--  Colour is white or black at an alpha over a near-black ground with a slight
--  blue cast, plus exactly ONE accent -- the same blue the wheel's emblem uses.
--  Nothing else has a hue, which is what makes the accent mean "on" rather
--  than "decorated", and what lets the whole panel retint from one table.
-------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

-------------------------------------------------------------------------------
--  Scales. Eight spacing numbers and six type steps, all named.
-------------------------------------------------------------------------------
local DESIGN_W = 400

local PAD = 20          -- page edge -> row edge
local ROW_H = 38        -- an option row
local COMPACT_H = 32    -- a ping row: icon plus a name, nothing else
local TITLE_H = 42
local SECTION_H = 30
local LABEL_GAP = 12    -- label right bound -> control left
local CTRL_H = 20       -- toggle track height
local STEP_BTN = 22

local FS_CAPTION, FS_SMALL, FS_SECTION = 10, 11, 12
local FS_CONTROL, FS_BODY, FS_TITLE = 13, 14, 16

local PANEL_BG = { 0.05, 0.07, 0.09 }
local CTRL_BG = { 0.061, 0.095, 0.120 }
local BORDER = { 1, 1, 1, 0.05 }
local TEXT = { 1, 1, 1, 1.00 }
local TEXT_DIM = { 1, 1, 1, 0.53 }
local TEXT_SEC = { 1, 1, 1, 0.41 }
local DIVIDER = { 1, 1, 1, 0.06 }
local ROW_ODD = { 0, 0, 0, 0.10 }
local ROW_EVEN = { 0, 0, 0, 0.20 }
local TRACK_OFF = { 0.27, 0.27, 0.27, 0.65 }

local FONT_FACE = GameFontNormal:GetFont()

local window, content

-------------------------------------------------------------------------------
--  Small shared helpers
-------------------------------------------------------------------------------

-- A FontString bounded on BOTH sides. The two anchors and the wrap-off are the
-- whole point: a string anchored on one side only is free to grow into its
-- neighbour the first time a locale hands it a longer word.
local function FS(parent, size, colour, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT_FACE, size, "")
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetTextColor(colour[1], colour[2], colour[3], colour[4] or 1)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Fill(parent, colour, layer)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(colour[1], colour[2], colour[3], colour[4] or 1)
    t:SetAllPoints(parent)
    return t
end

-- The row shell every option row shares: full width between the page's pads,
-- a stripe so a long list stays readable, and a label bounded short of
-- whatever control the caller puts on the right.
local function Row(parent, y, height, index)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(height)
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    r:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, y)
    local stripe = (index and index % 2 == 0) and ROW_EVEN or ROW_ODD
    Fill(r, stripe)
    return r
end

local function Tooltip(frame, title, body)
    if not body then return end
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        GameTooltip:AddLine(body, 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-------------------------------------------------------------------------------
--  Widgets. Each owns its own geometry and returns the height it used.
-------------------------------------------------------------------------------
local W = {}

function W.Spacer(_, _, h)
    return nil, h
end

function W.Section(parent, y, text)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(SECTION_H)
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    r:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, y)

    local label = FS(r, FS_SECTION, TEXT_SEC)
    label:SetPoint("LEFT", r, "LEFT", 0, -2)
    label:SetText(text:upper())

    -- The rule finishes itself: it is anchored to the label on one side and to
    -- the row on the other, so no call site has to complete the widget.
    local rule = r:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(DIVIDER[1], DIVIDER[2], DIVIDER[3], DIVIDER[4])
    rule:SetHeight(ns.OnePixel(r))
    rule:SetPoint("LEFT", label, "RIGHT", LABEL_GAP, 0)
    rule:SetPoint("RIGHT", r, "RIGHT", 0, 0)

    return r, SECTION_H
end

-- A toggle. Its "on" state is the only place the accent appears in a row,
-- which is what makes a page of settings scannable without reading it.
function W.Toggle(parent, y, index, text, tip, get, set)
    local r = Row(parent, y, ROW_H, index)

    local track = CreateFrame("Frame", nil, r)
    track:SetSize(36, CTRL_H)
    track:SetPoint("RIGHT", r, "RIGHT", -PAD * 0.5, 0)
    local trackFill = Fill(track, TRACK_OFF, "ARTWORK")

    local knob = track:CreateTexture(nil, "OVERLAY")
    knob:SetColorTexture(1, 1, 1, 1)
    knob:SetSize(CTRL_H - 6, CTRL_H - 6)

    local label = FS(r, FS_BODY, TEXT)
    label:SetPoint("LEFT", r, "LEFT", PAD * 0.5, 0)
    label:SetPoint("RIGHT", track, "LEFT", -LABEL_GAP, 0)
    label:SetText(text)

    local function Paint()
        local on = get() and true or false
        if on then
            local a = ns.ACCENT
            trackFill:SetColorTexture(a[1], a[2], a[3], 0.75)
            knob:SetVertexColor(1, 1, 1, 1)
            knob:ClearAllPoints()
            knob:SetPoint("RIGHT", track, "RIGHT", -3, 0)
        else
            trackFill:SetColorTexture(TRACK_OFF[1], TRACK_OFF[2], TRACK_OFF[3], TRACK_OFF[4])
            knob:SetVertexColor(1, 1, 1, 0.5)
            knob:ClearAllPoints()
            knob:SetPoint("LEFT", track, "LEFT", 3, 0)
        end
    end

    -- The widget owns the control, so the widget owns its refresh. A caller
    -- that had to remember to repaint would eventually forget.
    r.Paint = Paint
    r:EnableMouse(true)
    r:SetScript("OnMouseUp", function()
        set(not get())
        Paint()
        if ns.RefreshPage then ns.RefreshPage() end
    end)
    Tooltip(r, text, tip)
    Paint()

    return r, ROW_H
end

-- The keybind row. Writes the REAL binding with SetBinding/SaveBindings rather
-- than storing a key of its own, so the key shows up in Blizzard's own Key
-- Bindings panel, survives a binding-set switch, and cannot drift out of step
-- with what the game thinks is bound.
--
-- Capture goes through Blizzard's own four helpers (BindingUtil.lua) rather
-- than a hand-rolled modifier check: GetConvertedKeyOrButton normalises the
-- raw key, IsKeyPressIgnoredForBinding is what lets a bare modifier pass
-- through so it can be held as part of a chord, and
-- CreateKeyChordStringUsingMetaKeyState assembles the chord in the exact order
-- the binding system expects. Building "ALT-CTRL-SHIFT-" by hand is the
-- classic way to produce a string the game will not match.
function W.Keybind(parent, y, index, text, tip)
    local r = Row(parent, y, ROW_H, index)
    local listening = false

    local btn = CreateFrame("Button", nil, r)
    btn:SetSize(130, 24)
    btn:SetPoint("RIGHT", r, "RIGHT", -PAD * 0.5, 0)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local bg = Fill(btn, CTRL_BG, "ARTWORK")
    local border = ns.CreateBorder(btn, 1)
    local keyText = FS(btn, FS_CONTROL, TEXT, "CENTER")
    keyText:SetPoint("LEFT", btn, "LEFT", 6, 0)
    keyText:SetPoint("RIGHT", btn, "RIGHT", -6, 0)

    local label = FS(r, FS_BODY, TEXT)
    label:SetPoint("LEFT", r, "LEFT", PAD * 0.5, 0)
    label:SetPoint("RIGHT", btn, "LEFT", -LABEL_GAP, 0)
    label:SetText(text)

    local function Paint()
        if listening then
            local a = ns.ACCENT
            keyText:SetText("Press a key...")
            keyText:SetTextColor(a[1], a[2], a[3], 1)
            ns.UpdateBorder(border, 1, a[1], a[2], a[3], 0.9)
            return
        end
        local key = GetBindingKey("LAXXPING_HOLD")
        if key then
            keyText:SetText(GetBindingText(key) or key)
            keyText:SetTextColor(TEXT[1], TEXT[2], TEXT[3], 1)
        else
            keyText:SetText("Not bound")
            keyText:SetTextColor(TEXT_SEC[1], TEXT_SEC[2], TEXT_SEC[3], TEXT_SEC[4])
        end
        ns.UpdateBorder(border, 1, BORDER[1], BORDER[2], BORDER[3], 0.30)
    end

    local function StopListening()
        listening = false
        btn:EnableKeyboard(false)
        btn:SetPropagateKeyboardInput(true)
        Paint()
    end

    -- SaveBindings raises "can't be done in combat" and SetBinding would
    -- already be half-applied by then, so nothing is touched until combat ends.
    local function Commit(chord)
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage("LaxxPing: keybinds can't be changed in combat.", 1, 0.3, 0.3)
            return
        end

        -- Clear every key currently held, which is what rebinding means -- but
        -- collect them FIRST: SetBinding mutates what GetBindingKey returns,
        -- and clearing while iterating it drops the second key.
        local held = { GetBindingKey("LAXXPING_HOLD") }
        for _, k in ipairs(held) do SetBinding(k, nil) end

        if chord then
            -- SetBinding takes a chord away from whatever held it without
            -- asking, so say whose it was rather than letting the user find
            -- out later that something else stopped working.
            local stolenFrom = GetBindingAction(chord)
            if stolenFrom and stolenFrom ~= "" and stolenFrom ~= "LAXXPING_HOLD" then
                UIErrorsFrame:AddMessage("LaxxPing: took " .. (GetBindingText(chord) or chord)
                    .. " from " .. (GetBindingName(stolenFrom) or stolenFrom) .. ".", 1, 0.82, 0)
            end
            SetBinding(chord, "LAXXPING_HOLD")
        end

        SaveBindings(GetCurrentBindingSet())
        -- UPDATE_BINDINGS follows and re-applies the override routing, so
        -- nothing else has to be poked here.
    end

    btn:SetScript("OnClick", function(self, button)
        if listening then return end
        if button == "RightButton" then
            Commit(nil)
            Paint()
            return
        end
        if InCombatLockdown() then
            UIErrorsFrame:AddMessage("LaxxPing: keybinds can't be changed in combat.", 1, 0.3, 0.3)
            return
        end
        listening = true
        self:EnableKeyboard(true)
        Paint()
    end)

    btn:SetScript("OnKeyDown", function(self, key)
        if not listening then self:SetPropagateKeyboardInput(true) return end
        key = GetConvertedKeyOrButton(key)
        -- Bare modifiers and anything the binding system ignores pass straight
        -- through, so the user can hold them as part of the chord.
        if IsKeyPressIgnoredForBinding(key) then
            self:SetPropagateKeyboardInput(true)
            return
        end
        self:SetPropagateKeyboardInput(false)
        if key ~= "ESCAPE" then
            Commit(CreateKeyChordStringUsingMetaKeyState(key))
        end
        StopListening()
    end)

    -- Mouse buttons are legal binding keys too, but not the left one: the
    -- wheel claims BUTTON1 for itself the moment the hold key goes down, so a
    -- hold key bound to it could never be released.
    btn:SetScript("OnMouseDown", function(self, button)
        if not listening then return end
        if button == "LeftButton" or button == "RightButton" then
            StopListening()
            return
        end
        Commit(CreateKeyChordStringUsingMetaKeyState(GetConvertedKeyOrButton(button)))
        StopListening()
    end)

    btn:SetScript("OnEnter", function()
        if listening then return end
        ns.UpdateBorder(border, 1, BORDER[1], BORDER[2], BORDER[3], 0.45)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text, 1, 1, 1)
        GameTooltip:AddLine("Left-click, then press the key you want.\n"
            .. "Escape cancels. Right-click here to unbind.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        if listening then return end
        ns.UpdateBorder(border, 1, BORDER[1], BORDER[2], BORDER[3], 0.30)
    end)

    Tooltip(r, text, tip)
    r.Paint = Paint
    Paint()

    return r, ROW_H
end

-- A stepper rather than a slider, deliberately: the values here are small
-- integers where precision beats sweep, and a hand-rolled slider is a hundred
-- more lines of drag maths that can be subtly wrong at a non-default UI scale.
function W.Stepper(parent, y, index, text, tip, get, set, minV, maxV, step, suffix)
    local r = Row(parent, y, ROW_H, index)

    local function Button(glyph, delta)
        local b = CreateFrame("Button", nil, r)
        b:SetSize(STEP_BTN, STEP_BTN)
        local bg = Fill(b, CTRL_BG, "ARTWORK")
        local border = ns.CreateBorder(b, 1)
        ns.UpdateBorder(border, 1, BORDER[1], BORDER[2], BORDER[3], 0.30)
        local t = FS(b, FS_CONTROL, TEXT_DIM, "CENTER")
        t:SetPoint("LEFT")
        t:SetPoint("RIGHT")
        t:SetText(glyph)
        b:SetScript("OnEnter", function()
            bg:SetColorTexture(CTRL_BG[1], CTRL_BG[2], CTRL_BG[3], 1)
            ns.UpdateBorder(border, 1, BORDER[1], BORDER[2], BORDER[3], 0.45)
            t:SetTextColor(TEXT[1], TEXT[2], TEXT[3], 0.70)
        end)
        b:SetScript("OnLeave", function()
            bg:SetColorTexture(CTRL_BG[1], CTRL_BG[2], CTRL_BG[3], 1)
            ns.UpdateBorder(border, 1, BORDER[1], BORDER[2], BORDER[3], 0.30)
            t:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], TEXT_DIM[4])
        end)
        b.delta = delta
        return b
    end

    local plus = Button("+", step)
    plus:SetPoint("RIGHT", r, "RIGHT", -PAD * 0.5, 0)

    local value = FS(r, FS_CONTROL, TEXT, "CENTER")
    value:SetWidth(52)
    value:SetPoint("RIGHT", plus, "LEFT", -6, 0)

    local minus = Button("-", -step)
    minus:SetPoint("RIGHT", value, "LEFT", -6, 0)

    local label = FS(r, FS_BODY, TEXT)
    label:SetPoint("LEFT", r, "LEFT", PAD * 0.5, 0)
    label:SetPoint("RIGHT", minus, "LEFT", -LABEL_GAP, 0)
    label:SetText(text)

    local function Paint()
        value:SetText(tostring(get()) .. (suffix or ""))
        local v = get()
        minus:SetEnabled(v > minV)
        plus:SetEnabled(v < maxV)
        minus:SetAlpha(v > minV and 1 or 0.35)
        plus:SetAlpha(v < maxV and 1 or 0.35)
    end

    local function Bump(self)
        local v = get() + self.delta
        if v < minV then v = minV elseif v > maxV then v = maxV end
        set(v)
        Paint()
    end
    minus:SetScript("OnClick", Bump)
    plus:SetScript("OnClick", Bump)

    Tooltip(r, text, tip)
    r.Paint = Paint
    Paint()

    return r, ROW_H
end

-- One ping type: its own icon at the size the wheel draws it, its localized
-- name, and a toggle. The icon is here because the name alone does not tell
-- you which marker your group will see.
function W.PingRow(parent, y, index, def)
    local r = Row(parent, y, COMPACT_H, index)

    local track = CreateFrame("Frame", nil, r)
    track:SetSize(36, CTRL_H)
    track:SetPoint("RIGHT", r, "RIGHT", -PAD * 0.5, 0)
    local trackFill = Fill(track, TRACK_OFF, "ARTWORK")

    local knob = track:CreateTexture(nil, "OVERLAY")
    knob:SetColorTexture(1, 1, 1, 1)
    knob:SetSize(CTRL_H - 6, CTRL_H - 6)

    local icon = r:CreateTexture(nil, "ARTWORK")
    icon:SetSize(COMPACT_H - 10, COMPACT_H - 10)
    icon:SetPoint("LEFT", r, "LEFT", PAD * 0.5, 0)
    icon:SetAtlas(def.atlas)

    local label = FS(r, FS_BODY, TEXT)
    label:SetPoint("LEFT", icon, "RIGHT", LABEL_GAP, 0)
    label:SetPoint("RIGHT", track, "LEFT", -LABEL_GAP, 0)
    label:SetText(def.name)

    local db = ns.DB()

    local function Paint()
        local on = db.enabledTypes[def.key] and true or false
        if on then
            local a = ns.ACCENT
            trackFill:SetColorTexture(a[1], a[2], a[3], 0.75)
            knob:SetVertexColor(1, 1, 1, 1)
            knob:ClearAllPoints()
            knob:SetPoint("RIGHT", track, "RIGHT", -3, 0)
            icon:SetAlpha(1)
            label:SetTextColor(TEXT[1], TEXT[2], TEXT[3], 1)
        else
            trackFill:SetColorTexture(TRACK_OFF[1], TRACK_OFF[2], TRACK_OFF[3], TRACK_OFF[4])
            knob:SetVertexColor(1, 1, 1, 0.5)
            knob:ClearAllPoints()
            knob:SetPoint("LEFT", track, "LEFT", 3, 0)
            icon:SetAlpha(0.35)
            label:SetTextColor(TEXT_SEC[1], TEXT_SEC[2], TEXT_SEC[3], TEXT_SEC[4])
        end
    end

    r:EnableMouse(true)
    r:SetScript("OnMouseUp", function()
        local on = not db.enabledTypes[def.key]
        -- An empty wheel would leave the player holding a key that can only
        -- ever cancel, so the last entry standing refuses to be turned off.
        if not on then
            local count = 0
            for _, t in ipairs(ns.PING_TYPES) do
                if db.enabledTypes[t.key] then count = count + 1 end
            end
            if count <= 1 then
                UIErrorsFrame:AddMessage("LaxxPing: the wheel needs at least one ping.", 1, 0.3, 0.3)
                return
            end
        end
        db.enabledTypes[def.key] = on
        Paint()
        ns.Refresh()
    end)
    Tooltip(r, def.name, "Show this ping on the wheel.")
    r.Paint = Paint
    Paint()

    return r, COMPACT_H
end

-------------------------------------------------------------------------------
--  The page. A cursor, and no other arithmetic anywhere.
-------------------------------------------------------------------------------
local rows = {}

local function BuildPage(parent)
    local db = ns.DB()
    local y, h = -PAD
    local i = 0
    local function next_index() i = i + 1 return i end

    -- Declared, not left to become a global: a bare "_, h = ..." at file or
    -- function scope writes a global named _ that every other addon shares.
    local r, _
    r, h = W.Section(parent, y, "Keybind");                      y = y - h
    rows[#rows + 1] = r

    r, h = W.Keybind(parent, y, next_index(), "Ping wheel key",
        "Hold this, then left-click where you want to ping.");    y = y - h
    rows[#rows + 1] = r

    _, h = W.Spacer(parent, y, 10);                               y = y - h

    i = 0
    r, h = W.Section(parent, y, "Behaviour");                    y = y - h
    rows[#rows + 1] = r

    r, h = W.Toggle(parent, y, next_index(), "Enabled",
        "Turn the ping wheel off without unbinding its key.",
        function() return db.enabled end,
        function(v) db.enabled = v; ns.Refresh() end);           y = y - h
    rows[#rows + 1] = r

    r, h = W.Toggle(parent, y, next_index(), "Environment only",
        "Pings pass through units and interface frames and land on the world, "
        .. "whatever your Ping Target setting says. Turn this off for ordinary "
        .. "pings that can call out a unit.",
        function() return db.environmentOnly end,
        function(v) db.environmentOnly = v; ns.Refresh() end);    y = y - h
    rows[#rows + 1] = r

    r, h = W.Toggle(parent, y, next_index(), "Click without moving pings",
        "Release the mouse without flicking and a plain ping lands exactly "
        .. "where you clicked. This is the only gesture with no drift at all. "
        .. "Turn it off to make a no-move release cancel instead.",
        function() return db.plainOnNoMove end,
        function(v) db.plainOnNoMove = v; ns.Refresh() end);      y = y - h
    rows[#rows + 1] = r

    r, h = W.Stepper(parent, y, next_index(), "Dead zone",
        "How far you must flick before an entry is chosen. The ping lands "
        .. "where the cursor is when you release, so this is also how far the "
        .. "ping can miss by. Smaller is more accurate; too small and a "
        .. "twitch picks an entry for you.",
        function() return db.deadZone end,
        function(v) db.deadZone = v; ns.Refresh() end,
        ns.MIN_DEAD_ZONE, ns.MAX_DEAD_ZONE, 2, " px");            y = y - h
    rows[#rows + 1] = r

    r, h = W.Stepper(parent, y, next_index(), "Wheel radius",
        "How far the icons sit from the centre. Appearance only -- an entry is "
        .. "chosen by direction, so a larger wheel does not ask for a longer flick.",
        function() return db.radius end,
        function(v) db.radius = v; ns.Refresh() end,
        ns.MIN_RADIUS, ns.MAX_RADIUS, 10, " px");                 y = y - h
    rows[#rows + 1] = r

    _, h = W.Spacer(parent, y, 10);                               y = y - h

    r, h = W.Section(parent, y, "Pings on the wheel");            y = y - h
    rows[#rows + 1] = r

    i = 0
    for _, def in ipairs(ns.PING_TYPES) do
        r, h = W.PingRow(parent, y, next_index(), def);           y = y - h
        rows[#rows + 1] = r
    end

    _, h = W.Spacer(parent, y, PAD);                              y = y - h

    -- The page's height IS the cursor. Never precomputed somewhere else, so
    -- the two cannot drift the first time either changes.
    return -y
end

-------------------------------------------------------------------------------
--  The window
-------------------------------------------------------------------------------

-- One design unit -> one physical pixel. GetScreenWidth is UIParent's width in
-- its own scaled units and GetPhysicalScreenSize is the real display width, so
-- their ratio is exactly the factor that cancels the user's UI scale. Set on
-- the outermost frame and nowhere else.
local function CanvasScale()
    local physW = GetPhysicalScreenSize()
    if not physW or physW <= 0 then return 1 end
    local w = GetScreenWidth()
    if not w or w <= 0 then return 1 end
    return w / physW
end

local function BuildWindow()
    local f = CreateFrame("Frame", "LaxxPingOptions", UIParent)
    f:SetFrameStrata("HIGH")
    f:SetWidth(DESIGN_W)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:Hide()

    Fill(f, PANEL_BG)
    f.border = ns.CreateBorder(f, 1)

    local bar = CreateFrame("Frame", nil, f)
    bar:SetHeight(TITLE_H)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local barRule = bar:CreateTexture(nil, "ARTWORK")
    barRule:SetColorTexture(DIVIDER[1], DIVIDER[2], DIVIDER[3], DIVIDER[4])
    barRule:SetPoint("BOTTOMLEFT")
    barRule:SetPoint("BOTTOMRIGHT")

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(TITLE_H - 16, TITLE_H - 16)
    close:SetPoint("RIGHT", bar, "RIGHT", -PAD * 0.5, 0)
    local x = FS(close, FS_CONTROL, TEXT_DIM, "CENTER")
    x:SetPoint("LEFT")
    x:SetPoint("RIGHT")
    x:SetText("X")
    close:SetScript("OnEnter", function() x:SetTextColor(1, 1, 1, 1) end)
    close:SetScript("OnLeave", function() x:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], TEXT_DIM[4]) end)
    close:SetScript("OnClick", function() f:Hide() end)

    local title = FS(bar, FS_TITLE, TEXT)
    title:SetPoint("LEFT", bar, "LEFT", PAD, 0)
    title:SetPoint("RIGHT", close, "LEFT", -LABEL_GAP, 0)
    title:SetText("LaxxPing")

    f.bar = bar
    f.barRule = barRule

    content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", bar, "BOTTOMLEFT")
    content:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT")

    local hint = FS(f, FS_CAPTION, TEXT_SEC)
    hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 8)
    hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 8)
    f.hint = hint

    -- Re-derive the canvas scale on every open: resolution, monitor and UI
    -- scale all change while the window is closed, so PLAYER_LOGIN is not the
    -- last word on any of them.
    f:SetScript("OnShow", function(self)
        ns.RefreshPhysical()
        self:SetScale(CanvasScale())
        ns.UpdateBorder(self.border, 1, BORDER[1], BORDER[2], BORDER[3], BORDER[4])
        self.barRule:SetHeight(ns.OnePixel(self))
        if ns.RefreshPage then ns.RefreshPage() end
    end)

    return f
end

-- Repaint every row that owns a control. Cheap, and it means a setting that
-- gates another one is never left showing a stale state.
local function RefreshHint()
    if not window then return end
    local key = GetBindingKey("LAXXPING_HOLD")
    window.hint:SetText(key
        and ("Hold " .. (GetBindingText(key) or key) .. ", left-click, flick, release.")
        or "|cffff5555No key bound|r -- set one above.")
end

function ns.RefreshPage()
    for _, r in ipairs(rows) do
        if r and r.Paint then r.Paint() end
    end
    RefreshHint()
end

function ns.ToggleOptions()
    if not window then
        window = BuildWindow()
        local h = BuildPage(content)
        content:SetHeight(h)
        -- The window's height comes from the same cursor the layout produced,
        -- plus the title bar and the hint line's own strip.
        window:SetHeight(TITLE_H + h + 14)
        -- One proxy in UISpecialFrames, so Escape closes this the way it closes
        -- every other window rather than needing a key handler of its own.
        tinsert(UISpecialFrames, "LaxxPingOptions")
    end
    window:SetShown(not window:IsShown())
end
