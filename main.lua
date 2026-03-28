-- =============================================================================
--  main.lua  ·  IsoMap + imlove EditorUI demo
-- =============================================================================
io.stdout:setvbuf("no")
local IsoMap   = require "isomap"
local EditorUI = require "editor_ui"

local world, camera, renderer, editor, ui

-- ─── love.load ───────────────────────────────────────────────────────────────
function love.load()
    local tileW, tileH = 64, 32

    -- Build a demo tileset atlas (replace with your real PNG)
    local tileColors = {
        { 0.35, 0.65, 0.25 },  -- 1  grass
        { 0.55, 0.45, 0.28 },  -- 2  dirt
        { 0.50, 0.50, 0.58 },  -- 3  stone
        { 0.18, 0.38, 0.75 },  -- 4  water
        { 0.72, 0.62, 0.40 },  -- 5  sand
        { 0.28, 0.55, 0.28 },  -- 6  deep-grass
        { 0.80, 0.30, 0.20 },  -- 7  lava
        { 0.90, 0.90, 0.90 },  -- 8  snow
    }
    local atlasW = tileW * #tileColors
    local atlas  = love.graphics.newCanvas(atlasW, tileH)
    love.graphics.setCanvas(atlas)
    love.graphics.clear(0, 0, 0, 0)
    for i, col in ipairs(tileColors) do
        local ox = (i - 1) * tileW
        local hw, hh = tileW * 0.5, tileH * 0.5
        love.graphics.setColor(col[1], col[2], col[3])
        love.graphics.polygon("fill", ox+hw,0, ox+tileW,hh, ox+hw,tileH, ox,hh)
        love.graphics.setColor(col[1]*.55, col[2]*.55, col[3]*.55)
        love.graphics.polygon("fill", ox+hw,tileH*.55, ox+tileW,hh*1.1, ox+tileW,hh+tileH*.15, ox+hw,tileH)
        love.graphics.setColor(col[1]*.45, col[2]*.45, col[3]*.45, 0.7)
        love.graphics.polygon("line", ox+hw,0, ox+tileW,hh, ox+hw,tileH, ox,hh)
    end
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1, 1)

    -- World
    world = IsoMap.newWorld({ tileWidth = tileW, tileHeight = tileH })
    local tileset = IsoMap.newTileset("tiles", atlas, { tileWidth=tileW, tileHeight=tileH })
    world:registerTileset(tileset)

    world:addLayer("ground",   "tile",    { tileset = "tiles" })
    world:addLayer("detail",   "tile",    { tileset = "tiles" })
    world:addLayer("walls",    "tile",    { tileset = "tiles", elevation = 1 })
    world:addLayer("objects",  "object",  {})
    world:addLayer("triggers", "trigger", { visible = false })

    -- Starter island
    for y = -8, 8 do
        for x = -8, 8 do
            local dist = math.sqrt(x*x + y*y)
            local id = 1
            if     dist > 7   then id = 4
            elseif dist > 6   then id = 5
            elseif dist > 4.5 then id = 2 end
            world:setTile("ground", x, y, id)
        end
    end
    for y = -2, 2 do
        for x = -2, 2 do
            if math.abs(x) + math.abs(y) <= 2 then
                world:setTile("detail", x, y, 3)
            end
        end
    end

    -- Camera
    local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()
    camera = IsoMap.newCamera({ x = sw * 0.5, y = sh * 0.35, zoom = 1 })

    -- Renderer
    renderer = IsoMap.newRenderer({ showGrid = false })

    -- Editor
    editor = IsoMap.newEditor(world, camera)
    editor.active       = true
    editor.activeLayer  = "ground"
    editor.activeTileID = 1

    -- UI
    ui = EditorUI.new(world, renderer, editor, camera)

    love.window.setTitle("IsoMap Editor")
end

-- ─── love.update ─────────────────────────────────────────────────────────────
function love.update(dt)
    renderer:update(dt)
    camera:update(dt, love.graphics.getWidth(), love.graphics.getHeight())
    ui:update(dt)

    -- Camera pan — only when UI does not own the mouse
    if not ui:wantMouse() then
        local speed = 320 / camera.zoom
        if love.keyboard.isDown("a","left")  then camera:pan( speed*dt, 0)  end
        if love.keyboard.isDown("d","right") then camera:pan(-speed*dt, 0)  end
        if love.keyboard.isDown("w","up")    then camera:pan(0,  speed*dt)  end
        if love.keyboard.isDown("s","down")  then camera:pan(0, -speed*dt)  end
    end
    -- collectgarbage("step", 1)
end
count = 0
-- ─── love.draw ───────────────────────────────────────────────────────────────
function love.draw()
    love.graphics.clear(0.12, 0.13, 0.18, 1)
    local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()

    renderer:draw(world, camera, sw, sh)

    -- Hover tile highlight (no built-in status bar call)
    if editor.active and editor._hoverTile then
        local tx, ty = editor._hoverTile[1], editor._hoverTile[2]
        local sx, sy = IsoMap.Math.worldToISO(tx, ty, 0, world.tileW, world.tileH)
        local hw, hh = world.tileW * 0.5, world.tileH * 0.5
        local pts    = { sx, sy, sx+hw, sy+hh, sx, sy+world.tileH, sx-hw, sy+hh }
        camera:attach()
            love.graphics.setColor(1, 1, 0, 0.22)
            love.graphics.polygon("fill", pts)
            love.graphics.setColor(1, 1, 0, 0.80)
            love.graphics.polygon("line", pts)
        camera:detach()
    end

    -- imlove UI on top
    ui:draw()
    -- love.graphics.print("Mem: " .. collectgarbage("count"), 400, 10)
    -- print("frame".. count .."  Mem: " .. collectgarbage("count"))
    -- count = count+1
end

-- ─── Input ───────────────────────────────────────────────────────────────────
function love.mousepressed(x, y, button)
    ui:mousepressed(x, y, button)
    if not ui:wantMouse() then
        editor:mousepressed(x, y, button)
    end
end

function love.mousereleased(x, y, button)
    ui:mousereleased(x, y, button)
    editor:mousereleased(x, y, button)
end

function love.mousemoved(x, y)
    if not ui:wantMouse() then
        editor:mousemoved(x, y)
    end
end

function love.wheelmoved(x, y)
    ui:wheelmoved(x, y)
    if not ui:wantMouse() then
        local mx, my = love.mouse.getPosition()
        if     y > 0 then camera:zoomToPoint(1.2,   mx, my)
        elseif y < 0 then camera:zoomToPoint(1/1.2, mx, my) end
    end
end

function love.keypressed(key, scancode)
    ui:keypressed(key, scancode)
    if not ui:handleKey(key) then
        if key == "escape" then love.event.quit() end
    end
end

function love.textinput(t)
    ui:textinput(t)
end
function love.resize(w,h)
    ui:resize(w,h)
end