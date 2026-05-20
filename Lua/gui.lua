-- Floating MIDI picker panel. Opens while you hold an instrument and closes when you put it away.

if not CLIENT then return end

MidiMod                    = MidiMod or {}
MidiMod.GUI                = {}

local MGUI                 = MidiMod.GUI

MGUI.panel                 = nil
MGUI.isOpen                = false
MGUI.midiFiles             = {}
MGUI.selectedFile          = nil
MGUI.tempoValue            = 1.0

local wasHoldingInstrument = false

local function refreshFileList()
    MGUI.midiFiles = {}
    if MidiMod.MidiParser then
        local ok, files = pcall(MidiMod.MidiParser.listMidiFiles)
        if ok and files then
            MGUI.midiFiles = files
        end
    end
end

local function getFileName(path)
    return string.match(path, "([^/\\]+)$") or path
end

-- ── UI state ──────────────────────────────────────────────────────────────────
local frame                  = nil
local panelFrame             = nil
local statusLabel            = nil
local fileListBox            = nil
local searchBox              = nil

local lastSearch             = ""
local savedPanelScreenOffset = nil

-- ── File list builder ─────────────────────────────────────────────────────────
local function rebuildFileList(searchText)
    if not fileListBox then return end

    pcall(function() fileListBox.ClearChildren() end)

    local lower = string.lower(searchText or "")

    for _, path in ipairs(MGUI.midiFiles) do
        local name  = getFileName(path)
        local match = (lower == "") or
            (string.find(string.lower(name), lower, 1, true) ~= nil)

        if match then
            local isSelected = (MGUI.selectedFile == path)

            local btn = GUI.Button(
                GUI.RectTransform(Vector2(1, 0), fileListBox.Content.RectTransform, GUI.Anchor.TopCenter, nil,
                    Point(0, 28)),
                " " .. name,
                GUI.Alignment.CenterLeft,
                "ListBoxElement"
            )
            btn.CanBeFocused = true

            if isSelected then
                btn.Color = Color(40, 80, 160, 210)
            end
            btn.HoverColor = Color(60, 110, 200, 220)

            pcall(function()
                local tb = btn.GetChild(0)
                if tb then
                    tb.TextColor      = isSelected and Color(100, 200, 255) or Color(210, 210, 210)
                    tb.HoverTextColor = Color(255, 255, 255)
                end
            end)

            local capturedPath = path
            btn.OnClicked = function()
                MGUI.selectedFile = capturedPath
                return true
            end
        end
    end
end

-- ── Panel lifecycle ───────────────────────────────────────────────────────────
local function destroyPanel()
    if frame then
        pcall(function() frame.Visible = false end)
        pcall(function() frame.RectTransform.Parent = nil end)
    end
    frame       = nil
    panelFrame  = nil
    statusLabel = nil
    fileListBox = nil
    searchBox   = nil
    MGUI.panel  = nil
    MGUI.isOpen = false
end

