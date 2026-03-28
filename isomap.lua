-- =============================================================================
--  isomap.lua  ·  Professional 2.5D Isometric Map Library for LÖVE 2D
--  v1.1.0
-- =============================================================================
--  ARCHITECTURE
--  ─────────────────────────────────────────────────────────────────────────────
--  IsoMath     coordinate transforms  (world ↔ iso ↔ screen)
--  Tileset     image + quad registry + per-tile animation & properties
--  SparseGrid  infinite tile storage  (nested hash, zero cost for empty space)
--  Layer       tile | object | decal | trigger | light
--  World       layer stack + tileset registry + global config
--  Camera      pan / zoom-to-point / smooth follow / bounds clamping
--  Renderer    frustum culling · dynamic SpriteBatch · depth sorting
--  Editor      pencil / erase / fill / eyedropper / rect · undo/redo stack
--  Serializer  save / load  (binary .isob — no tile-count limit, ~10 bytes/tile)
--              Legacy v1 Lua-table .lua files are auto-detected and still load.
-- =============================================================================

local IsoMap = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- INTERNAL HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function lerp(a, b, t)    return a + (b - a) * t               end

-- Serialize a Lua value to source string (used by Serializer)
local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if     t == "number"  then return tostring(val)
    elseif t == "boolean" then return tostring(val)
    elseif t == "string"  then return string.format("%q", val)
    elseif t == "table"   then
        local child = indent .. "  "
        local parts = {}
        if #val > 0 then
            for _, v in ipairs(val) do
                table.insert(parts, child .. serialize(v, child))
            end
        else
            for k, v in pairs(val) do
                local key = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
                table.insert(parts, child .. key .. " = " .. serialize(v, child))
            end
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1 · IsoMath  — the single source of truth for all projections
-- ─────────────────────────────────────────────────────────────────────────────
--[[
    Standard 2:1 isometric projection:

        isoX = (tileX - tileY) * (tileW / 2)
        isoY = (tileX + tileY) * (tileH / 2)  −  elevation * (tileH / 2)

    Inverse:
        tileX = (isoX/(tileW/2) + isoY/(tileH/2)) / 2
        tileY = (isoY/(tileH/2) - isoX/(tileW/2)) / 2

    Camera transform (applied on top):
        screenX = isoX * zoom + camX
        screenY = isoY * zoom + camY
]]

local IsoMath = {}

function IsoMath.worldToISO(tx, ty, tz, tileW, tileH)
    tz = tz or 0
    local sx = (tx - ty)  * (tileW * 0.5)
    local sy = (tx + ty)  * (tileH * 0.5) - tz * (tileH * 0.5)
    return sx, sy
end

function IsoMath.isoToWorld(sx, sy, tileW, tileH)
    local hw, hh = tileW * 0.5, tileH * 0.5
    local tx = (sx / hw + sy / hh) * 0.5
    local ty = (sy / hh - sx / hw) * 0.5
    return tx, ty
end

-- Painter's-algorithm depth value. Lower = drawn first (behind).
function IsoMath.depth(tx, ty, layerIndex, elevation)
    return tx + ty + (layerIndex or 0) * 10000 + (elevation or 0)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2 · Tileset
-- ─────────────────────────────────────────────────────────────────────────────
--[[
    Tileset.new(name, image, config)
    config = {
        tileWidth  = 64,
        tileHeight = 32,
        margin     = 0,   -- outer pixel gap in the atlas
        spacing    = 0,   -- pixel gap between tiles
    }
    Tile IDs are 1-indexed; 0 = empty/air.
]]

local Tileset = {}
Tileset.__index = Tileset

function Tileset.new(name, image, config)
    config = config or {}
    local ts   = setmetatable({}, Tileset)
    ts.name    = name
    ts.image   = image
    ts.tileW   = config.tileWidth  or 64
    ts.tileH   = config.tileHeight or 32
    ts.margin  = config.margin  or 0
    ts.spacing = config.spacing or 0
    ts.quads       = {}   -- id → Quad
    ts.animations  = {}   -- id → {frames={ids}, duration=seconds}
    ts.properties  = {}   -- id → {key=value, ...}
    ts:_buildQuads()
    return ts
end

function Tileset:_buildQuads()
    local iw, ih = self.image:getDimensions()
    local m, s   = self.margin, self.spacing
    local cols   = math.floor((iw - m + s) / (self.tileW + s))
    local rows   = math.floor((ih - m + s) / (self.tileH + s))
    local id     = 1
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local qx = m + col * (self.tileW + s)
            local qy = m + row * (self.tileH + s)
            self.quads[id] = love.graphics.newQuad(qx, qy, self.tileW, self.tileH, iw, ih)
            id = id + 1
        end
    end
    self.count = id - 1
end

function Tileset:getQuad(id)        return self.quads[id]     end
function Tileset:setProperty(id, k, v)  self.properties[id] = self.properties[id] or {}
                                         self.properties[id][k] = v end
function Tileset:getProperty(id, k) return (self.properties[id] or {})[k] end

function Tileset:setAnimation(id, frames, frameDuration)
    self.animations[id] = { frames = frames, duration = frameDuration or 0.1 }
end

