-- Floating MIDI picker panel. Opens while you hold an instrument and closes when you put it away.

if not CLIENT then return end

MidiMod = MidiMod or {}
MidiMod.GUI = {}

local MGUI = MidiMod.GUI

MGUI.panel = nil
MGUI.isOpen = false
MGUI.midiFiles = {}
MGUI.selectedFile = nil
MGUI.fileIndex = 1
MGUI.tempoValue = 1.0

-- Did we have an instrument equipped last frame? Used for auto open/close.
local wasHoldingInstrument = false

-- Refresh the list of .mid files from disk.
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

-- UI widgets
local frame = nil      -- Full-screen invisible layer so the panel can sit on top.
local panelFrame = nil -- The visible box you drag around.
local titleText = nil
local fileLabel = nil
local statusLabel = nil

-- Keeps the panel where you left it when Prev/Next rebuilds the UI.
local savedPanelScreenOffset = nil

local function destroyPanel()
    if frame then
        pcall(function() frame.Visible = false end)
        pcall(function()
            frame.RectTransform.Parent = nil
        end)
    end
    frame = nil
    panelFrame = nil
    titleText = nil
    fileLabel = nil
    statusLabel = nil
    MGUI.panel = nil
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

    frame = GUI.Frame(GUI.RectTransform(Vector2(1, 1)), nil)
    frame.CanBeFocused = false

    -- Small window bottom-right with a fixed pixel size.
    local panelW = 350
    local panelH = 300
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

    -- Drag handle for the title strip
    local titleDrag = GUI.DragHandle(
        GUI.RectTransform(Vector2(1, 0.14), panelFrame.RectTransform, GUI.Anchor.TopCenter),
        panelFrame.RectTransform,
        nil
    )
    titleDrag.CanBeFocused = true
    pcall(function()
        titleDrag.DragArea = Rectangle(0, 0, GameMain.GraphicsWidth, GameMain.GraphicsHeight)
    end)

    local dragIndicator = GUI.Frame(
        GUI.RectTransform(Vector2(0.10, 0.75), titleDrag.RectTransform, GUI.Anchor.CenterLeft),
        "GUIDragIndicator"
    )
    dragIndicator.CanBeFocused = false

    titleText = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 1), titleDrag.RectTransform),
        "♪ MIDI Player",
        nil, nil, GUI.Alignment.Center
    )
    titleText.TextColor = Color(120, 200, 255)

    local contentList = GUI.ListBox(
        GUI.RectTransform(Vector2(0.92, 0.82), panelFrame.RectTransform, GUI.Anchor.BottomCenter)
    )
    contentList.RectTransform.AbsoluteOffset = Point(0, 4)

    if #MGUI.midiFiles == 0 then
        fileLabel = GUI.TextBlock(
            GUI.RectTransform(Vector2(1, 0.25), contentList.Content.RectTransform),
            "No MIDI files found!\nInstall 'MIDI Storage' from Workshop",
            nil, nil, GUI.Alignment.Center
        )
        fileLabel.TextColor = Color(255, 100, 100)
        fileLabel.Wrap = true

        MGUI.panel = frame
        MGUI.isOpen = true
        return
    end

    if MGUI.fileIndex < 1 then MGUI.fileIndex = 1 end
    if MGUI.fileIndex > #MGUI.midiFiles then MGUI.fileIndex = #MGUI.midiFiles end

    MGUI.selectedFile = MGUI.midiFiles[MGUI.fileIndex]
    local fileName = getFileName(MGUI.selectedFile)

    fileLabel = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.25), contentList.Content.RectTransform),
        string.format("[%d/%d] %s", MGUI.fileIndex, #MGUI.midiFiles, fileName),
        nil, nil, GUI.Alignment.Center
    )
    fileLabel.Wrap = true
    fileLabel.TextColor = Color(220, 220, 220)

    local navRow = GUI.Frame(
        GUI.RectTransform(Vector2(1, 0.18), contentList.Content.RectTransform),
        nil
    )
    navRow.CanBeFocused = false

    local prevBtn = GUI.Button(
        GUI.RectTransform(Vector2(0.48, 1), navRow.RectTransform, GUI.Anchor.CenterLeft),
        "◄ Prev", GUI.Alignment.Center, "GUIButtonSmall"
    )
    prevBtn.OnClicked = function()
        MGUI.fileIndex = MGUI.fileIndex - 1
        if MGUI.fileIndex < 1 then MGUI.fileIndex = #MGUI.midiFiles end
        createPanel()
        return true
    end

    local nextBtn = GUI.Button(
        GUI.RectTransform(Vector2(0.48, 1), navRow.RectTransform, GUI.Anchor.CenterRight),
        "Next ►", GUI.Alignment.Center, "GUIButtonSmall"
    )
    nextBtn.OnClicked = function()
        MGUI.fileIndex = MGUI.fileIndex + 1
        if MGUI.fileIndex > #MGUI.midiFiles then MGUI.fileIndex = 1 end
        createPanel()
        return true
    end

    local actionRow = GUI.Frame(
        GUI.RectTransform(Vector2(1, 0.18), contentList.Content.RectTransform),
        nil
    )
    actionRow.CanBeFocused = false

    local playBtn = GUI.Button(
        GUI.RectTransform(Vector2(0.48, 1), actionRow.RectTransform, GUI.Anchor.CenterLeft),
        "▶ Play", GUI.Alignment.Center, "GUIButtonSmall"
    )
    playBtn.OnClicked = function()
        if MidiMod.Network then
            MidiMod.Network.requestPlay(MGUI.selectedFile, MGUI.tempoValue)
        end
        return true
    end

    local stopBtn = GUI.Button(
        GUI.RectTransform(Vector2(0.48, 1), actionRow.RectTransform, GUI.Anchor.CenterRight),
        "■ Stop", GUI.Alignment.Center, "GUIButtonSmall"
    )
    stopBtn.OnClicked = function()
        if MidiMod.Network then
            MidiMod.Network.requestStop()
        end
        return true
    end

    local volHint = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.18), contentList.Content.RectTransform),
        "* You can change midi volume in\nesc - settings - mod gameplay settings *",
        nil, nil, GUI.Alignment.Center
    )
    volHint.TextColor = Color(110, 110, 110)

    statusLabel = GUI.TextBlock(
        GUI.RectTransform(Vector2(1, 0.12), contentList.Content.RectTransform),
        "Ready  |  F5 to toggle",
        nil, nil, GUI.Alignment.Center
    )
    statusLabel.TextColor = Color(140, 140, 140)

    MGUI.panel = frame
    MGUI.isOpen = true
