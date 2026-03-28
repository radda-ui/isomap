# isomap.lua
a simple isometric map editor made for love 2D

## Why this exists
for a professional use

The full list of what was designed:

- Infinite grid with zero memory cost for empty space
- Layered map (tile, object, decal, trigger, light)
- Multiple tilesets with animated tiles
- Camera with smooth follow and zoom-to-cursor
- Renderer with frustum culling and SpriteBatch batching
- In-library editor (pencil, erase, fill, eyedropper, rect)
- Full undo/redo via command objects
- Binary save/load with no tile-count ceiling
- Diagnostic logger that wraps the whole system non-invasively

---