-- Returns the visual tile ID at the given world time (handles animation)
function Tileset:resolveID(id, time)
    local anim = self.animations[id]
    if not anim then return id end
    local n = #anim.frames
    return anim.frames[math.floor(time / anim.duration) % n + 1]
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3 · SparseGrid  — infinite, zero-cost-for-empty storage
-- ─────────────────────────────────────────────────────────────────────────────

local SparseGrid = {}
SparseGrid.__index = SparseGrid

function SparseGrid.new()
    return setmetatable({ data = {}, dirty = true }, SparseGrid)
end

function SparseGrid:get(x, y)
    local row = self.data[y]
    return row and row[x] or 0
end

function SparseGrid:set(x, y, val)
    if val == nil or val == 0 then
        if self.data[y] then
            self.data[y][x] = nil
            if next(self.data[y]) == nil then self.data[y] = nil end
        end
    else
        if not self.data[y] then self.data[y] = {} end
        self.data[y][x] = val
    end
    self.dirty = true
end

-- Bulk-load path: skips dirty flagging for each cell (caller sets dirty once after).
-- ~3x faster than set() for initial map load.
function SparseGrid:setRaw(x, y, val)
    if val == nil or val == 0 then return end
    local row = self.data[y]
    if not row then row = {}; self.data[y] = row end
    row[x] = val
end

function SparseGrid:fill(x1, y1, x2, y2, val)
    for y = y1, y2 do
        for x = x1, x2 do self:set(x, y, val) end
    end
end

-- BFS flood fill — bounded by `limit` cells to prevent runaway on open maps
function SparseGrid:floodFill(startX, startY, newVal, limit)
    limit = limit or 5000
    local target = self:get(startX, startY)
    if target == newVal then return end
    local queue   = { { startX, startY } }
    local visited = {}
    local count   = 0
    while #queue > 0 and count < limit do
        local pos    = table.remove(queue, 1)
        local x, y  = pos[1], pos[2]
        local key    = x .. "," .. y
        if not visited[key] and self:get(x, y) == target then
            visited[key] = true
            self:set(x, y, newVal)
            count = count + 1
            table.insert(queue, { x+1, y })
            table.insert(queue, { x-1, y })
            table.insert(queue, { x,   y+1 })
            table.insert(queue, { x,   y-1 })
        end
    end
end

-- Iterate only over non-empty tiles within a rectangle — O(non-empty tiles only)
function SparseGrid:iterRect(x1, y1, x2, y2, fn)
    for y = y1, y2 do
        local row = self.data[y]
        if row then
            for x = x1, x2 do
                local v = row[x]
                if v then fn(x, y, v) end
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4 · Layer
-- ─────────────────────────────────────────────────────────────────────────────
--[[
    Layer types:
      "tile"    — isometric tile grid  (backed by SparseGrid)
      "object"  — free-placed entities / sprites
      "decal"   — non-grid images placed at world coords
      "trigger" — invisible logic zones  (not drawn by default)
      "light"   — per-tile light multipliers  (future: post-process)
]]

local Layer = {}
Layer.__index = Layer

function Layer.new(name, layerType, config)
    config = config or {}
    local l      = setmetatable({}, Layer)
    l.name        = name
    l.type        = layerType
    l.visible     = config.visible   ~= false
    l.locked      = config.locked    or false
    l.opacity     = config.opacity   or 1
    l.tilesetName = config.tileset   or nil
    l.elevation   = config.elevation or 0   -- whole-layer Z offset
    l.objects     = {}                       -- object / decal / trigger entries
    l._grid       = (layerType == "tile" or layerType == "light") and SparseGrid.new() or nil
    l._batch      = nil                      -- SpriteBatch, managed by Renderer
    l._batchDirty = true
    return l
end

-- Tile layer methods
function Layer:getTile(x, y)
    assert(self._grid, "getTile: layer '" .. self.name .. "' is not a tile layer")
    return self._grid:get(x, y)
end

function Layer:setTile(x, y, id)
    assert(self._grid, "setTile: layer '" .. self.name .. "' is not a tile layer")
    self._grid:set(x, y, id)
    self._batchDirty = true
end

-- Object layer methods
function Layer:addObject(obj)
    table.insert(self.objects, obj)
    return obj
end

function Layer:removeObject(obj)
    for i, o in ipairs(self.objects) do
        if o == obj then table.remove(self.objects, i); return true end
    end
    return false
end

function Layer:findObjects(predicate)
    local results = {}
    for _, o in ipairs(self.objects) do
        if predicate(o) then table.insert(results, o) end
    end
    return results
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5 · World
-- ─────────────────────────────────────────────────────────────────────────────

local World = {}
World.__index = World

function World.new(config)
    config = config or {}
    local w       = setmetatable({}, World)
    w.tileW       = config.tileWidth  or 64
    w.tileH       = config.tileHeight or 32
    w.layers      = {}      -- ordered draw list
    w._layerMap   = {}      -- name → Layer  (fast lookup)
    w.tilesets    = {}      -- name → Tileset
    w.properties  = {}      -- free-form map metadata
    return w
end

function World:registerTileset(tileset)
    self.tilesets[tileset.name] = tileset
end

