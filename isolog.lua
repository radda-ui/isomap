local IsoLog = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────────────────────────────────────
local CFG = {
    visible         = true,
    historySize     = 128,       -- frames kept for sparkline charts
    warnBatchCap    = 3000,      -- warn when SpriteBatch fills above this
    warnFrameMs     = 16.67,     -- warn when a frame exceeds 60fps budget
    warnUndoDepth   = 150,       -- warn when undo stack is deep
    autoFlushFrames = 300,       -- write session log every N frames
    overlayX        = 8,
    overlayY        = 40,
    overlayW        = 420,
    font            = nil,       -- set to a Love2D font or nil for default
}

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────────────────────────────────────
local S = {
    -- references to patched objects
    world    = nil,
    renderer = nil,
    editor   = nil,
    camera   = nil,

    -- per-frame counters (reset each frame)
    frame = {
        tilesConsidered  = 0,   -- tiles in frustum rect before culling
        tilesDrawn       = 0,   -- tiles actually added to SpriteBatch
        batchRebuildCount= 0,   -- how many layers rebuilt their SpriteBatch
        batchMaxSize     = 0,   -- largest single batch this frame
        drawCalls        = 0,   -- love.graphics draw calls (estimated)
        objectsDrawn     = 0,
        frustumW         = 0,   -- frustum width  in tiles
        frustumH         = 0,   -- frustum height in tiles
    },

    -- totals (lifetime)
    total = {
        edits            = 0,
        undos            = 0,
        redos            = 0,
        saves            = 0,
        loads            = 0,
        frames           = 0,
        floodFills       = 0,
        batchRebuilds    = 0,
    },

    -- per-layer stats
    layers = {},    -- name → { rebuilds, tilesDrawn, batchSize, dirty }

    -- performance history (ring buffers)
    hist = {
        frameMs         = {},
        tilesDrawn      = {},
        batchRebuild    = {},
    },
    histPos = 0,

    -- one-time measurements
    map = {
        totalNonEmpty   = 0,   -- recomputed on demand
        layerCount      = 0,
        tilesetCount    = 0,
        objectCount     = 0,
        sparseByteEst   = 0,   -- rough memory estimate
    },

    -- event log  (capped ring buffer)
    eventLog  = {},
    eventMax  = 200,

    -- session file
    sessionFile = nil,
    sessionPath = nil,
    framesSinceFlush = 0,

    -- timing
    _frameStart = 0,
    _lastFrameMs = 0,

    -- warnings this frame
    warnings = {},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- INTERNAL HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

local function ts()
    return string.format("[%.3f]", love.timer.getTime())
end

local function pushEvent(level, msg)
    local entry = ts() .. " [" .. level .. "] " .. msg
    table.insert(S.eventLog, entry)
    if #S.eventLog > S.eventMax then table.remove(S.eventLog, 1) end
    if S.sessionFile then S.sessionFile:write(entry .. "\n") end
    if level == "ERROR" or level == "WARN" then
        table.insert(S.warnings, msg)
    end
end

local function info(msg)  pushEvent("INFO",  msg) end
local function warn(msg)  pushEvent("WARN",  msg) end
local function err(msg)   pushEvent("ERROR", msg) end

local function pushHist(buf, val)
    table.insert(buf, val)
    if #buf > CFG.historySize then table.remove(buf, 1) end
end

local function countSparse(grid)
    if not grid then return 0 end
    local n = 0
    for _, row in pairs(grid.data) do
        for _ in pairs(row) do n = n + 1 end
    end
    return n
end

-- Approximate memory used by sparse grid (rough: 80 bytes per entry on LuaJIT)
local function estimateSparseBytes(grid)
    return countSparse(grid) * 80
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MAP SNAPSHOT  (called on attach and on demand)
-- ─────────────────────────────────────────────────────────────────────────────

local function snapMap()
    if not S.world then return end
    local w = S.world
    local totalTiles, totalBytes, totalObjects = 0, 0, 0

    S.layers = {}
    for _, layer in ipairs(w.layers) do
        local n = layer._grid and countSparse(layer._grid) or 0
        local b = layer._grid and estimateSparseBytes(layer._grid) or 0
        local o = layer.objects and #layer.objects or 0
        totalTiles   = totalTiles   + n
        totalBytes   = totalBytes   + b
        totalObjects = totalObjects + o
        S.layers[layer.name] = S.layers[layer.name] or {}
        S.layers[layer.name].tileCount = n
        S.layers[layer.name].memBytes  = b
        S.layers[layer.name].objCount  = o
    end

    S.map.totalNonEmpty  = totalTiles
    S.map.sparseByteEst  = totalBytes
    S.map.layerCount     = #w.layers
    S.map.tilesetCount   = 0
    for _ in pairs(w.tilesets) do S.map.tilesetCount = S.map.tilesetCount + 1 end
    S.map.objectCount    = totalObjects

    info(string.format("Map snapshot: %d tiles across %d layers (~%.1f MB sparse)",
        totalTiles, #w.layers, totalBytes / 1048576))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PATCH HELPERS  — wrap methods non-destructively
-- ─────────────────────────────────────────────────────────────────────────────

local function wrap(obj, method, before, after)
    local original = obj[method]
    obj[method] = function(self, ...)
        if before then before(self, ...) end
        local r1,r2,r3,r4 = original(self, ...)
        if after then after(self, r1, ...) end
        return r1,r2,r3,r4
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PATCH: Renderer
-- ─────────────────────────────────────────────────────────────────────────────

local function patchRenderer(renderer)

    -- _visibleRange: capture frustum dimensions
    local origVR = renderer._visibleRange
    renderer._visibleRange = function(self, world, camera, sw, sh)
        local x1,y1,x2,y2 = origVR(self, world, camera, sw, sh)
        S.frame.frustumW = (x2 - x1)
        S.frame.frustumH = (y2 - y1)
        S.frame.tilesConsidered = S.frame.tilesConsidered +
            math.max(0, S.frame.frustumW) * math.max(0, S.frame.frustumH)
        return x1,y1,x2,y2
    end

    -- _rebuildBatch: count rebuilds, batch sizes, tiles drawn
    local origRB = renderer._rebuildBatch
    renderer._rebuildBatch = function(self, layer, world, x1, y1, x2, y2)
        local before = layer._batchDirty
        origRB(self, layer, world, x1, y1, x2, y2)

        if before then   -- was dirty = actually rebuilt
            S.frame.batchRebuildCount = S.frame.batchRebuildCount + 1
            S.total.batchRebuilds     = S.total.batchRebuilds + 1

            local count = 0
            if layer._batch then count = layer._batch:getCount() end

            S.frame.tilesDrawn  = S.frame.tilesDrawn  + count
            S.frame.drawCalls   = S.frame.drawCalls   + 1
            S.frame.batchMaxSize = math.max(S.frame.batchMaxSize, count)

            -- Per-layer stats
            local ls = S.layers[layer.name] or {}
            ls.rebuilds    = (ls.rebuilds or 0) + 1
            ls.tilesDrawn  = count
            ls.batchSize   = count
            S.layers[layer.name] = ls

            if count >= CFG.warnBatchCap then
                warn(string.format("Layer '%s' SpriteBatch near capacity: %d sprites (cap ~4096)",
                    layer.name, count))
            end
        end
    end

    info("Renderer patched.")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PATCH: Editor
-- ─────────────────────────────────────────────────────────────────────────────

local function patchEditor(editor)

    wrap(editor, "_commit", nil, function(self, cmd)
        S.total.edits = S.total.edits + 1
        if #self._undoStack >= CFG.warnUndoDepth then
            warn(string.format("Undo stack deep: %d entries (memory pressure)", #self._undoStack))
        end
    end)

    wrap(editor, "undo", nil, function(self)
        S.total.undos = S.total.undos + 1
        info(string.format("Undo #%d  (stack now %d)", S.total.undos, #self._undoStack))
    end)

    wrap(editor, "redo", nil, function(self)
        S.total.redos = S.total.redos + 1
        info(string.format("Redo #%d  (stack now %d)", S.total.redos, #self._undoStack))
    end)

    wrap(editor, "_fill", nil, function(self)
        S.total.floodFills = S.total.floodFills + 1
        info(string.format("FloodFill #%d at layer '%s'", S.total.floodFills, self.activeLayer or "?"))
    end)

    info("Editor patched.")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PATCH: World  (save / load)
-- ─────────────────────────────────────────────────────────────────────────────

local function patchWorld(world)

    local origSave = world.save
    world.save = function(self, path)
        local t0 = love.timer.getTime()
        local ok, e = origSave(self, path)
        local ms = (love.timer.getTime() - t0) * 1000

        S.total.saves = S.total.saves + 1
        local info_msg = string.format("Save '%s'  %s  %.1f ms", path, ok and "OK" or "FAIL", ms)
        if ok then info(info_msg) else err(info_msg .. " — " .. tostring(e)) end

        if ms > 500 then
            warn(string.format("Save took %.0f ms — consider RLE or binary format at this map size", ms))
        end

        -- Capture file size
        local finfo = love.filesystem.getInfo(path)
        if finfo then
            info(string.format("Save file size: %.1f KB", finfo.size / 1024))
            if finfo.size > 5 * 1024 * 1024 then
                warn("Save file >5 MB — strongly recommend switching to binary / RLE encoding")
            end
        end

        return ok, e
    end

    local origLoad = world.load
    world.load = function(self, path)
        local t0 = love.timer.getTime()
        local ok, e = origLoad(self, path)
        local ms = (love.timer.getTime() - t0) * 1000

        S.total.loads = S.total.loads + 1
        local msg = string.format("Load '%s'  %s  %.1f ms", path, ok and "OK" or "FAIL", ms)
        if ok then info(msg); snapMap() else err(msg .. " — " .. tostring(e)) end

        if ms > 1000 then
            warn(string.format("Load took %.0f ms — Lua table parsing is bottleneck; use binary chunk loader", ms))
        end

        return ok, e
    end

    info("World patched.")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PATCH: SparseGrid  (monitor floodFill hit limit)
-- ─────────────────────────────────────────────────────────────────────────────

local function patchSparseGrid(IsoMap)
    local SG = IsoMap and IsoMap.SparseGrid
    if not SG then
        warn("IsoMap.SparseGrid not exposed — pass IsoMap module to IsoLog.attach() to patch it")
        return
    end

    local origFF = SG.floodFill
    SG.floodFill = function(self, startX, startY, newVal, limit)
        limit = limit or 5000
        local before = countSparse(self)
        origFF(self, startX, startY, newVal, limit)
        local after  = countSparse(self)
        local changed = math.abs(after - before)
        if changed >= limit then
            warn(string.format("FloodFill HIT cell limit (%d) — map may be open/unbounded", limit))
        end
        info(string.format("FloodFill changed %d cells (limit %d)", changed, limit))
    end

    info("SparseGrid.floodFill patched.")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SPARKLINE RENDERER  (ASCII / pixel bar chart in overlay)
-- ─────────────────────────────────────────────────────────────────────────────

local function sparkline(buf, x, y, w, h, color, maxVal)
    if #buf == 0 then return end
    maxVal = maxVal or 0
    for _, v in ipairs(buf) do if v > maxVal then maxVal = v end end
    if maxVal == 0 then maxVal = 1 end

    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", x, y, w, h)

    love.graphics.setColor(color[1], color[2], color[3], 0.85)
    local n   = #buf
    local barW = w / n
    for i, v in ipairs(buf) do
        local bh = math.max(1, (v / maxVal) * h)
        love.graphics.rectangle("fill", x + (i-1)*barW, y + h - bh, math.max(1, barW-1), bh)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- OVERLAY DRAW
-- ─────────────────────────────────────────────────────────────────────────────

local function drawOverlay()
    if not CFG.visible then return end

    local f    = S.frame
    local tot  = S.total
    local m    = S.map
    local x, y = CFG.overlayX, CFG.overlayY
    local w    = CFG.overlayW
    local lh   = 15   -- line height

    -- Background panel
    love.graphics.setColor(0.05, 0.05, 0.08, 0.88)
    love.graphics.rectangle("fill", x-4, y-4, w+8, 400)
    love.graphics.setColor(0.25, 0.25, 0.30, 1)
    love.graphics.rectangle("line", x-4, y-4, w+8, 400)

    local function line(text, col)
        col = col or {0.85, 0.85, 0.85}
        love.graphics.setColor(col[1], col[2], col[3], 1)
        love.graphics.print(text, x, y)
        y = y + lh
    end
    local function sep()
        love.graphics.setColor(0.25, 0.25, 0.30, 0.7)
        love.graphics.line(x, y, x+w, y)
        y = y + 4
    end

    -- Title
    line("▶ ISOMAP DIAGNOSTICS  (F1 toggle)", {0.4, 0.8, 1})
    sep()

    -- Frame perf
    local fpsColor = S._lastFrameMs > CFG.warnFrameMs and {1,0.4,0.2} or {0.4,1,0.5}
    line(string.format("FPS: %d   frame: %.2f ms   zoom: %.2fx",
        love.timer.getFPS(), S._lastFrameMs, S.camera and S.camera.zoom or 0), fpsColor)

    -- Renderer
    sep()
    line("── RENDERER", {0.7, 0.9, 0.7})
    line(string.format("  frustum:      %d × %d tiles  (%d considered)",
        f.frustumW, f.frustumH, f.tilesConsidered))
    line(string.format("  tiles drawn:  %d   batches rebuilt: %d   max batch: %d",
        f.tilesDrawn, f.batchRebuildCount, f.batchMaxSize))

    local batchColor = {0.85,0.85,0.85}
    _ = batchColor -- suppress unused warning

    -- Map
    sep()
    line("── MAP", {0.7, 0.9, 0.7})
    line(string.format("  total tiles:  %d   layers: %d   tilesets: %d   objects: %d",
        m.totalNonEmpty, m.layerCount, m.tilesetCount, m.objectCount))
    line(string.format("  sparse est:   %.2f MB", m.sparseByteEst / 1048576))

    -- Per-layer table
    sep()
    line("  Layer               Tiles       Mem KB    Batch   Rebuilds", {0.6,0.6,0.7})
    for name, ls in pairs(S.layers) do
        local flag = (ls.batchSize or 0) >= CFG.warnBatchCap and " ⚠" or ""
        line(string.format("  %-18s  %-10d  %-8.1f  %-6d  %d%s",
            name:sub(1,18),
            ls.tileCount  or 0,
            (ls.memBytes  or 0) / 1024,
            ls.batchSize  or 0,
            ls.rebuilds   or 0,
            flag))
    end

    -- Editor
    sep()
    line("── EDITOR", {0.7, 0.9, 0.7})
    if S.editor then
        local e = S.editor
        line(string.format("  tool: %-12s  layer: %-14s  tileID: %d",
            e.tool or "?", e.activeLayer or "?", e.activeTileID or 0))
        local undoColor = #e._undoStack >= CFG.warnUndoDepth and {1,0.5,0.2} or {0.85,0.85,0.85}
        line(string.format("  undo: %d   redo: %d   edits: %d   fills: %d   saves: %d",
            #e._undoStack, #e._redoStack, tot.edits, tot.floodFills, tot.saves), undoColor)
    end

    -- Camera
    sep()
    line("── CAMERA", {0.7, 0.9, 0.7})
    if S.camera then
        local c = S.camera
        line(string.format("  pos: (%.0f, %.0f)   zoom: %.3f   following: %s",
            c.x, c.y, c.zoom, c._target and "YES" or "no"))
    end

    -- Warnings
    if #S.warnings > 0 then
        sep()
        line("── WARNINGS", {1, 0.4, 0.2})
        for i = math.max(1, #S.warnings-3), #S.warnings do
            line("  " .. (S.warnings[i] or ""), {1, 0.6, 0.3})
        end
    end

    -- Sparklines
    sep()
    local sy = y + 2
    sparkline(S.hist.frameMs,      x,       sy, 130, 32, {0.4,1,0.5},   CFG.warnFrameMs * 2)
    sparkline(S.hist.tilesDrawn,   x + 140, sy, 130, 32, {0.4,0.7,1},   nil)
    sparkline(S.hist.batchRebuild, x + 280, sy, 130, 32, {1,0.7,0.3},   nil)
    love.graphics.setColor(0.5,0.5,0.5,0.7)
    love.graphics.print("frame ms",    x,       sy + 33)
    love.graphics.print("tiles drawn", x + 140, sy + 33)
    love.graphics.print("rebuilds",    x + 280, sy + 33)

    love.graphics.setColor(1, 1, 1, 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DUMP  — full report to console + session file
-- ─────────────────────────────────────────────────────────────────────────────

function IsoLog.dump()
    local lines = {
        "═══════════════════════════════════════════════════════════════",
        "  ISOMAP DIAGNOSTIC DUMP  " .. os.date("%Y-%m-%d %H:%M:%S"),
        "═══════════════════════════════════════════════════════════════",
        string.format("  Frames logged:     %d",    S.total.frames),
        string.format("  Total edits:       %d",    S.total.edits),
        string.format("  Undos / Redos:     %d / %d", S.total.undos, S.total.redos),
        string.format("  Flood fills:       %d",    S.total.floodFills),
        string.format("  Batch rebuilds:    %d",    S.total.batchRebuilds),
        string.format("  Saves / Loads:     %d / %d", S.total.saves, S.total.loads),
        "───────────────────────────────────────────────────────────────",
        string.format("  Map tiles (total): %d",    S.map.totalNonEmpty),
        string.format("  Sparse mem est:    %.2f MB", S.map.sparseByteEst / 1048576),
        string.format("  Layers:            %d",    S.map.layerCount),
        string.format("  Tilesets:          %d",    S.map.tilesetCount),
        "───────────────────────────────────────────────────────────────",
    }

    -- Frame timing stats from history
    if #S.hist.frameMs > 0 then
        local sum, mx = 0, 0
        for _, v in ipairs(S.hist.frameMs) do
            sum = sum + v
            if v > mx then mx = v end
        end
        local avg = sum / #S.hist.frameMs
        table.insert(lines, string.format("  Avg frame ms:      %.2f   peak: %.2f", avg, mx))
        if avg > CFG.warnFrameMs then
            table.insert(lines, "  ⚠ BELOW 60 FPS average — profile renderer._rebuildBatch and SpriteBatch cap")
        end
    end

    -- Per-layer summary
    table.insert(lines, "───────────────────────────────────────────────────────────────")
    table.insert(lines, "  Per-layer:")
    for name, ls in pairs(S.layers) do
        table.insert(lines, string.format(
            "    %-20s tiles=%-10d mem=%-8.1fKB  batch=%-6d rebuilds=%d",
            name, ls.tileCount or 0, (ls.memBytes or 0)/1024,
            ls.batchSize or 0, ls.rebuilds or 0))
    end

    -- Recommendations
    table.insert(lines, "───────────────────────────────────────────────────────────────")
    table.insert(lines, "  RECOMMENDATIONS:")
    local hasRec = false

    if S.map.totalNonEmpty > 1000000 then
        table.insert(lines, "  • Map >1M tiles: consider chunk-based streaming (16×16 chunks, load on demand)")
        hasRec = true
    end

    for name, ls in pairs(S.layers) do
        -- Batch cap: dynamic sizing is in v1.1+, only warn if logger sees a rebuild
        -- every single frame (camMoved every frame = expected, but count > frames/2 is suspect)
        if (ls.rebuilds or 0) > S.total.frames * 0.9 and S.total.frames > 120 then
            table.insert(lines, "  • Layer '" .. name .. "': rebuilding >90% of frames — camera may be jittering or follow() is micro-moving each frame")
            hasRec = true
        end
    end

    if S.total.floodFills > 0 then
        table.insert(lines, "  • FloodFill used " .. S.total.floodFills .. "x — default cell limit is 5000; tune via SparseGrid:floodFill(x,y,v,limit)")
        hasRec = true
    end

    if S.total.saves > 0 then
        -- Check if avg frame time spiked during saves (heuristic: peak > 3x avg)
        local avg = 0
        if #S.hist.frameMs > 0 then
            for _, v in ipairs(S.hist.frameMs) do avg = avg + v end
            avg = avg / #S.hist.frameMs
        end
        if avg > 50 then
            table.insert(lines, "  • Avg frame >50ms during session — profile iterRect call count vs visible tile count")
            hasRec = true
        end
    end

    if not hasRec then
        table.insert(lines, "  (none — system looks healthy)")
    end

    table.insert(lines, "═══════════════════════════════════════════════════════════════")

    local report = table.concat(lines, "\n")
    print(report)

    if S.sessionFile then
        S.sessionFile:write(report .. "\n")
        S.sessionFile:flush()
    end

    return report
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

function IsoLog.attach(world, renderer, renderer2, camera2, isoMapModule)
    -- Accept either (world, renderer, editor, camera, IsoMap)
    -- or positional from user
    S.world    = world
    S.renderer = renderer
    S.editor   = renderer2   -- 3rd arg is editor
    S.camera   = camera2     -- 4th arg is camera

    patchRenderer(renderer)
    patchEditor(S.editor)
    patchWorld(world)
    if isoMapModule then patchSparseGrid(isoMapModule) end

    snapMap()
    info("IsoLog attached. Press F1 to toggle overlay, call IsoLog.dump() for full report.")
end

function IsoLog.startSession(path)
    local f, err2 = io.open(path, "w")
    if not f then
        warn("Cannot open session log: " .. tostring(err2))
        return false
    end
    S.sessionFile = f
    S.sessionPath = path
    f:write("IsoMap session log  " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
    info("Session log started: " .. path)
    return true
end

function IsoLog.stopSession()
    if S.sessionFile then
        IsoLog.dump()
        S.sessionFile:close()
        S.sessionFile = nil
        info("Session log closed: " .. tostring(S.sessionPath))
    end
end

function IsoLog.toggle()
    CFG.visible = not CFG.visible
end

function IsoLog.snapMap()
    snapMap()
end

function IsoLog.update(dt)
    -- Frame start timing
    if S._frameStart > 0 then
        S._lastFrameMs = (love.timer.getTime() - S._frameStart) * 1000
        pushHist(S.hist.frameMs,      S._lastFrameMs)
        pushHist(S.hist.tilesDrawn,   S.frame.tilesDrawn)
        pushHist(S.hist.batchRebuild, S.frame.batchRebuildCount)

        if S._lastFrameMs > CFG.warnFrameMs then
            -- Only warn every 60 frames to avoid log spam
            if S.total.frames % 60 == 0 then
                warn(string.format("Frame spike: %.1f ms  (%.0f fps)",
                    S._lastFrameMs, 1000 / math.max(0.001, S._lastFrameMs)))
            end
        end
    end

    -- Reset per-frame counters
    S.frame.tilesConsidered   = 0
    S.frame.tilesDrawn        = 0
    S.frame.batchRebuildCount = 0
    S.frame.batchMaxSize      = 0
    S.frame.drawCalls         = 0
    S.frame.objectsDrawn      = 0
    S.warnings                = {}

    S.total.frames  = S.total.frames + 1
    S._frameStart   = love.timer.getTime()

    -- Auto-flush session log
    S.framesSinceFlush = S.framesSinceFlush + 1
    if S.sessionFile and S.framesSinceFlush >= CFG.autoFlushFrames then
        S.sessionFile:flush()
        S.framesSinceFlush = 0
    end
end

function IsoLog.draw()
    drawOverlay()
end

-- Allow tweaking config at runtime
function IsoLog.configure(opts)
    for k, v in pairs(opts) do CFG[k] = v end
end

-- Expose raw state for custom tooling
function IsoLog.getState() return S end
function IsoLog.getConfig() return CFG end

return IsoLog