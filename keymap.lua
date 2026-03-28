-- =============================================================================
--  keymap.lua  ·  Configurable keybinding system for the IsoMap editor
-- =============================================================================
--  QUICK START
--  ─────────────────────────────────────────────────────────────────────────────
--  local Keymap = require "keymap"
--  km = Keymap.new()                   -- auto-loads "keybindings.lua" if present
--
--  -- in love.keypressed:
--  km:onKeyPressed(key)                -- returns true if rebind mode consumed it
--
--  -- in love.update (call FIRST, before anything else):
--  km:beginFrame()
--  if km:down("cam_left") then camera:pan(speed*dt, 0) end
--
--  -- anywhere:
--  if km:pressed("edit_undo") then editor:undo() end
--
--  -- display binding in UI:
--  km:display("edit_undo")             -- "Ctrl+Z"
--  km:display("cam_left")             -- "A / ←"
--  km:displaySlot("cam_left", 1)      -- "A"   (one slot only)
--
--  -- rebinding (wire to a UI button click):
--  km:beginRebind("tool_pencil", 1)   -- slot 1;  next non-modifier key sets it
--  km:beginRebind("cam_left",    2)   -- slot 2 (alt key)
--  km:cancelRebind()
--  km:isRebinding()                   -- nil | action_id
--
--  -- persistence:
--  km:save()   km:load()              -- default path "keybindings.lua"
-- =============================================================================

local Keymap   = {}
Keymap.__index = Keymap

-- ─────────────────────────────────────────────────────────────────────────────
-- BINDING PARSE / FORMAT
-- ─────────────────────────────────────────────────────────────────────────────

local KEY_LABEL = {
    ["return"]  = "Enter",  space    = "Space",  tab      = "Tab",
    escape      = "Esc",    backspace = "Bksp",   delete   = "Del",
    up          = "↑",      down     = "↓",       left     = "←",   right = "→",
    f1="F1", f2="F2", f3="F3",  f4="F4",  f5="F5",  f6="F6",
    f7="F7", f8="F8", f9="F9", f10="F10", f11="F11", f12="F12",
    lshift="LShift", rshift="RShift", lctrl="LCtrl", rctrl="RCtrl",
    lalt="LAlt", ralt="RAlt",
}

-- "ctrl+z" → { key="z", ctrl=true, shift=false, alt=false }
local function parseBind(s)
    if not s or s == "" then return nil end
    local b = { ctrl = false, shift = false, alt = false, key = nil }
    for part in s:lower():gmatch("[^+]+") do
        if     part == "ctrl"  then b.ctrl  = true
        elseif part == "shift" then b.shift = true
        elseif part == "alt"   then b.alt   = true
        else   b.key = part end
    end
    return b.key and b or nil
end