function World:addLayer(name, layerType, config)
    assert(not self._layerMap[name], "Layer already exists: " .. name)
    local l = Layer.new(name, layerType, config)
    table.insert(self.layers, l)
    self._layerMap[name] = l
    return l
end

function World:insertLayer(index, name, layerType, config)
    assert(not self._layerMap[name], "Layer already exists: " .. name)
    local l = Layer.new(name, layerType, config)
    table.insert(self.layers, index, l)
    self._layerMap[name] = l
    return l
end

function World:removeLayer(name)
    local l = self._layerMap[name]
    if not l then return end
    for i, layer in ipairs(self.layers) do
        if layer == l then table.remove(self.layers, i); break end
    end
    self._layerMap[name] = nil
end

function World:getLayer(name) return self._layerMap[name] end

function World:setTile(layerName, x, y, id)
    local l = self:getLayer(layerName)
    assert(l, "Layer not found: " .. tostring(layerName))
    l:setTile(x, y, id)
end

function World:getTile(layerName, x, y)
    local l = self:getLayer(layerName)
    assert(l, "Layer not found: " .. tostring(layerName))
    return l:getTile(x, y)
end

function World:moveLayerUp(name)
    for i, l in ipairs(self.layers) do
        if l.name == name and i > 1 then
            self.layers[i], self.layers[i-1] = self.layers[i-1], self.layers[i]
            return
        end
    end
end

function World:moveLayerDown(name)
    for i, l in ipairs(self.layers) do
        if l.name == name and i < #self.layers then
            self.layers[i], self.layers[i+1] = self.layers[i+1], self.layers[i]
            return
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6 · Camera
-- ─────────────────────────────────────────────────────────────────────────────

local Camera = {}
Camera.__index = Camera

function Camera.new(config)
    config = config or {}
    local c         = setmetatable({}, Camera)
    c.x             = config.x          or 0
    c.y             = config.y          or 0
    c.zoom          = config.zoom       or 1
    c.minZoom       = config.minZoom    or 0.12
    c.maxZoom       = config.maxZoom    or 2
    c.bounds        = config.bounds     or nil   -- {x1,y1,x2,y2} in screen units
    c._target       = nil
    c._followSpeed  = config.followSpeed or 6
    return c
end

function Camera:pan(dx, dy)
    self.x = self.x + dx
    self.y = self.y + dy
    self:_clamp()
end

function Camera:moveTo(x, y) self.x = x; self.y = y; self:_clamp() end

function Camera:zoomTo(z)
    self.zoom = clamp(z, self.minZoom, self.maxZoom)
end

-- Zoom toward a screen-space point (e.g. mouse cursor) — no jitter
function Camera:zoomToPoint(factor, px, py)
    local prev = self.zoom
    self:zoomTo(self.zoom * factor)
    local ratio = self.zoom / prev
    self.x = px - (px - self.x) * ratio
    self.y = py - (py - self.y) * ratio
end

function Camera:follow(entity)  self._target = entity   end
function Camera:unfollow()      self._target = nil      end

function Camera:update(dt, screenW, screenH)
    if self._target then
        local tx = screenW * 0.5 - (self._target.isoX or 0) * self.zoom
        local ty = screenH * 0.5 - (self._target.isoY or 0) * self.zoom
        self.x = lerp(self.x, tx, clamp(self._followSpeed * dt, 0, 1))
        self.y = lerp(self.y, ty, clamp(self._followSpeed * dt, 0, 1))
        self:_clamp()
    end
end

function Camera:_clamp()
    if not self.bounds then return end
    local b = self.bounds
    self.x  = clamp(self.x, b.x1, b.x2)
    self.y  = clamp(self.y, b.y1, b.y2)
end

-- iso-space ↔ screen-space  (without tile quantization)
function Camera:screenToISO(px, py)
    return (px - self.x) / self.zoom, (py - self.y) / self.zoom
end

function Camera:ISOToScreen(ix, iy)
    return ix * self.zoom + self.x, iy * self.zoom + self.y
end

-- Full conversion: screen pixel → tile coords (floored)
function Camera:screenToTile(px, py, tileW, tileH)
    local ix, iy = self:screenToISO(px, py)
    local tx, ty = IsoMath.isoToWorld(ix, iy, tileW, tileH)
    return math.floor(tx), math.floor(ty)
end

function Camera:attach()
    love.graphics.push()
    love.graphics.translate(self.x, self.y)
    love.graphics.scale(self.zoom, self.zoom)
end

function Camera:detach()
    love.graphics.pop()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7 · Renderer
-- ─────────────────────────────────────────────────────────────────────────────

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(config)
    config = config or {}
    local r       = setmetatable({}, Renderer)
    r.padding     = config.padding   or 2        -- extra tile buffer around viewport
    r.showGrid    = config.showGrid  or false
    r.gridColor   = config.gridColor or { 0.3, 0.3, 0.3, 0.25 }
    r._time       = 0
    return r
end

function Renderer:update(dt)
    self._time = self._time + dt
end