local function createPanel()
    if panelFrame and panelFrame.RectTransform then
        pcall(function()
            savedPanelScreenOffset = panelFrame.RectTransform.ScreenSpaceOffset
        end)
    end
    destroyPanel()
    refreshFileList()

    -- ── Root overlay ──────────────────────────────────────────────────────────
    frame = GUI.Frame(GUI.RectTransform(Vector2(1, 1)), nil)
    frame.CanBeFocused = false

    -- ── Main window ───────────────────────────────────────────────────────────
    local panelW, panelH = 360, 440
    panelFrame = GUI.Frame(
        GUI.RectTransform(Point(panelW, panelH), frame.RectTransform, GUI.Anchor.BottomRight),
        "GUIFrameListBox"
    )
    panelFrame.RectTransform.AbsoluteOffset = Point(20, 120)
    panelFrame.CanBeFocused = true

    if savedPanelScreenOffset then
        pcall(function()
            panelFrame.RectTransform.ScreenSpaceOffset = savedPanelScreenOffset
        end)
    end

    -- ── Title / drag handle ───────────────────────────────────────────────────
    local titleDrag = GUI.DragHandle(
        GUI.RectTransform(Vector2(1, 0.10), panelFrame.RectTransform, GUI.Anchor.TopCenter),
        panelFrame.RectTransform,
        nil
    )
    titleDrag.CanBeFocused = true
    pcall(function()
        titleDrag.DragArea = Rectangle(0, 0, GameMain.GraphicsWidth, GameMain.GraphicsHeight)
    end)

    GUI.Frame(
        GUI.RectTransform(Vector2(0.08, 0.70), titleDrag.RectTransform, GUI.Anchor.CenterLeft),
        "GUIDragIndicator"
    ).CanBeFocused = false

    local titleText = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 1), titleDrag.RectTransform),
        "♪ MIDI Player",
        nil, nil, GUI.Alignment.Center
    )
    titleText.TextColor = Color(120, 200, 255)

    -- ── Outer content list ────────────────────────────────────────────────────
    local contentList = GUI.ListBox(
        GUI.RectTransform(Vector2(0.93, 0.88), panelFrame.RectTransform, GUI.Anchor.BottomCenter)
    )
    contentList.RectTransform.AbsoluteOffset = Point(0, 6)

    -- ── No-files fallback ─────────────────────────────────────────────────────
    if #MGUI.midiFiles == 0 then
        local noFiles     = GUI.TextBlock(
            GUI.RectTransform(Vector2(1, 0.20), contentList.Content.RectTransform),
            "No MIDI files found!\nInstall 'MIDI Storage' from Workshop",
            nil, nil, GUI.Alignment.Center
        )
        noFiles.TextColor = Color(255, 100, 100)
        noFiles.Wrap      = true
        MGUI.panel        = frame
        MGUI.isOpen       = true
        return
    end

    if not MGUI.selectedFile then
        MGUI.selectedFile = MGUI.midiFiles[1]
    end

    -- ── Search label ──────────────────────────────────────────────────────────
    local searchLabel       = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.05), contentList.Content.RectTransform),
        "Search:",
        nil, nil, GUI.Alignment.CenterLeft
    )
    searchLabel.TextColor   = Color(160, 160, 160)
    searchLabel.Padding     = Vector4(4, 0, 0, 0)

    -- ── Search row: [TextBox.......] [↺] ─────────────────────────────────────
    local searchRow         = GUI.Frame(
        GUI.RectTransform(Vector2(1, 0.09), contentList.Content.RectTransform),
        nil
    )
    searchRow.CanBeFocused  = false

    searchBox               = GUI.TextBox(
        GUI.RectTransform(Vector2(0.76, 1), searchRow.RectTransform, GUI.Anchor.CenterLeft),
        lastSearch
    )
    searchBox.MaxTextLength = 80
    lastSearch              = searchBox.Text or ""

    -- Refresh button: rescans files from disk AND applies current search filter.
    local refreshBtn        = GUI.Button(
        GUI.RectTransform(Vector2(0.22, 1), searchRow.RectTransform, GUI.Anchor.CenterRight),
        "↺ Refresh", GUI.Alignment.Center, "GUIButtonSmall"
    )
    refreshBtn.OnClicked    = function()
        refreshFileList()
        local stillExists = false
        for _, p in ipairs(MGUI.midiFiles) do
            if p == MGUI.selectedFile then
                stillExists = true; break
            end
        end
        if not stillExists then MGUI.selectedFile = MGUI.midiFiles[1] end
        rebuildFileList(lastSearch)
        return true
    end

    -- ── Scrollable file list ──────────────────────────────────────────────────
    fileListBox             = GUI.ListBox(
        GUI.RectTransform(Vector2(1, 0.48), contentList.Content.RectTransform)
    )

    rebuildFileList(lastSearch)

    -- ── Divider ───────────────────────────────────────────────────────────────
    local divider             = GUI.Frame(
        GUI.RectTransform(Vector2(1, 0.01), contentList.Content.RectTransform),
        "HorizontalLine"
    )
    divider.CanBeFocused      = false

    -- ── Play / Stop ───────────────────────────────────────────────────────────
    local actionRow           = GUI.Frame(
        GUI.RectTransform(Vector2(1, 0.11), contentList.Content.RectTransform),
        nil
    )
    actionRow.CanBeFocused    = false

    local playBtn             = GUI.Button(
        GUI.RectTransform(Vector2(0.48, 1), actionRow.RectTransform, GUI.Anchor.CenterLeft),
        "▶ Play", GUI.Alignment.Center, "GUIButtonSmall"
    )
    playBtn.OnClicked         = function()
        if MGUI.selectedFile and MidiMod.Network then
            MidiMod.Network.requestPlay(MGUI.selectedFile, MGUI.tempoValue)
        end
        return true
    end

    local stopBtn             = GUI.Button(
        GUI.RectTransform(Vector2(0.48, 1), actionRow.RectTransform, GUI.Anchor.CenterRight),
        "■ Stop", GUI.Alignment.Center, "GUIButtonSmall"
    )
    stopBtn.OnClicked         = function()
        if MidiMod.Network then
            MidiMod.Network.requestStop()
        end
        return true
    end

    -- ── Now playing ───────────────────────────────────────────────────────────
    local nowPlayingLabel     = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.08), contentList.Content.RectTransform),
        "",
        nil, nil, GUI.Alignment.Center
    )
    nowPlayingLabel.TextColor = Color(100, 255, 140)
    nowPlayingLabel.Wrap      = true

    -- ── Status ────────────────────────────────────────────────────────────────
    statusLabel               = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.08), contentList.Content.RectTransform),
        "Ready  |  F5 to toggle",
        nil, nil, GUI.Alignment.Center
    )
    statusLabel.TextColor     = Color(140, 140, 140)

    -- ── Hints ─────────────────────────────────────────────────────────────────
    local volHint             = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.10), contentList.Content.RectTransform),
        "* Volume: Esc → Settings → Mod Gameplay Settings *",
        nil, nil, GUI.Alignment.Center
    )
    volHint.TextColor         = Color(100, 100, 100)
    volHint.Wrap              = true

    MGUI.nowPlayingLabel      = nowPlayingLabel
    MGUI.panel                = frame
    MGUI.isOpen               = true
