-- =============================================================================
--  editor_ui.lua  ·  imlove-powered Editor UI  (refactored)
-- =============================================================================
--  WINDOWS
--  ────────────────────────────────────────────────────────────────────────────
--  ##topbar    full-width, no title bar, 2 rows:
--                row 1 — menu bar  (File / Edit / View / Layer)
--                row 2 — toolbar   (tool buttons + grid/editor toggles)
--  ##props     left panel, collapsing headers:
--                Map  · Layer  · Tileset
--  ##sidebar   right panel:
--                top half  — layer list (flat, inline vis/lock/type)
--                bottom half — tileset switcher + tile picker grid
--  ##info      floating top-centre, full stats
--
--  PANEL VISIBILITY
--  ────────────────────────────────────────────────────────────────────────────
--  Toggled via View menu checkboxes:  Props  ·  Sidebar  ·  Info
--
--  USAGE  (same as before)
--  ────────────────────────────────────────────────────────────────────────────
--  ui = EditorUI.new(world, renderer, editor, camera)
--  love.update(dt)      →  ui:update(dt)
--  love.draw()          →  ui:draw()          (call after renderer:draw)
--  love.mousepressed    →  ui:mousepressed(x,y,b)
--  love.mousereleased   →  ui:mousereleased(x,y,b)
--  love.mousemoved      →  (gate with ui:wantMouse())
--  love.wheelmoved      →  ui:wheelmoved(x,y)
--  love.keypressed      →  ui:keypressed(k,s)  then  ui:handleKey(k)
--  love.textinput       →  ui:textinput(t)
-- =============================================================================

local im               = require "imlove"

-- ─────────────────────────────────────────────────────────────────────────────
--  CONSTANTS
-- ─────────────────────────────────────────────────────────────────────────────
local TOPBAR_H         = 48 -- menu row (22) + toolbar row (22) + 4 padding
local PROPS_W          = 200
local SIDEBAR_W        = 220

local TOOLS            = {
    { id = "pencil",     short = "P", key = "1", tip = "Pencil  [1]" },
    { id = "erase",      short = "E", key = "2", tip = "Erase   [2]" },
    { id = "fill",       short = "F", key = "3", tip = "Fill    [3]" },
    { id = "eyedropper", short = "K", key = "4", tip = "Pick    [4]" },
    { id = "rect",       short = "R", key = "5", tip = "Rect    [5]" },
}

local TYPE_LABEL       = { tile = "Tile", object = "Obj", decal = "Decal", trigger = "Trig", light = "Lght" }
local TYPE_COLOR       = {
    tile    = { 0.40, 0.80, 0.40, 1 },
    object  = { 0.40, 0.65, 1.00, 1 },
    decal   = { 1.00, 0.80, 0.30, 1 },
    trigger = { 1.00, 0.45, 0.45, 1 },
    light   = { 1.00, 1.00, 0.45, 1 },
}

local _LAYER_TYPE_LIST = { "tile", "object", "decal", "trigger", "light" }

-- ─────────────────────────────────────────────────────────────────────────────
--  EditorUI
-- ─────────────────────────────────────────────────────────────────────────────
local EditorUI         = {}
EditorUI.__index       = EditorUI

function EditorUI.new(world, renderer, editor, camera)
    local self         = setmetatable({}, EditorUI)
    self.world         = world
    self.renderer      = renderer
    self.editor        = editor
    self.camera        = camera

    -- save/load
    self._savePath     = "map.isob"

    -- new-layer popup state
    self._newLayerName = "new_layer"
    self._newLayerType = 0    -- index into _LAYER_TYPE_LIST

    -- collapsing-header open state
    self._hdrMap       = true
    self._hdrLayer     = true
    self._hdrTileset   = true

    -- palette zoom  1 or 2
    self._palZoom      = 1

    -- panel visibility (toggled from View menu)
    self._showProps    = true
    self._showSidebar  = true
    self._showInfo     = true

    im.Init()
    im.LoadLayout("editor_layout.lua")
    return self
end

-- ─── public callbacks ────────────────────────────────────────────────────────
function EditorUI:update(dt) im.Update(dt) end

function EditorUI:wantMouse() return im.WantCaptureMouse() end

function EditorUI:mousepressed(x, y, b) im.MousePressed(x, y, b) end

function EditorUI:mousereleased(x, y, b) im.MouseReleased(x, y, b) end