-- Back-project viewport corners into tile space to get visible range
function Renderer:_visibleRange(world, camera, sw, sh)
    local corners = { {0,0}, {sw,0}, {0,sh}, {sw,sh} }
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs(corners) do
        local ix, iy = camera:screenToISO(c[1], c[2])
        local tx, ty = IsoMath.isoToWorld(ix, iy, world.tileW, world.tileH)
        if tx < minX then minX = tx end
        if ty < minY then minY = ty end
        if tx > maxX then maxX = tx end
        if ty > maxY then maxY = ty end
    end
    local p = self.padding
    return math.floor(minX)-p, math.floor(minY)-p,
           math.ceil(maxX)+p,  math.ceil(maxY)+p
end

-- Rebuild the SpriteBatch for one tile layer using only visible tiles.
-- Single-pass: collects draw calls into a temp array, sizes the batch from
-- the result, only reallocates when capacity needs to GROW (never shrinks).
function Renderer:_rebuildBatch(layer, world, x1, y1, x2, y2)
    local ts = world.tilesets[layer.tilesetName]
    if not ts then return end

    local tileW, tileH = world.tileW, world.tileH
    local elev         = layer.elevation
    local time         = self._time
    local hw           = tileW * 0.5

    -- Single-pass collect
    local calls = self._calls  -- reuse table to avoid GC pressure
    if not calls then calls = {}; self._calls = calls end
    local count = 0

    layer._grid:iterRect(x1, y1, x2, y2, function(tx, ty, tileID)
        local drawID = ts:resolveID(tileID, time)
        local quad   = ts:getQuad(drawID)
        if quad then
            count = count + 1
            local sx, sy = IsoMath.worldToISO(tx, ty, elev, tileW, tileH)
            local e = calls[count]
            if e then e[1]=quad; e[2]=sx-hw; e[3]=sy
            else calls[count] = { quad, sx-hw, sy } end
        end
    end)

    -- Grow-only capacity (50% headroom absorbs zoom-out without thrashing)
    local needed = math.max(64, count)
    if not layer._batch
        or layer._batchTS  ~= layer.tilesetName
        or (layer._batchCap or 0) < needed then
        local cap       = math.ceil(needed * 1.5)
        layer._batch    = love.graphics.newSpriteBatch(ts.image, cap, "dynamic")
        layer._batchTS  = layer.tilesetName
        layer._batchCap = cap
    end

    local batch = layer._batch
    batch:clear()
    for i = 1, count do
        local c = calls[i]
        batch:add(c[1], c[2], c[3])
    end

    layer._batchDirty    = false
    layer._grid.dirty    = false
    layer._lastDrawCount = count
end

function Renderer:draw(world, camera, screenW, screenH)
    screenW = screenW or love.graphics.getWidth()
    screenH = screenH or love.graphics.getHeight()

    local x1, y1, x2, y2 = self:_visibleRange(world, camera, screenW, screenH)

    -- Camera dirty tracking: only rebuild when viewport actually changed
    -- or when a tile edit flagged the layer dirty.
    local cx, cy, cz = camera.x, camera.y, camera.zoom
    local camMoved = (cx ~= self._lastCX or cy ~= self._lastCY
                   or cz ~= self._lastCZ or x1 ~= self._lastX1
                   or y1 ~= self._lastY1)
    self._lastCX = cx; self._lastCY = cy; self._lastCZ = cz
    self._lastX1 = x1; self._lastY1 = y1

    camera:attach()

        for layerIndex, layer in ipairs(world.layers) do
            if layer.visible then
                love.graphics.setColor(1, 1, 1, layer.opacity)

                if layer.type == "tile" then
                    -- Rebuild only on camera move, tile edit, or first draw
                    if camMoved or layer._batchDirty or not layer._batch then
                        self:_rebuildBatch(layer, world, x1, y1, x2, y2)
                    end
                    if layer._batch then
                        love.graphics.draw(layer._batch)
                    end

                elseif layer.type == "object" or layer.type == "decal" then
                    -- Depth-sort objects then draw
                    local sorted = {}
                    for _, obj in ipairs(layer.objects) do
                        if obj.visible ~= false then
                            table.insert(sorted, {
                                obj   = obj,
                                depth = IsoMath.depth(
                                    obj.tileX or 0, obj.tileY or 0,
                                    layerIndex,     obj.elevation or 0)
                            })
                        end
                    end
                    table.sort(sorted, function(a, b) return a.depth < b.depth end)
                    for _, entry in ipairs(sorted) do
                        if entry.obj.draw then entry.obj:draw(world) end
                    end
                end
                -- "trigger" and "light" layers are intentionally invisible in release
            end
        end

        if self.showGrid then
            self:_drawGrid(world, x1, y1, x2, y2)
        end

    camera:detach()
    love.graphics.setColor(1, 1, 1, 1)
end

function Renderer:_drawGrid(world, x1, y1, x2, y2)
    local c = self.gridColor
    love.graphics.setColor(c[1], c[2], c[3], c[4])
    local tileW, tileH = world.tileW, world.tileH
    for ty = y1, y2 do
        for tx = x1, x2 do
            local cx, cy = IsoMath.worldToISO(tx, ty, 0, tileW, tileH)
            local hw, hh = tileW * 0.5, tileH * 0.5
            love.graphics.polygon("line",
                cx,      cy,
                cx + hw, cy + hh,
                cx,      cy + tileH,
                cx - hw, cy + hh)
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8 · Editor
-- ─────────────────────────────────────────────────────────────────────────────
--[[
    Tools: pencil | erase | fill | eyedropper | rect
    Undo/Redo: command-stack pattern (each edit is a reversible command object)
    UI: built-in status bar + hover highlight. Integrate cimgui for full panels.
]]