end

-- ── Public toggle ─────────────────────────────────────────────────────────────
function MGUI.togglePanel(show)
    if show == nil then show = not MGUI.isOpen end
    if show then createPanel() else destroyPanel() end
end

-- ── GUI draw hook ─────────────────────────────────────────────────────────────
Hook.Patch("Barotrauma.GameScreen", "AddToGUIUpdateList", function()
    if frame and MGUI.isOpen then
        frame.AddToGUIUpdateList()
    end
end)

-- ── Think hook ────────────────────────────────────────────────────────────────
Hook.Add("think", "MidiMod.GUI.Think", function()
    local ch         = Character.Controlled
    local holdingNow = ch and MidiMod.IsHoldingInstrument(ch) or false

    if holdingNow and not wasHoldingInstrument then MGUI.togglePanel(true) end
    if not holdingNow and wasHoldingInstrument then MGUI.togglePanel(false) end
    wasHoldingInstrument = holdingNow

    local f5Pressed = false
    pcall(function() f5Pressed = PlayerInput.KeyHit(Keys.F5) end)
    if f5Pressed and holdingNow then MGUI.togglePanel() end

    if MGUI.isOpen and searchBox then
        local currentText = ""
        pcall(function() currentText = searchBox.Text or "" end)
        if currentText ~= lastSearch then
            lastSearch = currentText
            rebuildFileList(lastSearch)
        end
    end

    -- ── Update status label only ───────────────────────────────────────────────
    if MGUI.isOpen and statusLabel and MidiMod.Player then
        pcall(function()
            if MidiMod.Player.playing then
                statusLabel.Text      = "♪ Playing...  |  F5 to hide"
                statusLabel.TextColor = Color(100, 255, 140)
                if MGUI.nowPlayingLabel and MidiMod.Player.currentFile then
                    MGUI.nowPlayingLabel.Text = getFileName(MidiMod.Player.currentFile)
                end
            else
                statusLabel.Text      = "Ready  |  F5 to toggle"
                statusLabel.TextColor = Color(140, 140, 140)
                if MGUI.nowPlayingLabel then
                    MGUI.nowPlayingLabel.Text = ""
                end
            end
        end)
    end
end)

MidiMod.Log("[GUI] Initialized. Panel auto-shows on instrument pickup. Toggle: F5")
