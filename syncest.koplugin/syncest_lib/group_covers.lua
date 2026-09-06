-- group_covers.lua
-- macOS-style folder previews: a 2x2 mosaic of the first N child book
-- covers, served as a synthetic readest-group:// URI through the
-- patched BookInfoManager. Fully populated composites are cached on disk
-- and in memory. The fingerprint includes each source cover's presence,
-- size and mtime, so a newly downloaded child invalidates an older mosaic.
-- Partial composites are deliberately never persisted.

local cloud_covers = require("syncest_lib.cloud_covers")
local sha2 = require("ffi/sha2")

local M = {}

M.URI_PREFIX = "readest-group://"

local _mosaic_cache = {}

-- Layouts:
--   "grid" — 2x2, 360x480 (3:4 — typical book-cover aspect).
--   "list" — 2x2, 480x480 (square — matches ListMenu's rigid square
--   cover slot, so the composite fills it vertically and each
--   mini-cover stays book-shaped instead of getting squished).
M.LAYOUTS = {
    grid = { target_w = 360, target_h = 480, cols = 2, rows = 2 },
    list = { target_w = 480, target_h = 480, cols = 2, rows = 2 },
}

-- "Asimov" → "417369..." — filesystem-safe regardless of slashes,
-- colons, etc. in the original group value.
local function hex_encode(s)
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function hex_decode(hex)
    return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- shape ∈ {"grid", "list"} — controls the composite layout. Defaults
-- to "grid" for backward compat with older callers.
function M.build_uri(group_by, value, shape)
    return M.URI_PREFIX .. group_by .. ":" .. hex_encode(value)
        .. ":" .. (shape or "grid") .. ".png"
end