local Editor = {}
Editor.__index = Editor

-- Command factory — captures old/new state for a single tile change
local function makeTileCmd(layer, x, y, newID, oldID)
    return {
        do_  = function() layer:setTile(x, y, newID) end,
        undo = function() layer:setTile(x, y, oldID) end,
    }
end

function Editor.new(world, camera, config)
    config = config or {}
    local e          = setmetatable({}, Editor)
    e.world          = world
    e.camera         = camera
    e.active         = false
    e.tool           = "pencil"
    e.activeLayer    = nil       -- layer name currently being edited
    e.activeTileID   = 1         -- tile to paint
    e._undoStack     = {}
    e._redoStack     = {}
    e._maxUndo       = config.maxUndo or 200
    e._painting      = false     -- held left-button drag state
    e._rectAnchor    = nil       -- {tx,ty} start of rect-draw
    e._hoverTile     = nil       -- {tx,ty} tile under mouse cursor
    return e
end

function Editor:setTool(name)
    self.tool      = name
    self._painting = false
    self._rectAnchor = nil
end

function Editor:setLayer(name)
    self.activeLayer = name
end

function Editor:_layer()
    if not self.activeLayer then return nil end
    return self.world:getLayer(self.activeLayer)
end

function Editor:_commit(cmd)
    cmd.do_()
    table.insert(self._undoStack, cmd)
    if #self._undoStack > self._maxUndo then
        table.remove(self._undoStack, 1)
    end
    self._redoStack = {}   -- new edit invalidates redo history
end

function Editor:undo()
    if #self._undoStack == 0 then return end
    local cmd = table.remove(self._undoStack)
    cmd.undo()
    table.insert(self._redoStack, cmd)
end

function Editor:redo()
    if #self._redoStack == 0 then return end
    local cmd = table.remove(self._redoStack)
    cmd.do_()
    table.insert(self._undoStack, cmd)
end

function Editor:_screenToTile(px, py)
    return self.camera:screenToTile(px, py, self.world.tileW, self.world.tileH)
end

function Editor:mousepressed(x, y, button)
    if not self.active then return end
    local layer = self:_layer()
    if not layer or layer.locked or layer.type ~= "tile" then return end
    local tx, ty = self:_screenToTile(x, y)

    if button == 1 then
        if     self.tool == "pencil"      then self._painting = true; self:_paint(layer, tx, ty)
        elseif self.tool == "erase"       then self._painting = true; self:_erase(layer, tx, ty)
        elseif self.tool == "fill"        then self:_fill(layer, tx, ty)
        elseif self.tool == "eyedropper"  then self:_pick(layer, tx, ty)
        elseif self.tool == "rect"        then self._rectAnchor = { tx, ty }
        end
    elseif button == 2 then
        -- Right-click always eyedrops
        self:_pick(layer, tx, ty)
    end
end

function Editor:mousereleased(x, y, button)
    if not self.active then return end
    if button == 1 then
        if self.tool == "rect" and self._rectAnchor then
            local layer = self:_layer()
            if layer then
                local tx, ty  = self:_screenToTile(x, y)
                local ax, ay  = self._rectAnchor[1], self._rectAnchor[2]
                local x1, x2  = math.min(ax, tx), math.max(ax, tx)
                local y1, y2  = math.min(ay, ty), math.max(ay, ty)
                -- Batch as a single undoable command via snapshot
                local before = {}
                for ry = y1, y2 do
                    for rx = x1, x2 do
                        before[ry * 1000000 + rx] = layer:getTile(rx, ry)
                    end
                end
                local id = self.activeTileID
                self:_commit({
                    do_  = function()
                        layer._grid:fill(x1, y1, x2, y2, id)
                        layer._batchDirty = true
                    end,
                    undo = function()
                        for ry = y1, y2 do
                            for rx = x1, x2 do
                                layer:setTile(rx, ry, before[ry * 1000000 + rx] or 0)
                            end
                        end
                    end
                })
            end
            self._rectAnchor = nil
        end
        self._painting = false
    end
end

function Editor:mousemoved(x, y)
    if not self.active then return end
    local tx, ty = self:_screenToTile(x, y)
    self._hoverTile = { tx, ty }
    if self._painting then
        local layer = self:_layer()
        if not layer then return end
        if     self.tool == "pencil" then self:_paint(layer, tx, ty)
        elseif self.tool == "erase"  then self:_erase(layer, tx, ty) end
    end
end

function Editor:_paint(layer, tx, ty)
    if layer:getTile(tx, ty) == self.activeTileID then return end
    self:_commit(makeTileCmd(layer, tx, ty, self.activeTileID, layer:getTile(tx, ty)))
end

function Editor:_erase(layer, tx, ty)
    if layer:getTile(tx, ty) == 0 then return end
    self:_commit(makeTileCmd(layer, tx, ty, 0, layer:getTile(tx, ty)))
end