function EditorUI:wheelmoved(x, y) im.WheelMoved(x, y) end

function EditorUI:keypressed(k, s) im.KeyPressed(k, s) end

function EditorUI:textinput(t) im.TextInput(t) end

function EditorUI:resize(w, h) im.resize(w, h) end

-- ─────────────────────────────────────────────────────────────────────────────
--  MAIN DRAW
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:draw()
    local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()

    im.BeginFrame()

    self:_drawTopBar(sw, sh)
    if self._showProps then self:_drawProps(sw, sh) end
    if self._showSidebar then self:_drawSidebar(sw, sh) end
    if self._showInfo then self:_drawInfo(sw, sh) end
    self:_drawNewLayerPopup()
    self:_drawDeleteConfirmPopup()

    im.EndFrame()
    love.graphics.setColor(1, 1, 1, 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
--  TOPBAR  (menu bar + toolbar, locked to top)
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:_drawTopBar(sw, sh)
    im.PushStyleVar("windowPadding", 0)
    local visible = im.Begin("##topbar", {
        x = 0,
        y = 0,
        w = sw,
        h = TOPBAR_H,
        noTitleBar  = true,
        noResize    = true,
        noMove      = true,
        noScrollbar = true,
    })
    if not visible then
        im.End(); return
    end
    -- ── row 1: menu bar ───────────────────────────────────────────────────
    if im.BeginMenuBar() then
        self:_menuFile()
        self:_menuEdit()
        self:_menuView()
        self:_menuLayer()
        im.EndMenuBar()
    end

    -- ── row 2: toolbar ────────────────────────────────────────────────────
    local ed = self.editor
    local iw = im.GetContentWidth()
    local bh = 20
    local bw = 28  -- tool button width
    for _, t in ipairs(TOOLS) do
        local active = (ed.tool == t.id)
        if active then
            im.PushStyleColor("button", { 0.25, 0.55, 0.25, 1 })
            im.PushStyleColor("buttonHover", { 0.32, 0.68, 0.32, 1 })
        end

        if im.Button(t.short .. "##tb_" .. t.id, bw, bh) then
            ed:setTool(t.id)
        end
        im.PopStyleVar(2)
        im.SetTooltip(t.tip)
        if active then im.PopStyleColor(2) end
        im.SameLine(4)
    end
    -- separator gap
    im.SameLine(12)

    -- Grid toggle
    local gridActive = self.renderer.showGrid
    if gridActive then
        im.PushStyleColor("button", { 0.55, 0.45, 0.15, 1 })
        im.PushStyleColor("buttonHover", { 0.70, 0.58, 0.20, 1 })
    end
    if im.Button("G##tbgrid", bw, bh) then
        self.renderer.showGrid = not self.renderer.showGrid
    end
    im.SetTooltip("Toggle Grid  [G]")
    if gridActive then im.PopStyleColor(2) end
    im.SameLine(4)

    -- Editor mode toggle
    local edActive = self.editor.active
    if edActive then
        im.PushStyleColor("button", { 0.20, 0.40, 0.65, 1 })
        im.PushStyleColor("buttonHover", { 0.28, 0.52, 0.80, 1 })
    end
    if im.Button("Ed##tbeditor", bw + 8, bh) then
        self.editor.active = not self.editor.active
    end
    im.SetTooltip("Toggle Editor Mode  [E]")
    if edActive then im.PopStyleColor(2) end
    im.End()
    im.PopStyleVar(1)
end

-- ── menu helpers ─────────────────────────────────────────────────────────────
function EditorUI:_menuFile()
    if im.BeginMenu("File") then
        if im.MenuItem("New Map", "Ctrl+N") then self:_cmdNewMap() end
        im.MenuSeparator()
        if im.MenuItem("Open...", "F9") then self:_cmdLoad() end
        if im.MenuItem("Save", "F5") then self:_cmdSave() end
        im.MenuSeparator()
        if im.MenuItem("Save Layout") then
            im.SaveLayout("editor_layout.lua")
        end
        im.MenuSeparator()
        if im.MenuItem("Quit", "Esc") then
            im.SaveLayout("editor_layout.lua")
            love.event.quit()
        end
        im.EndMenu()
    end
end

function EditorUI:_menuEdit()
    if im.BeginMenu("Edit") then
        local canUndo = #self.editor._undoStack > 0
        local canRedo = #self.editor._redoStack > 0
        if im.MenuItem("Undo", "Ctrl+Z", canUndo) then self.editor:undo() end
        if im.MenuItem("Redo", "Ctrl+Y", canRedo) then self.editor:redo() end
        im.MenuSeparator()
        if im.MenuItem("Clear Active Layer") then self:_cmdClearLayer() end
        im.EndMenu()
    end
end

function EditorUI:_menuView()
    if im.BeginMenu("View") then
        -- panel toggles
        self._showProps, _ = im.Checkbox("Properties##vp", self._showProps)
        self._showSidebar, _ = im.Checkbox("Layers/Tilesets##vs", self._showSidebar)
        self._showInfo, _ = im.Checkbox("Info##vi", self._showInfo)
        im.MenuSeparator()
        -- camera
        if im.MenuItem("Reset Camera") then
            local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()
            self.camera:moveTo(sw * 0.5, sh * 0.35)
            self.camera:zoomTo(1)
        end
        im.EndMenu()
    end
end

function EditorUI:_menuLayer()
    if im.BeginMenu("Layer") then
        if im.MenuItem("Add Tile Layer") then
            self._newLayerType = 0
            im.OpenPopup("New Layer##newlayer")
        end
        if im.MenuItem("Add Object Layer") then
            self._newLayerType = 1
            im.OpenPopup("New Layer##newlayer")
        end
        im.MenuSeparator()
        local hasActive = self.editor.activeLayer ~= nil
        if im.MenuItem("Remove Active Layer", nil, hasActive) then
            im.OpenPopup("Confirm Delete##delpop")
        end
        im.MenuSeparator()
        if im.MenuItem("Move Up", nil, hasActive) then
            self.world:moveLayerUp(self.editor.activeLayer)
        end
        if im.MenuItem("Move Down", nil, hasActive) then
            self.world:moveLayerDown(self.editor.activeLayer)
        end
        im.EndMenu()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  PROPS PANEL  (left side, collapsing headers)
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:_drawProps(sw, sh)
    local visible = im.Begin("Properties##props", {
        x = 0,
        y = TOPBAR_H,
        w = PROPS_W,
        h = sh - TOPBAR_H,
        dockable = true,
    })
    if not visible then
        im.End(); return
    end

    local iw = im.GetContentWidth()

    -- ── Map ───────────────────────────────────────────────────────────────
    self._hdrMap = im.CollapsingHeader("Map##hmap", self._hdrMap)
    if self._hdrMap then
        im.Indent()
        im.Label("Tile size:")
        im.Label(string.format("  W: %d  H: %d", self.world.tileW, self.world.tileH))
        im.Label("Layers: " .. #self.world.layers)
        local tsCount = 0
        for _ in pairs(self.world.tilesets) do tsCount = tsCount + 1 end
        im.Label("Tilesets: " .. tsCount)
        im.Separator()
        -- save path
        self._savePath = im.InputText("Path##savepath", self._savePath)
        local hw = math.floor(iw * 0.5) - 2
        if im.Button("Save##mapsave", hw) then self:_cmdSave() end
        im.SameLine()
        if im.Button("Load##mapload", hw) then self:_cmdLoad() end
        if im.Button("New Map##mapnew", iw) then self:_cmdNewMap() end
        im.Unindent()
    end

    -- ── Active Layer ──────────────────────────────────────────────────────
    local ed          = self.editor
    local activeLayer = ed.activeLayer and self.world:getLayer(ed.activeLayer)

    self._hdrLayer    = im.CollapsingHeader(
        "Layer: " .. (ed.activeLayer or "(none)") .. "##hlayer", self._hdrLayer)
    if self._hdrLayer then
        if activeLayer then
            im.Indent()
            -- type badge
            local tc = TYPE_COLOR[activeLayer.type] or { 0.7, 0.7, 0.7, 1 }
            im.LabelColored(
                "Type: " .. (TYPE_LABEL[activeLayer.type] or "?"),
                tc[1], tc[2], tc[3], 1)

            -- vis / lock
            activeLayer.visible, _ = im.Checkbox("Visible##lvis", activeLayer.visible)
            im.SameLine()
            activeLayer.locked, _ = im.Checkbox("Locked##llck", activeLayer.locked)

            -- opacity
            local newOp = im.Slider("Opacity##lop", activeLayer.opacity, 0, 1, "%.2f")
            if newOp ~= activeLayer.opacity then activeLayer.opacity = newOp end

            -- elevation (tile/light layers)
            if activeLayer.type == "tile" or activeLayer.type == "light" then
                local newEl = im.SliderInt("Elevation##lel",
                    activeLayer.elevation or 0, -8, 16)
                if newEl ~= activeLayer.elevation then
                    activeLayer.elevation   = newEl
                    activeLayer._batchDirty = true
                end
            end

            -- tileset assignment (tile layers)
            if activeLayer.type == "tile" then
                im.Label("Tileset:")
                for tsName in pairs(self.world.tilesets) do
                    local isSel = (activeLayer.tilesetName == tsName)
                    local _, clicked = im.Selectable(
                        tsName .. "##lts_" .. tsName, isSel)
                    if clicked then
                        activeLayer.tilesetName = tsName
                        activeLayer._batchDirty = true
                    end
                end
            end

            -- object count
            if activeLayer.objects then
                im.Label("Objects: " .. #activeLayer.objects)
            end

            -- tile count (sparse grid layers)
            if activeLayer._grid then
                local cnt = 0
                for _, row in pairs(activeLayer._grid.data) do
                    for _ in pairs(row) do cnt = cnt + 1 end
                end
                im.Label("Tiles: " .. cnt)
            end
            im.Unindent()
        else
            im.Indent()
            im.LabelColored("No active layer", 0.5, 0.5, 0.5, 1)
            im.Unindent()
        end
    end

    -- ── Active Tileset ────────────────────────────────────────────────────
    local tsName = nil
    if activeLayer then tsName = activeLayer.tilesetName end
    if not tsName then tsName = next(self.world.tilesets) end
    local ts = tsName and self.world.tilesets[tsName]

    self._hdrTileset = im.CollapsingHeader(
        "Tileset: " .. (tsName or "(none)") .. "##htileset", self._hdrTileset)
    if self._hdrTileset then
        if ts then
            im.Indent()
            im.Label("Name: " .. ts.name)
            im.Label(string.format("Tile W/H: %d / %d", ts.tileW, ts.tileH))
            im.Label("Count: " .. ts.count)
            im.Label(string.format("Margin: %d  Spacing: %d",
                ts.margin or 0, ts.spacing or 0))
            -- image dimensions
            if ts.image then
                local iw2, ih2 = ts.image:getDimensions()
                im.Label(string.format("Atlas: %d × %d px", iw2, ih2))
            end
            -- active tile ID
            im.Separator()
            im.Label("Active tile ID: " .. ed.activeTileID)
            -- preview of active tile
            if ts.quads[ed.activeTileID] then
                local q            = ts.quads[ed.activeTileID]
                local _, _, qw, qh = q:getViewport()
                local pw           = math.min(iw - 8, 64)
                local ph           = math.floor(pw * qh / qw)
                im.Image(ts.image, q, pw, ph)
            end
            im.Unindent()
        else
            im.Indent()
            im.LabelColored("No tileset loaded", 0.5, 0.5, 0.5, 1)
            im.Unindent()
        end
    end

    im.End()
end

-- ─────────────────────────────────────────────────────────────────────────────
--  SIDEBAR  (right side: layer list + tileset tile picker)
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:_drawSidebar(sw, sh)
    local visible = im.Begin("Layers & Tilesets##sidebar", {
        x = sw - SIDEBAR_W,
        y = TOPBAR_H,
        w = SIDEBAR_W,
        h = sh - TOPBAR_H
    }, im.FitContent)
    if not visible then
        im.End(); return
    end

    local world = self.world
    local ed    = self.editor
    local iw    = im.GetContentWidth()

    -- ── Layer list ────────────────────────────────────────────────────────
    im.LabelColored("LAYERS", 0.55, 0.75, 1, 1)
    im.Separator()

    -- reverse draw order (top visual = top of list)
    for i = #world.layers, 1, -1 do
        local layer    = world.layers[i]
        local isActive = (ed.activeLayer == layer.name)

        if isActive then
            im.PushStyleColor("widgetBg", { 0.18, 0.32, 0.52, 1 })
            im.PushStyleColor("widgetHover", { 0.24, 0.40, 0.64, 1 })
        end

        local _, clicked = im.Selectable("##lr_" .. layer.name, isActive, iw, 20)
        if clicked then ed:setLayer(layer.name) end

        if isActive then im.PopStyleColor(2) end

        -- overlay: vis + lock + name + type badge
        im.SameLine(4)
        local visC = layer.visible and { 0.3, 0.9, 0.3, 1 } or { 0.4, 0.4, 0.4, 1 }
        im.LabelColored(layer.visible and "V" or "-", visC[1], visC[2], visC[3], 1)
        im.SameLine()
        local lckC = layer.locked and { 1, 0.6, 0.2, 1 } or { 0.4, 0.4, 0.4, 0.5 }
        im.LabelColored(layer.locked and "L" or ".", lckC[1], lckC[2], lckC[3], 1)
        im.SameLine()

        local name = layer.name
        if #name > 11 then name = name:sub(1, 10) .. "…" end
        im.Label(name)
        im.SameLine()
        local tc = TYPE_COLOR[layer.type] or { 0.7, 0.7, 0.7, 1 }
        im.LabelColored(
            "[" .. (TYPE_LABEL[layer.type] or "?") .. "]",
            tc[1], tc[2], tc[3], 1)
    end

    -- action buttons: + Tile, + Obj, Up, Down, Del
    im.Separator()
    local hw = math.floor(iw * 0.5) - 2
    if im.Button("+Tile##ladd",40) then
        self._newLayerType = 0
        im.OpenPopup("New Layer##newlayer")
    end
    im.SetTooltip("Add tile layer")
    im.SameLine()
    if im.Button("+Obj##laddo",40) then
        self._newLayerType = 1
        im.OpenPopup("New Layer##newlayer")
    end
    im.SetTooltip("Add object layer")

    local b3 = math.floor(iw / 3) - 2
    if im.Button("Up##lup",40) then
        if ed.activeLayer then world:moveLayerUp(ed.activeLayer) end
    end
    im.SameLine()
    if im.Button("Dn##ldn",40) then
        if ed.activeLayer then world:moveLayerDown(ed.activeLayer) end
    end
    im.SameLine()
    if im.Button("Del##ldel",40) then
        im.OpenPopup("Confirm Delete##delpop")
    end

    -- ── Tileset tile picker ───────────────────────────────────────────────
    im.Separator()
    im.LabelColored("TILESET", 0.55, 0.75, 1, 1)

    -- tileset switcher (if multiple tilesets exist)
    local tsNames = {}
    for n in pairs(world.tilesets) do table.insert(tsNames, n) end
    table.sort(tsNames)

    local activeTsName = nil
    if ed.activeLayer then
        local al = world:getLayer(ed.activeLayer)
        activeTsName = al and al.tilesetName
    end
    if not activeTsName then activeTsName = tsNames[1] end

    if #tsNames > 1 then
        for _, n in ipairs(tsNames) do
            local isSel = (n == activeTsName)
            if isSel then
                im.PushStyleColor("widgetBg", { 0.18, 0.32, 0.52, 1 })
                im.PushStyleColor("widgetHover", { 0.24, 0.40, 0.64, 1 })
            end
            local _, clicked = im.Selectable(n .. "##ts_" .. n, isSel, iw, 18)
            if clicked then
                activeTsName = n
                -- assign to active layer if it's a tile layer
                local al = ed.activeLayer and world:getLayer(ed.activeLayer)
                if al and al.type == "tile" then
                    al.tilesetName = n
                    al._batchDirty = true
                end
            end
            if isSel then im.PopStyleColor(2) end
        end
        im.Separator()
    end

    local ts = activeTsName and world.tilesets[activeTsName]
    if not ts then
        im.LabelColored("No tileset", 0.5, 0.5, 0.5, 1)
        im.End()
        return
    end

    -- zoom toggle
    local zl = self._palZoom == 2 and "Zoom:2x##pz" or "Zoom:1x##pz"
    if im.Button(zl, 72) then
        self._palZoom = self._palZoom == 1 and 2 or 1
    end
    im.Label(ts.count .. " tiles", { 0.6, 0.6, 0.7, 1 })

    im.Separator()

    -- tile grid
    local contentAreaW = SIDEBAR_W - (im.style.windowPadding * 2)
    local scale = self._palZoom
    local cols  = math.max(1, math.floor(contentAreaW / (ts.tileW * scale + im.style.itemSpacingX)))
    local tileW = math.floor((contentAreaW - (cols - 1) * im.style.itemSpacingX) / cols)
    local tileH = math.floor(tileW * ts.tileH / ts.tileW)

    for i = 1, ts.count do
        if not ts.quads[i] then break end
        local isSel = (ed.activeTileID == i)
        if isSel then
            im.PushStyleColor("widgetBg", { 0.20, 0.50, 0.20, 1 })
            im.PushStyleColor("widgetHover", { 0.28, 0.62, 0.28, 1 })
            im.PushStyleColor("widgetActive", { 0.35, 0.72, 0.35, 1 })
        end
        local _, clicked = im.SelectableImage(
            "##pal_" .. i, ts.image, ts.quads[i], isSel, tileW, tileH)
        if clicked then ed.activeTileID = i end
        im.SetTooltip("Tile " .. i)
        if isSel then im.PopStyleColor(3) end
        if i % cols ~= 0 and i < ts.count then im.SameLine() end
    end

    im.End()
end

-- ─────────────────────────────────────────────────────────────────────────────
--  INFO PANEL  (floating top-centre, full stats)
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:_drawInfo(sw, sh)
    local panW = 260
    local visible = im.Begin("Info##info", {
        x = math.floor(sw * 0.5 - panW * 0.5),
        y = TOPBAR_H + 4,
        w = panW,
        h = 210
    }, im.FitContent)
    if not visible then
        im.End(); return
    end

    local ed  = self.editor
    local cam = self.camera

    -- FPS
    local fps = love.timer.getFPS()
    local fc  = fps >= 55 and { 0.3, 1, 0.45, 1 } or fps >= 30 and { 1, 0.8, 0.3, 1 } or { 1, 0.35, 0.35, 1 }
    im.LabelColored(string.format("FPS: %d", fps), fc[1], fc[2], fc[3], 1)

    -- zoom
    im.Label(string.format("Zoom: %.2fx", cam.zoom))

    -- cursor
    if ed._hoverTile then
        im.Label(string.format("Cursor: %d, %d", ed._hoverTile[1], ed._hoverTile[2]))
    else
        im.Label("Cursor: –")
    end

    -- active tool / layer / tile
    im.Label("Tool:  " .. ed.tool)
    im.Label("Layer: " .. (ed.activeLayer or "none"))
    im.Label("Tile:  " .. ed.activeTileID)

    im.Separator()

    -- undo/redo depth
    local undoCol = #ed._undoStack > 150 and { 1, 0.5, 0.2, 1 } or { 0.7, 0.7, 0.7, 1 }
    im.LabelColored(
        string.format("Undo: %d  Redo: %d", #ed._undoStack, #ed._redoStack),
        undoCol[1], undoCol[2], undoCol[3], 1)

    im.Separator()

    -- total tile count across all layers
    local totalTiles = 0
    for _, layer in ipairs(self.world.layers) do
        if layer._grid then
            for _, row in pairs(layer._grid.data) do
                for _ in pairs(row) do totalTiles = totalTiles + 1 end
            end
        end
    end
    im.Label(string.format("Total tiles: %d", totalTiles))
    im.Label(string.format("Layers: %d", #self.world.layers))

    -- per-layer tile counts
    im.Separator()
    im.LabelColored("Per layer:", 0.6, 0.8, 1, 1)
    for _, layer in ipairs(self.world.layers) do
        if layer._grid then
            local cnt = 0
            for _, row in pairs(layer._grid.data) do
                for _ in pairs(row) do cnt = cnt + 1 end
            end
            local tc = TYPE_COLOR[layer.type] or { 0.7, 0.7, 0.7, 1 }
            local name = layer.name
            if #name > 10 then name = name:sub(1, 9) .. "…" end
            im.LabelColored(
                string.format("  %-12s %d", name, cnt),
                tc[1], tc[2], tc[3], 1)
        end
    end

    im.End()
end

-- ─────────────────────────────────────────────────────────────────────────────
--  POPUPS
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:_drawNewLayerPopup()
    if im.BeginPopup("New Layer##newlayer", { w = 280, h = 210 }) then
        im.LabelColored("New Layer", 0.6, 0.9, 1, 1)
        im.Separator()

        self._newLayerName = im.InputText("Name##nlname", self._newLayerName)

        im.Label("Type:")
        for i, t in ipairs(_LAYER_TYPE_LIST) do
            self._newLayerType, _ = im.RadioButton(t .. "##nlt", self._newLayerType, i - 1)
            if i < #_LAYER_TYPE_LIST then im.SameLine() end
        end

        im.Spacing()

        local iw = im.GetContentWidth()
        local hw = math.floor(iw * 0.5) - 2

        if im.Button("Create##nlcreate", hw) then
            local name = self._newLayerName
            if name ~= "" and not self.world:getLayer(name) then
                local ltype = _LAYER_TYPE_LIST[self._newLayerType + 1]
                local al    = self.editor.activeLayer
                    and (self.world:getLayer(self.editor.activeLayer) or {}).tilesetName
                self.world:addLayer(name, ltype, {
                    tileset = al or next(self.world.tilesets),
                })
                self.editor:setLayer(name)
                self._newLayerName = "new_layer"
                im.ClosePopup("New Layer##newlayer")
            end
        end
        im.SameLine()
        if im.Button("Cancel##nlcancel", hw) then
            im.ClosePopup("New Layer##newlayer")
        end

        im.EndPopup()
    end
end

function EditorUI:_drawDeleteConfirmPopup()
    if im.BeginPopup("Confirm Delete##delpop", { w = 260, h = 130 }) then
        local layName = self.editor.activeLayer or "?"
        im.LabelColored("Delete '" .. layName .. "'?", 1, 0.5, 0.35, 1)
        im.LabelColored("This cannot be undone.", 0.55, 0.55, 0.55, 1)
        im.Separator()

        local iw = im.GetContentWidth()
        local hw = math.floor(iw * 0.5) - 2

        if im.Button("Delete##delyes", hw) then
            if self.editor.activeLayer then
                local name = self.editor.activeLayer
                self.editor.activeLayer = nil
                self.world:removeLayer(name)
            end
            im.ClosePopup("Confirm Delete##delpop")
        end
        im.SameLine()
        if im.Button("Cancel##delno", hw) then
            im.ClosePopup("Confirm Delete##delpop")
        end

        im.EndPopup()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  KEYBOARD SHORTCUTS  (call from love.keypressed, after im.KeyPressed)
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:handleKey(key)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")

    if ctrl then
        if key == "z" then
            self.editor:undo(); return true
        end
        if key == "y" then
            self.editor:redo(); return true
        end
        if key == "s" then
            self:_cmdSave(); return true
        end
        if key == "n" then
            self:_cmdNewMap(); return true
        end
    end

    local toolKeys = {
        ["1"] = "pencil",
        ["2"] = "erase",
        ["3"] = "fill",
        ["4"] = "eyedropper",
        ["5"] = "rect"
    }
    if toolKeys[key] then
        self.editor:setTool(toolKeys[key]); return true
    end

    if key == "g" then
        self.renderer.showGrid = not self.renderer.showGrid; return true
    end
    if key == "e" then
        self.editor.active = not self.editor.active; return true
    end
    if key == "f5" then
        self:_cmdSave(); return true
    end
    if key == "f9" then
        self:_cmdLoad(); return true
    end

    if key == "tab" then
        local layers = self.world.layers
        if #layers == 0 then return true end
        local idx = 1
        for i, l in ipairs(layers) do
            if l.name == self.editor.activeLayer then
                idx = i; break
            end
        end
        idx = idx % #layers + 1
        self.editor:setLayer(layers[idx].name)
        return true
    end

    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
--  COMMANDS
-- ─────────────────────────────────────────────────────────────────────────────
function EditorUI:_cmdSave()
    local ok, err = self.world:save(self._savePath)
    if not ok then
        print("[EditorUI] Save failed: " .. tostring(err))
    end
end

function EditorUI:_cmdLoad()
    local ok, err = self.world:load(self._savePath)
    if not ok then
        print("[EditorUI] Load failed: " .. tostring(err))
    end
end

function EditorUI:_cmdNewMap()
    for _, layer in ipairs(self.world.layers) do
        if layer._grid then
            layer._grid.data  = {}
            layer._grid.dirty = true
            layer._batchDirty = true
        end
        if layer.objects then layer.objects = {} end
    end
end

function EditorUI:_cmdClearLayer()
    local layer = self.editor.activeLayer
        and self.world:getLayer(self.editor.activeLayer)
    if not layer or not layer._grid then return end
    layer._grid.data  = {}
    layer._grid.dirty = true
    layer._batchDirty = true
end

return EditorUI