-- Returns group_by, value, shape; nil if not a group URI.
function M.parse_uri(uri)
    if uri:sub(1, #M.URI_PREFIX) ~= M.URI_PREFIX then return nil end
    local body = uri:sub(#M.URI_PREFIX + 1)
    if body:sub(-4) == ".png" then body = body:sub(1, -5) end
    local parts = {}
    for p in body:gmatch("[^:]+") do parts[#parts + 1] = p end
    if #parts < 2 then return nil end
    local group_by = parts[1]
    local hex      = parts[2]
    local shape    = parts[3] or "grid"
    local value    = hex_decode(hex)
    return group_by, value, shape
end

-- Pull a usable cover bb for a single child book during composition.
-- Tries (in order):
--   1. local file via the original BIM cache (already-cached only;
--      no extraction triggered)
--   2. cloud cover .png we previously downloaded
-- Returns nil if neither path produces one. Caller owns the bb.
--
-- When (2) misses for a cloud-present book, queue a cloud-cover download
-- so a subsequent paint can complete the mosaic. Without this hook a
-- freshly-pulled library renders every group as FakeCover until the user
-- drills into each one, because cloud_covers' download queue is only
-- primed for cloud-only book entries on the visible page — group cells
-- never appear there themselves, so their children's covers were never
-- requested.
function M.child_cover_bb(book, orig_getBookInfo, BIM)
    if not book then return nil end
    if book.local_present == 1 and book.file_path and orig_getBookInfo then
        local ok, info = pcall(orig_getBookInfo, BIM, book.file_path, true)
        if ok and info and info.has_cover and info.cover_bb then
            -- BIM hands us a cached bb whose ownership it keeps; we copy
            -- before scaling so the BIM cache stays intact when our
            -- composition pipeline frees what it received.
            local Blitbuffer = require("ffi/blitbuffer")
            local copy = Blitbuffer.new(info.cover_bb:getWidth(),
                                        info.cover_bb:getHeight(),
                                        info.cover_bb:getType())
            copy:blitFrom(info.cover_bb, 0, 0, 0, 0,
                          info.cover_bb:getWidth(), info.cover_bb:getHeight())
            return copy
        end
    end
    if not book.hash or book.hash == "" then return nil end
    local bb = cloud_covers.load_cover_bb(book.hash)
    if bb then return bb end
    if (book.cloud_present or 0) == 1 then
        cloud_covers.trigger_download(book.hash)
    end
    return nil
end

local function cache_dir()
    return require("syncest_lib.storage").path("syncest_group_thumbnails")
end

local function group_identity(group_by, value, shape)
    return sha2.md5(table.concat({
        tostring(group_by), tostring(value), tostring(shape or "grid"),
    }, "|"))
end

local function read_text(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local value = f:read("*a")
    f:close()
    return value
end

local function write_text(path, value)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(value)
    f:close()
    return true
end

local function copy_bb(bb)
    if not bb then return nil end
    local ok, copy = pcall(bb.copy, bb)
    return ok and copy or nil
end

local function file_token(path)
    if not path or path == "" then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    if not attr then return nil end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

local function books_fingerprint(books, shape)
    local parts = { shape or "grid", tostring(#books) }
    for i, book in ipairs(books) do
        local local_token = book.local_present == 1 and file_token(book.file_path) or nil
        local cloud_token = book.hash and cloud_covers.cover_token(book.hash) or nil
        parts[#parts + 1] = table.concat({
            tostring(i),
            tostring(book.hash or ""),
            tostring(local_token or "-"),
            tostring(cloud_token or "-"),
            tostring(book.updated_at or "-"),
        }, ":")
    end
    return sha2.md5(table.concat(parts, "|"))
end

-- Compose up to N child covers into a mosaic. The placed/expected counts let
-- the caller distinguish a complete image (safe to persist) from a partial
-- one that should be repainted after pending cover downloads finish.
local function compose(books, shape, orig_getBookInfo, BIM)
    if #books == 0 then return nil, 0, 0 end
    local layout = M.LAYOUTS[shape] or M.LAYOUTS.grid
    local target_w, target_h = layout.target_w, layout.target_h
    local cols, rows = layout.cols, layout.rows
    local max_cells = cols * rows
    local expected = math.min(max_cells, #books)

    local Blitbuffer = require("ffi/blitbuffer")
    local target = Blitbuffer.new(target_w, target_h, Blitbuffer.TYPE_BBRGB32)
    target:fill(Blitbuffer.COLOR_WHITE)

    local gap = 8
    local cell_w = math.floor((target_w - (cols - 1) * gap) / cols)
    local cell_h = math.floor((target_h - (rows - 1) * gap) / rows)
    local placed = 0

    for i = 1, expected do
        local book = books[i]
        local cover = M.child_cover_bb(book, orig_getBookInfo, BIM)
        if cover then
            local row = math.floor((i - 1) / cols)
            local col = (i - 1) % cols
            local dx = col * (cell_w + gap)
            local dy = row * (cell_h + gap)
            local ok_scale, scaled = pcall(cover.scale, cover, cell_w, cell_h)
            if ok_scale and scaled then
                target:blitFrom(scaled, dx, dy, 0, 0, cell_w, cell_h)
                scaled:free()
                placed = placed + 1
            end
            cover:free()
        end
    end

    if placed == 0 then
        target:free()
        return nil, 0, expected
    end
    return target, placed, expected
end

-- Cells-per-mosaic for a given shape. Used by callers to know how many
-- books to fetch from the store.
function M.cells_for(shape)
    local layout = M.LAYOUTS[shape] or M.LAYOUTS.grid
    return layout.cols * layout.rows
end

-- High-level: query the store and serve a validated cached composite, or
-- compose it once. The returned bb is always caller-owned.
function M.serve_or_compose(group_by, value, shape,
                            store, settings, orig_getBookInfo, BIM)
    if not store then return nil, {} end
    local n = M.cells_for(shape)
    local books = store:listBooksInGroup(group_by, value, n, {
        sort_by  = settings and settings.library_sort_by,
        sort_asc = settings and settings.library_sort_ascending == true,
    })
    local identity = group_identity(group_by, value, shape)
    local fingerprint = books_fingerprint(books, shape)
    local memory = _mosaic_cache[identity]
    if memory and memory.fingerprint == fingerprint and memory.bb then
        local copy = copy_bb(memory.bb)
        if copy then return copy, books end
    elseif memory and memory.bb then
        memory.bb:free()
        _mosaic_cache[identity] = nil
    end

    require("util").makePath(cache_dir())
    local image_path = cache_dir() .. "/" .. identity .. ".png"
    local key_path = image_path .. ".meta"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(image_path, "mode") == "file"
            and read_text(key_path) == fingerprint then
        local ok_render, RenderImage = pcall(require, "ui/renderimage")
        if ok_render then
            local ok_load, bb = pcall(
                RenderImage.renderImageFile, RenderImage, image_path, false)
            if ok_load and bb then
                _mosaic_cache[identity] = {
                    fingerprint = fingerprint,
                    bb = bb,
                }
                return copy_bb(bb), books
            end
        end
    end

    local bb, placed, expected = compose(books, shape, orig_getBookInfo, BIM)
    if not bb then return nil, books end
    if placed == expected then
        local wrote = bb:writeToFile(image_path, "png")
        if wrote then write_text(key_path, fingerprint) end
        _mosaic_cache[identity] = {
            fingerprint = fingerprint,
            bb = bb,
        }
        local copy = copy_bb(bb)
        if copy then return copy, books end
        _mosaic_cache[identity] = nil
    end
    return bb, books
end

-- Build/validate a group composite before constructing its menu entry, then
-- return the real PNG path that stock KOReader and Zen both accept.
function M.materialize_path(group_by, value, shape, store, settings)
    if not store then return nil end
    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not ok_bim or not BIM then return nil end
    local bb = M.serve_or_compose(
        group_by, value, shape, store, settings, BIM.getBookInfo, BIM)
    if bb then bb:free() end
    local path = cache_dir() .. "/"
        .. group_identity(group_by, value, shape) .. ".png"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") == "file" then return path end
end

return M