function Editor:_fill(layer, tx, ty)
    local target = layer:getTile(tx, ty)
    local newID  = self.activeTileID
    if target == newID then return end
    -- Snapshot fill region for undo (bounded, so memory is safe)
    local snapshot = {}
    layer._grid:floodFill(tx, ty, -999999)  -- temp sentinel
    -- Collect all cells with sentinel, record old values
    for ry, row in pairs(layer._grid.data) do
        for rx, v in pairs(row) do
            if v == -999999 then
                snapshot[ry * 1000000 + rx] = { rx, ry, target }
                layer._grid:set(rx, ry, newID)
            end
        end
    end
    layer._batchDirty = true
    -- Build undo from snapshot
    table.insert(self._undoStack, {
        do_  = function()
            for _, s in pairs(snapshot) do layer:setTile(s[1], s[2], newID) end
        end,
        undo = function()
            for _, s in pairs(snapshot) do layer:setTile(s[1], s[2], s[3]) end
        end
    })
    self._redoStack = {}
end

function Editor:_pick(layer, tx, ty)
    local id = layer:getTile(tx, ty)
    if id ~= 0 then self.activeTileID = id end
end

-- Draw hover diamond + status bar
function Editor:draw(screenW, screenH)
    if not self.active then return end

    -- Hover tile highlight
    if self._hoverTile then
        local tx, ty  = self._hoverTile[1], self._hoverTile[2]
        local sx, sy  = IsoMath.worldToISO(tx, ty, 0, self.world.tileW, self.world.tileH)
        local hw, hh  = self.world.tileW * 0.5, self.world.tileH * 0.5
        local pts     = { sx, sy, sx+hw, sy+hh, sx, sy+self.world.tileH, sx-hw, sy+hh }

        self.camera:attach()
            love.graphics.setColor(1, 1, 0, 0.25)
            love.graphics.polygon("fill", pts)
            love.graphics.setColor(1, 1, 0, 0.85)
            love.graphics.polygon("line", pts)

            -- Preview rect anchor
            if self.tool == "rect" and self._rectAnchor then
                local ax, ay   = self._rectAnchor[1], self._rectAnchor[2]
                local rx1, rx2 = math.min(ax, tx), math.max(ax, tx)
                local ry1, ry2 = math.min(ay, ty), math.max(ay, ty)
                love.graphics.setColor(0.3, 0.8, 1, 0.2)
                for ry = ry1, ry2 do
                    for rx = rx1, rx2 do
                        local dx, dy = IsoMath.worldToISO(rx, ry, 0, self.world.tileW, self.world.tileH)
                        love.graphics.polygon("fill",
                            dx, dy, dx+hw, dy+hh, dx, dy+self.world.tileH, dx-hw, dy+hh)
                    end
                end
            end
        self.camera:detach()
    end

    -- Status bar
    local barH = 26
    love.graphics.setColor(0.08, 0.08, 0.10, 0.90)
    love.graphics.rectangle("fill", 0, screenH - barH, screenW, barH)
    love.graphics.setColor(0.85, 0.85, 0.85, 1)
    local info = string.format(
        "  EDITOR  |  tool: %-12s  layer: %-18s  tile: %-4d  undo: %d  redo: %d",
        self.tool,
        self.activeLayer or "(none)",
        self.activeTileID,
        #self._undoStack,
        #self._redoStack)
    if self._hoverTile then
        info = info .. string.format("  |  cursor %d, %d", self._hoverTile[1], self._hoverTile[2])
    end
    love.graphics.print(info, 0, screenH - barH + 6)
    love.graphics.setColor(1, 1, 1, 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 9 · Serializer  — Binary format  (.isob)
-- ─────────────────────────────────────────────────────────────────────────────
--[[
    Replaces the Lua-table format which hits Lua's 65,536-constants-per-function
    limit at ~21,000 tiles.  Binary packing has no such limit and is 8–10× faster
    to write/read at large scale.

    FILE LAYOUT
    ───────────────────────────────────────────────────────────────
    HEADER  (16 bytes)
      4B  magic       "ISOB"
      1B  version     uint8  (currently 2)
      2B  tileW       uint16
      2B  tileH       uint16
      2B  numLayers   uint16
      1B  propLen     uint8   length of JSON-like property blob
      4B  reserved    uint32  (zero, for future flags)
    propLen bytes of UTF-8 property string (serialize() format)

    LAYER BLOCK  (repeated numLayers times)
      1B  nameLen     uint8
      nameLen bytes   layer name (UTF-8)
      1B  typeCode    uint8  (0=tile 1=object 2=decal 3=trigger 4=light)
      1B  flags       bitfield  bit0=visible bit1=locked
      1B  opacity255  uint8   (opacity * 255, rounded)
      1B  elevation   int8    (clamped ±127)
      1B  tsLen       uint8   tileset name length
      tsLen bytes     tileset name
      4B  tileCount   uint32  (0 if non-tile layer)
    tileCount × TILE_RECORD:
      4B  x           int32
      4B  y           int32
      2B  id          uint16
    (10 bytes per tile — 1.5M tiles = ~15 MB)

    NOTE: objects are not yet binary-serialised; they round-trip through
    a compact Lua string appended after all layer blocks.
    ───────────────────────────────────────────────────────────────
]]

local Serializer = {}

local MAGIC   = "ISOB"
local VERSION = 2

local TYPE_CODE = { tile=0, object=1, decal=2, trigger=3, light=4 }
local CODE_TYPE = {}
for k,v in pairs(TYPE_CODE) do CODE_TYPE[v] = k end

-- LuaJIT / Lua 5.1 bit library (Love2D always provides this via LuaJIT)
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

-- Lua 5.1-safe loadstring wrapper (LuaJIT has both, plain 5.1 only has loadstring)
local loadstring = loadstring or load

-- ── Write helpers  (little-endian) ───────────────────────────────────────────

local function writeU8(buf, v)
    buf[#buf+1] = string.char(band(v, 0xFF))
end

local function writeU16(buf, v)
    buf[#buf+1] = string.char(band(v, 0xFF))
    buf[#buf+1] = string.char(band(rshift(v, 8), 0xFF))
end

local function writeI32(buf, v)
    -- two's complement: negatives are treated as unsigned 32-bit
    if v < 0 then v = v + 0x100000000 end
    buf[#buf+1] = string.char(band(v,           0xFF))
    buf[#buf+1] = string.char(band(rshift(v,  8), 0xFF))
    buf[#buf+1] = string.char(band(rshift(v, 16), 0xFF))
    buf[#buf+1] = string.char(band(rshift(v, 24), 0xFF))
end

local function writeU32(buf, v) writeI32(buf, v) end

local function writeStr(buf, s)
    writeU8(buf, #s)
    buf[#buf+1] = s
end

-- ── Read helpers  (little-endian) ────────────────────────────────────────────

local function readU8(s, pos)
    return s:byte(pos), pos + 1
end

local function readU16(s, pos)
    local lo, hi = s:byte(pos, pos+1)
    return bor(lo, lshift(hi, 8)), pos + 2
end

local function readI32(s, pos)
    local b0, b1, b2, b3 = s:byte(pos, pos+3)
    -- assemble as unsigned first, then sign-extend
    local v = bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24))
    -- LuaJIT bit ops return signed 32-bit; convert to Lua number
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v, pos + 4
end

local function readU32(s, pos) return readI32(s, pos) end

local function readStr(s, pos)
    local len, p = readU8(s, pos)
    return s:sub(p, p + len - 1), p + len
end

-- ── Save ─────────────────────────────────────────────────────────────────────

function Serializer.save(world, path)
    local buf = {}

    -- Header
    buf[1] = MAGIC
    writeU8 (buf, VERSION)
    writeU16(buf, world.tileW)
    writeU16(buf, world.tileH)
    writeU16(buf, #world.layers)

    local propStr = serialize(world.properties or {})
    writeU8(buf, math.min(255, #propStr))
    buf[#buf+1] = propStr:sub(1, 255)
    writeU32(buf, 0)   -- reserved

    -- Layers
    for _, layer in ipairs(world.layers) do
        writeStr(buf, layer.name)
        writeU8 (buf, TYPE_CODE[layer.type] or 0)

        local flags = bor(
            (layer.visible ~= false and 1 or 0),
            (layer.locked  and 2 or 0))
        writeU8(buf, flags)
        writeU8(buf, math.floor(math.max(0, math.min(1, layer.opacity or 1)) * 255 + 0.5))
        -- elevation as signed byte: clamp to [-127, 127]
        local elev = math.max(-127, math.min(127, math.floor(layer.elevation or 0)))
        writeU8(buf, elev < 0 and (elev + 256) or elev)
        writeStr(buf, layer.tilesetName or "")

        if layer._grid then
            -- Count first (uint32 tile count written before tile records)
            local tileCount = 0
            for _, row in pairs(layer._grid.data) do
                for _ in pairs(row) do tileCount = tileCount + 1 end
            end
            writeU32(buf, tileCount)

            for y, row in pairs(layer._grid.data) do
                for x, id in pairs(row) do
                    writeI32(buf, x)
                    writeI32(buf, y)
                    writeU16(buf, id)
                end
            end
        else
            writeU32(buf, 0)
        end
    end

    -- Object payload (compact Lua for now; future: binary)
    local objBlocks = {}
    for _, layer in ipairs(world.layers) do
        if layer.objects and #layer.objects > 0 then
            local serializedObjs = {}
            for _, obj in ipairs(layer.objects) do
                local o = {}
                for k, v in pairs(obj) do
                    if type(v) ~= "function" then o[k] = v end
                end
                table.insert(serializedObjs, serialize(o))
            end
            table.insert(objBlocks, string.format("%q={%s}",
                layer.name, table.concat(serializedObjs, ",")))
        end
    end
    local objStr = "{" .. table.concat(objBlocks, ",") .. "}"
    writeU32(buf, #objStr)
    buf[#buf+1] = objStr

    local data   = table.concat(buf)
    local ok, e  = love.filesystem.write(path, data)
    return ok, e
end

-- ── Load ─────────────────────────────────────────────────────────────────────

function Serializer.load(world, path)
    local info = love.filesystem.getInfo(path)
    if not info then return false, "File not found: " .. path end

    local data, err = love.filesystem.read("data", path)
    if not data then return false, "Cannot read: " .. tostring(err) end

    -- Convert FileData to string for byte operations
    local s   = data:getString()
    local pos = 1

    -- Magic
    local magic = s:sub(pos, pos+3); pos = pos + 4
    if magic ~= MAGIC then
        -- Fallback: try legacy Lua-table format (v1 files)
        local fn, ferr = love.filesystem.load(path)
        if not fn then return false, "Not an ISOB file and Lua parse failed: " .. tostring(ferr) end
        local ok2, tbl = pcall(fn)
        if not ok2 then return false, "Legacy parse error: " .. tostring(tbl) end
        return Serializer._loadLegacy(world, tbl)
    end

    -- Version
    local version; version, pos = readU8(s, pos)
    if version > VERSION then
        return false, string.format("Map version %d requires a newer isomap.lua (this is v%d)", version, VERSION)
    end

    -- Header fields
    local tileW, tileH, numLayers
    tileW,     pos = readU16(s, pos)
    tileH,     pos = readU16(s, pos)
    numLayers, pos = readU16(s, pos)

    local propLen; propLen, pos = readU8(s, pos)
    local propStr = s:sub(pos, pos + propLen - 1); pos = pos + propLen
    pos = pos + 4  -- reserved uint32

    world.layers    = {}
    world._layerMap = {}
    world.tileW     = tileW
    world.tileH     = tileH

    -- Parse property string back to table
    if propStr and #propStr > 2 then
        local fn2 = loadstring("return " .. propStr)
        if fn2 then
            local ok2, props = pcall(fn2)
            world.properties = ok2 and props or {}
        end
    end

    -- Layers
    for _ = 1, numLayers do
        local name, typeCode, flags, opacity255, elevByte, tsName
        name,      pos = readStr(s, pos)
        typeCode,  pos = readU8 (s, pos)
        flags,     pos = readU8 (s, pos)
        opacity255,pos = readU8 (s, pos)
        elevByte,  pos = readU8 (s, pos)

        local elev = elevByte > 127 and (elevByte - 256) or elevByte
        tsName, pos = readStr(s, pos)

        local layer = world:addLayer(name, CODE_TYPE[typeCode] or "tile", {
            visible   = band(flags, 1) ~= 0,
            locked    = band(flags, 2) ~= 0,
            opacity   = opacity255 / 255,
            elevation = elev,
            tileset   = tsName ~= "" and tsName or nil,
        })

        local tileCount; tileCount, pos = readU32(s, pos)
        if tileCount > 0 and layer._grid then
            for _ = 1, tileCount do
                local tx, ty, id
                tx,  pos = readI32(s, pos)
                ty,  pos = readI32(s, pos)
                id,  pos = readU16(s, pos)
                layer._grid:setRaw(tx, ty, id)   -- skip per-cell dirty; set once below
            end
            layer._grid.dirty = true
            layer._batchDirty = true
        end
    end

    -- Object payload
    if pos <= #s then
        local objPayloadLen; objPayloadLen, pos = readU32(s, pos)
        if objPayloadLen > 0 then
            local objStr = s:sub(pos, pos + objPayloadLen - 1)
            local fn3 = loadstring("return " .. objStr)
            if fn3 then
                local ok3, objData = pcall(fn3)
                if ok3 then
                    for layerName, objs in pairs(objData) do
                        local layer = world:getLayer(layerName)
                        if layer then
                            for _, obj in ipairs(objs) do
                                table.insert(layer.objects, obj)
                            end
                        end
                    end
                end
            end
        end
    end

    return true
end

-- Legacy v1 Lua-table loader (handles old .lua saves, no size limit workaround —
-- if they were too large to load originally they'll still fail, but small v1 maps work)
function Serializer._loadLegacy(world, data)
    if (data.version or 0) > 1 then
        return false, "Legacy map version unsupported"
    end
    world.layers     = {}
    world._layerMap  = {}
    world.tileW      = data.tileWidth  or world.tileW
    world.tileH      = data.tileHeight or world.tileH
    world.properties = data.properties or {}
    for _, ld in ipairs(data.layers or {}) do
        local layer = world:addLayer(ld.name, ld.type, {
            visible   = ld.visible,
            locked    = ld.locked,
            opacity   = ld.opacity,
            elevation = ld.elevation,
            tileset   = ld.tileset,
        })
        if ld.tiles then
            for _, t in ipairs(ld.tiles) do
                layer._grid:set(t[1], t[2], t[3])
            end
            layer._batchDirty = true
        end
        if ld.objects then
            for _, obj in ipairs(ld.objects) do
                table.insert(layer.objects, obj)
            end
        end
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

function IsoMap.newWorld(config)
    local w = World.new(config)
    w.save  = function(self, path) return Serializer.save(self, path) end
    w.load  = function(self, path) return Serializer.load(self, path) end
    return w
end

function IsoMap.newTileset(name, image, config)
    return Tileset.new(name, image, config)
end

function IsoMap.newCamera(config)
    return Camera.new(config)
end

function IsoMap.newRenderer(config)
    return Renderer.new(config)
end

function IsoMap.newEditor(world, camera, config)
    return Editor.new(world, camera, config)
end

-- Expose internals for power users
IsoMap.Math       = IsoMath
IsoMap.SparseGrid = SparseGrid

return IsoMap