end

function MGUI.togglePanel(show)
    if show == nil then show = not MGUI.isOpen end

    if show then
        createPanel()
    else
        destroyPanel()
    end
end

-- Hook into the screen GUI pass so our overlay actually draws.
Hook.Patch("Barotrauma.GameScreen", "AddToGUIUpdateList", function()
    if frame and MGUI.isOpen then
        frame.AddToGUIUpdateList()
    end
end)

Hook.Add("think", "MidiMod.GUI.Think", function()
    local ch = Character.Controlled
    local holdingNow = ch and MidiMod.IsHoldingInstrument(ch) or false

    -- Auto-open when picking up instrument
    if holdingNow and not wasHoldingInstrument then
        MGUI.togglePanel(true)
    end

    -- Auto-close when dropping instrument
    if not holdingNow and wasHoldingInstrument then
        MGUI.togglePanel(false)
    end

    wasHoldingInstrument = holdingNow

    -- F5 toggle (only while holding instrument)
    local f5Pressed = false
    pcall(function() f5Pressed = PlayerInput.KeyHit(Keys.F5) end)
    if f5Pressed and holdingNow then
        MGUI.togglePanel()
    end

    -- Update status text
    if MGUI.isOpen and statusLabel and MidiMod.Player then
        pcall(function()
            if MidiMod.Player.playing then
                statusLabel.Text = "♪ Playing...  |  F5 to hide"
                statusLabel.TextColor = Color(100, 255, 140)
            else
                statusLabel.Text = "Ready  |  F5 to toggle"
                statusLabel.TextColor = Color(140, 140, 140)
            end
        end)
    end
end)

MidiMod.Log("[GUI] Initialized. Panel auto-shows on instrument pickup. Toggle: F5")