-- { key="z", ctrl=true } → "Ctrl+Z"
local function fmtBind(b)
    if not b then return nil end
    local p = {}
    if b.ctrl  then p[#p+1] = "Ctrl"  end
    if b.shift then p[#p+1] = "Shift" end
    if b.alt   then p[#p+1] = "Alt"   end
    p[#p+1] = KEY_LABEL[b.key] or b.key:upper()
    return table.concat(p, "+")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ACTION REGISTRY
-- ─────────────────────────────────────────────────────────────────────────────
--  default  string | { string, string }  — up to 2 bindings per action
--  held     true → use isDown() instead of keypressed event (camera pan etc.)

local ACTIONS = {
    -- ── Tools ─────────────────────────────────────────────────────────────────
    { id="tool_pencil",    name="Pencil",           cat="Tools",   default="1"                     },
    { id="tool_erase",     name="Erase",            cat="Tools",   default="2"                     },
    { id="tool_fill",      name="Fill",             cat="Tools",   default="3"                     },
    { id="tool_pick",      name="Eyedropper",       cat="Tools",   default="4"                     },
    { id="tool_rect",      name="Rectangle",        cat="Tools",   default="5"                     },
    -- ── Edit ──────────────────────────────────────────────────────────────────
    { id="edit_undo",      name="Undo",             cat="Edit",    default="ctrl+z"                },
    { id="edit_redo",      name="Redo",             cat="Edit",    default="ctrl+y"                },
    { id="edit_clear",     name="Clear Layer",      cat="Edit",    default=nil                     },
    -- ── File ──────────────────────────────────────────────────────────────────
    { id="file_save",      name="Save",             cat="File",    default="f5"                    },
    { id="file_load",      name="Load",             cat="File",    default="f9"                    },
    { id="file_new",       name="New Map",          cat="File",    default=nil                     },
    -- ── View ──────────────────────────────────────────────────────────────────
    { id="view_grid",      name="Toggle Grid",      cat="View",    default="g"                     },
    { id="view_editor",    name="Editor Mode",      cat="View",    default="e"                     },
    { id="view_keybinds",  name="Keybindings",      cat="View",    default="f2"                    },
    { id="view_reset_cam", name="Reset Camera",     cat="View",    default=nil                     },
    -- ── Layers ────────────────────────────────────────────────────────────────
    { id="layer_cycle",    name="Cycle Layer",      cat="Layers",  default="tab"                   },
    { id="layer_up",       name="Move Layer Up",    cat="Layers",  default=nil                     },
    { id="layer_down",     name="Move Layer Down",  cat="Layers",  default=nil                     },
    -- ── Camera (held — checked with isDown, no modifier requirement) ──────────
    { id="cam_left",       name="Pan Left",         cat="Camera",  default={"a","left"},  held=true },
    { id="cam_right",      name="Pan Right",        cat="Camera",  default={"d","right"}, held=true },
    { id="cam_up",         name="Pan Up",           cat="Camera",  default={"w","up"},    held=true },
    { id="cam_down",       name="Pan Down",         cat="Camera",  default={"s","down"},  held=true },
}

local CAT_ORDER = { "Tools", "Edit", "File", "View", "Layers", "Camera" }

-- ─────────────────────────────────────────────────────────────────────────────
-- CONSTRUCTOR
-- ─────────────────────────────────────────────────────────────────────────────

function Keymap.new(savePath)
    local self          = setmetatable({}, Keymap)
    self._savePath      = savePath or "keybindings.lua"
    self._bindings      = {}   -- [action_id] = { bind1, bind2? }
    self._pressed       = {}   -- [key] = true; set in onKeyPressed, cleared in beginFrame
    self._rebinding     = nil  -- action_id currently being rebound, or nil
    self._rebindSlot    = 1    -- which slot (1 or 2) to overwrite
    self._defs          = {}   -- [action_id] = action def table

    -- Build lookup + apply defaults
    for _, a in ipairs(ACTIONS) do
        self._defs[a.id]     = a
        self._bindings[a.id] = {}
        if a.default then
            local list = type(a.default) == "table" and a.default or { a.default }
            for i, s in ipairs(list) do
                self._bindings[a.id][i] = parseBind(s)
            end
        end
    end

    -- Auto-load saved keybindings
    if love.filesystem.getInfo(self._savePath) then
        self:load(self._savePath)
    end

    return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FRAME LIFECYCLE
-- ─────────────────────────────────────────────────────────────────────────────

-- Call at the very START of love.update — clears the previous frame's key events.
function Keymap:beginFrame()
    self._pressed = {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- INPUT  (call from love.keypressed)
-- ─────────────────────────────────────────────────────────────────────────────

local PURE_MODS = {
    lctrl=true, rctrl=true, lshift=true, rshift=true, lalt=true, ralt=true
}

-- Returns true if the event was consumed (rebind mode captured it or was cancelled).
-- When true, callers should skip all other key handling for this event.
function Keymap:onKeyPressed(key)
    if self._rebinding then
        if key == "escape" then          -- cancel rebind
            self._rebinding = nil
            return true
        end
        if PURE_MODS[key] then return true end  -- wait for real key

        -- Capture binding with current modifiers
        self._bindings[self._rebinding][self._rebindSlot] = {
            key   = key,
            ctrl  = love.keyboard.isDown("lctrl", "rctrl"),
            shift = love.keyboard.isDown("lshift", "rshift"),
            alt   = love.keyboard.isDown("lalt", "ralt"),
        }
        self._rebinding = nil
        return true
    end

    self._pressed[key] = true
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY
-- ─────────────────────────────────────────────────────────────────────────────

-- True if the action's key-combo fired as a keypressed event this frame.
-- Modifier state is checked against what's stored in the binding.
function Keymap:pressed(actionId)
    local list = self._bindings[actionId]
    if not list then return false end
    local ctrl  = love.keyboard.isDown("lctrl", "rctrl")
    local shift = love.keyboard.isDown("lshift", "rshift")
    local alt   = love.keyboard.isDown("lalt", "ralt")
    for _, b in ipairs(list) do
        if b and self._pressed[b.key]
           and b.ctrl  == ctrl
           and b.shift == shift
           and b.alt   == alt then
            return true
        end
    end
    return false
end

-- True if ANY bound key is physically held right now (ignores modifiers).
-- Designed for held actions like camera pan.
function Keymap:down(actionId)
    local list = self._bindings[actionId]
    if not list then return false end
    for _, b in ipairs(list) do
        if b and love.keyboard.isDown(b.key) then return true end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DISPLAY
-- ─────────────────────────────────────────────────────────────────────────────

-- Format one slot: "Ctrl+Z"  or nil if unbound.
function Keymap:displaySlot(actionId, slot)
    local list = self._bindings[actionId]
    return list and fmtBind(list[slot]) or nil
end

-- Format all slots joined: "A / ←"  or "Ctrl+Z"  or "–" if nothing bound.
function Keymap:display(actionId)
    local list = self._bindings[actionId]
    if not list then return "–" end
    local parts = {}
    for _, b in ipairs(list) do
        if b then parts[#parts+1] = fmtBind(b) end
    end
    return #parts > 0 and table.concat(parts, " / ") or "–"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- REBIND
-- ─────────────────────────────────────────────────────────────────────────────

-- Begin capturing the next non-modifier keypress as the new binding for slot.
function Keymap:beginRebind(actionId, slot)
    self._rebinding  = actionId
    self._rebindSlot = slot or 1
    self._pressed    = {}   -- prevent stale keys from completing the rebind immediately
end

function Keymap:cancelRebind()
    self._rebinding = nil
end

-- Returns nil when not rebinding, or the action_id currently being rebound.
function Keymap:isRebinding()
    return self._rebinding
end

-- Returns true if specifically this action+slot is awaiting input.
function Keymap:isRebindingSlot(actionId, slot)
    return self._rebinding == actionId and self._rebindSlot == slot
end

-- Clear one slot (or all slots if slot is nil).
function Keymap:clearBinding(actionId, slot)
    local list = self._bindings[actionId]
    if not list then return end
    if slot then
        list[slot] = nil
    else
        self._bindings[actionId] = {}
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFLICT DETECTION
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns a list of conflict records: { binding="Ctrl+Z", actions={"edit_undo","file_save"} }
-- Two bindings conflict when they share the same key + modifiers.
function Keymap:getConflicts()
    local seen      = {}   -- fingerprint → action_id
    local conflicts = {}
    local added     = {}   -- dedup by pair string

    for id, list in pairs(self._bindings) do
        for _, b in ipairs(list) do
            if b then
                local fp = b.key
                    .. (b.ctrl  and "\1" or "\0")
                    .. (b.shift and "\1" or "\0")
                    .. (b.alt   and "\1" or "\0")
                if seen[fp] and seen[fp] ~= id then
                    local a1, a2 = seen[fp], id
                    if a1 > a2 then a1, a2 = a2, a1 end
                    local key = a1 .. "|" .. a2
                    if not added[key] then
                        added[key] = true
                        table.insert(conflicts, { binding = fmtBind(b), actions = { seen[fp], id } })
                    end
                else
                    seen[fp] = id
                end
            end
        end
    end
    return conflicts
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DEFAULTS
-- ─────────────────────────────────────────────────────────────────────────────

function Keymap:resetDefaults()
    for _, a in ipairs(ACTIONS) do
        self._bindings[a.id] = {}
        if a.default then
            local list = type(a.default) == "table" and a.default or { a.default }
            for i, s in ipairs(list) do
                self._bindings[a.id][i] = parseBind(s)
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE
-- ─────────────────────────────────────────────────────────────────────────────

function Keymap:save(path)
    path = path or self._savePath
    local lines = { "return {" }
    for id, list in pairs(self._bindings) do
        local strs = {}
        for _, b in ipairs(list) do
            if b then
                local parts = {}
                if b.ctrl  then parts[#parts+1] = "ctrl"  end
                if b.shift then parts[#parts+1] = "shift" end
                if b.alt   then parts[#parts+1] = "alt"   end
                parts[#parts+1] = b.key
                strs[#strs+1] = '"' .. table.concat(parts, "+") .. '"'
            end
        end
        if #strs > 0 then
            lines[#lines+1] = string.format('  ["%s"] = { %s },', id, table.concat(strs, ", "))
        end
    end
    lines[#lines+1] = "}"
    return love.filesystem.write(path, table.concat(lines, "\n"))
end

function Keymap:load(path)
    path = path or self._savePath
    if not love.filesystem.getInfo(path) then return false, "not found" end
    local fn, err = love.filesystem.load(path)
    if not fn then return false, err end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= "table" then return false, "parse error" end
    for id, bindstrs in pairs(data) do
        if self._bindings[id] ~= nil then   -- only apply known actions
            self._bindings[id] = {}
            for i, s in ipairs(bindstrs) do
                self._bindings[id][i] = parseBind(s)
            end
        end
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- INTROSPECTION  (for building the UI panel)
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns the ordered category list.
function Keymap.categories()
    return CAT_ORDER
end

-- Returns all action defs for a category, in definition order.
function Keymap:actionsForCategory(cat)
    local out = {}
    for _, a in ipairs(ACTIONS) do
        if a.cat == cat then out[#out+1] = a end
    end
    return out
end

-- Returns the action definition table (name, cat, held, default).
function Keymap:getDef(actionId)
    return self._defs[actionId]
end

return Keymap
