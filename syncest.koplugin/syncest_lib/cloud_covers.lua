-- cloud_covers.lua
-- Per-book cover lifecycle for cloud-only rows. Owns the on-disk
-- <hash>.png cache and the single-slot async download queue that
-- fetches missing covers from WebDAV when cells become visible.

local logger = require("logger")

local WebDavAuth = require("webdav_auth")

local M = {}

M.URI_PREFIX = "readest-cloud://"

-- Synthetic metadata cache keyed by hash: { title, author }
local _meta = {}

-- Download lifecycle state
local _cover_pending   = {}
local _missing_covers  = {}
local _visible_hashes  = nil
local _refresh_pending = false
local _download_queue  = {}
local _downloading     = false

-- Decoded, view-sized cover masters. Callers receive copies because
-- KOReader's cover widgets take ownership of (and free) their blitbuffers.
local _memory_thumbnails = {}

-- WebDAV opts (set via M.set_opts). Holds { settings } with webdav_* fields.
local _opts = nil

function M.set_opts(opts)
    _opts = opts
end

function M.set_meta(key, meta)
    _meta[key] = meta
end

function M.get_meta(key)
    return _meta[key] or {}
end

function M.covers_dir()
    return require("syncest_lib.storage").path("readest_covers")
end

local function cover_path_for(hash)
    return M.covers_dir() .. "/" .. hash .. ".png"
end

function M.cached_cover_path(hash)
    local lfs = require("libs/libkoreader-lfs")
    local path = cover_path_for(hash)
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
end

local function thumbnail_dir()
    return require("syncest_lib.storage").path("syncest_thumbnails")
end

local THUMBNAIL_BOUNDS = {
    grid   = { w = 360, h = 480 },
    list   = { w = 360, h = 480 },
    source = nil,
}

local function source_token(path)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    if not attr then return nil end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

function M.cover_token(hash)
    return source_token(cover_path_for(hash))
end

-- Keep the real book hash at the start of the synthetic filename, but add a
-- source version before the final image suffix. Zen UI keys its rendered-tile
-- cache by entry.file; without a changing URI, a FakeCover created before the
-- async download survives ordinary Library refreshes indefinitely.
function M.cover_uri(hash)
    local token = M.cover_token(hash)
    if token then
        token = token:gsub("[^%w]", "_")
        return M.URI_PREFIX .. hash .. "." .. token .. ".png"
    end
    return M.URI_PREFIX .. hash .. ".pending.png"
end

-- Drop downloaded cloud covers and every derived thumbnail so the next
-- Library paint fetches the current WebDAV cover instead of treating an old
-- on-device PNG as authoritative.
function M.clear_download_cache()
    local lfs = require("libs/libkoreader-lfs")
    for _, cached in pairs(_memory_thumbnails) do
        if cached.bb then cached.bb:free() end
    end
    _memory_thumbnails = {}
    _cover_pending = {}
    _missing_covers = {}
    _download_queue = {}

    for _, dir in ipairs({ M.covers_dir(), thumbnail_dir() }) do
        if lfs.attributes(dir, "mode") == "directory" then
            local ok, iter, dir_obj = pcall(lfs.dir, dir)
            if ok then
                for name in iter, dir_obj do
                    if name ~= "." and name ~= ".." then
                        os.remove(dir .. "/" .. name)
                    end
                end
            end
        end
    end
end

-- A catalog refresh should retry covers previously marked missing, but it
-- must not delete good on-device covers first. If the server is temporarily
-- unreachable, deleting the cache turns already-renderable books into blank
-- tiles (and forces every cover through the network again).
function M.reset_download_failures()
    _missing_covers = {}
    _cover_pending = {}
    _download_queue = {}
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

-- Return a real, view-sized PNG whose basename is the catalog title. Zen UI
-- may bypass Syncest metadata during a delayed CoverBrowser refresh and fall
-- back to the filename; exposing <hash>.png there turns every title into a
-- hash. Keeping the hash in the parent directory preserves uniqueness while
-- making even that fallback human-readable.
function M.display_cover_path(hash, title)
    local lfs = require("libs/libkoreader-lfs")
    local source_path = cover_path_for(hash)
    if lfs.attributes(source_path, "mode") ~= "file" then return nil end
    local token = source_token(source_path)
    if not token then return nil end

    local util = require("util")
    local dir = thumbnail_dir() .. "/display/" .. tostring(hash)
    util.makePath(dir)
    local filename = util.getSafeFilename(
        tostring(title or "Untitled") .. ".png", dir, 200, 10)
    local path = dir .. "/" .. filename
    local meta_path = path .. ".meta"
    if lfs.attributes(path, "mode") == "file"
            and read_text(meta_path) == token then
        return path
    end

    local bb = M.load_cover_bb(hash, "grid")
    if not bb then return nil end
    local wrote = bb:writeToFile(path, "png")
    bb:free()
    if not wrote then return nil end
    write_text(meta_path, token)
    return path
end

local function copy_bb(bb)
    if not bb then return nil end
    local ok, copy = pcall(bb.copy, bb)
    return ok and copy or nil
end

function M.hash_from_uri(filepath)
    local rest = filepath:sub(#M.URI_PREFIX + 1)
    return (rest:match("^([^.]+)") or rest)
end

-- Load a cover, optionally through a persistent view-sized thumbnail.
-- The source PNG remains the authority; its mtime+size token invalidates both
-- memory and disk thumbnails when a newer cover is downloaded.
function M.load_cover_bb(hash, variant)
    local lfs = require("libs/libkoreader-lfs")
    local source_path = cover_path_for(hash)
    if lfs.attributes(source_path, "mode") ~= "file" then return nil end
    variant = THUMBNAIL_BOUNDS[variant] and variant or "source"
    local token = source_token(source_path)
    if not token then return nil end

    local memory_key = hash .. ":" .. variant
    -- ListMenu rebuilds rows frequently and its cover widgets take ownership
    -- of their blitbuffers. Keep using the fast persistent list thumbnail,
    -- but decode a fresh owner for each row instead of sharing an in-memory
    -- master that another rebuild may have already freed.
    local use_memory = variant ~= "list"
    local memory = use_memory and _memory_thumbnails[memory_key] or nil
    if memory then
        if memory.token == token and memory.bb then
            local copy = copy_bb(memory.bb)
            if copy then return copy end
        elseif memory.bb then
            memory.bb:free()
            _memory_thumbnails[memory_key] = nil
        end
    end

    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok then return nil end

    local load_path = source_path
    local thumb_path, meta_path
    local bounds = THUMBNAIL_BOUNDS[variant]
    if bounds then
        require("util").makePath(thumbnail_dir())
        thumb_path = thumbnail_dir() .. "/" .. hash .. "-" .. variant .. ".png"
        meta_path = thumb_path .. ".meta"
        if lfs.attributes(thumb_path, "mode") == "file"
                and read_text(meta_path) == token then
            load_path = thumb_path
        end
    end

    local ok2, bb = pcall(RenderImage.renderImageFile, RenderImage, load_path, false)
    -- A thumbnail write may have been interrupted, or an older cache entry
    -- may no longer be readable by the current renderer. The source cover is
    -- still authoritative, so discard only the broken derived files and
    -- rebuild them instead of leaving this row as a FakeCover forever.
    if (not ok2 or not bb) and thumb_path and load_path == thumb_path then
        os.remove(thumb_path)
        os.remove(meta_path)
        load_path = source_path
        ok2, bb = pcall(RenderImage.renderImageFile, RenderImage, load_path, false)
    end
    if not ok2 or not bb then return nil end

    -- First use after a source change: scale once, persist once.
    if bounds and load_path == source_path then
        local w, h = bb:getWidth(), bb:getHeight()
        local factor = math.min(bounds.w / w, bounds.h / h, 1)
        local target_w = math.max(1, math.floor(w * factor + 0.5))
        local target_h = math.max(1, math.floor(h * factor + 0.5))
        local scaled = bb
        if target_w ~= w or target_h ~= h then
            local ok_scale, result = pcall(bb.scale, bb, target_w, target_h)
            if ok_scale and result then
                scaled = result
                bb:free()
            end
        end
        bb = scaled
        local wrote = bb:writeToFile(thumb_path, "png")
        if wrote then write_text(meta_path, token) end
    end

    if use_memory then
        _memory_thumbnails[memory_key] = { token = token, bb = bb }
        return copy_bb(bb)
    end
    return bb
end

local function tag_for(hash)
    local meta = _meta[hash] or {}
    return hash:sub(1, 8) .. " '" .. tostring(meta.title or "?") .. "'"
end

local function process_queue()
    if _downloading then return end
    local hash
    repeat
        hash = table.remove(_download_queue, 1)
        if not hash then return end
        if _missing_covers[hash] then
            _cover_pending[hash] = nil
            hash = nil
        elseif _visible_hashes and not _visible_hashes[hash] then
            logger.dbg("WebDavSync cover dequeue skip: " .. tag_for(hash)
                .. " no longer on visible page")
            _cover_pending[hash] = nil
            hash = nil
        end
    until hash

    _downloading = true
    logger.info("WebDavSync cover download: starting " .. tag_for(hash))

    local function finish_download(success, path_or_err, status)
            _cover_pending[hash] = nil
            _downloading = false
            if not success then
                if status == 404 then
                    _missing_covers[hash] = true
                    logger.info("WebDavSync cover " .. tag_for(hash)
                        .. " — not on server (404)")
                    -- A local/archived copy may still have a valid extracted
                    -- cover. Persist that path so its row can bypass a stale
                    -- KOReader FakeCover without affecting unrelated books.
                    local fallback = require("syncest_lib.storage").path("syncest_covers") .. "/" .. hash .. ".png"
                    local lfs = require("libs/libkoreader-lfs")
                    if lfs.attributes(fallback, "mode") == "file" then
                        local LibraryWidget = package.loaded["syncest_lib.librarywidget"]
                        local store = LibraryWidget and LibraryWidget._store
                        local meta = _meta[hash] or {}
                        if store then
                            store:upsertBook({
                                hash = hash,
                                title = meta.title or "Untitled",
                                cover_path = fallback,
                            })
                        end
                        if LibraryWidget and LibraryWidget._menu then
                            local UIManager = require("ui/uimanager")
                            UIManager:nextTick(function()
                                LibraryWidget.refresh()
                            end)
                        end
                    end
                else
                    logger.warn("WebDavSync cover " .. tag_for(hash)
                        .. " failed: " .. tostring(path_or_err))
                end
            else
                logger.info("WebDavSync cover " .. tag_for(hash)
                    .. " saved → " .. tostring(path_or_err))
                -- Any in-process thumbnail for an overwritten source is stale.
                for _, variant in ipairs({ "source", "grid", "list" }) do
                    local key = hash .. ":" .. variant
                    local cached = _memory_thumbnails[key]
                    if cached and cached.bb then cached.bb:free() end
                    _memory_thumbnails[key] = nil
                end
                if not _refresh_pending then
                    _refresh_pending = true
                    local UIManager = require("ui/uimanager")
                    UIManager:nextTick(function()
                        _refresh_pending = false
                        local LibraryWidget = package.loaded["syncest_lib.librarywidget"]
                        if LibraryWidget and LibraryWidget._menu then LibraryWidget.refresh() end
                    end)
                end
            end
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(process_queue)
    end

    -- Cover extraction is triggered while cells are being built, so an inline
    -- WebDAV request here blocks painting and input. Fork the synchronous
    -- transfer and poll it from the UI loop; only the result handling above
    -- runs in the parent process.
    local FFIUtil = require("ffi/util")
    local result_path = require("syncest_lib.storage").tempDir()
        .. "/syncest_cover_download_" .. hash .. ".json"
    os.remove(result_path)
    local settings = _opts and _opts.settings
    local covers_dir = M.covers_dir()
    local launched, pid = pcall(FFIUtil.runInSubProcess, function()
        local json = require("json")
        local syncbooks = require("syncest_lib.syncbooks")
        local result = { success = false, message = "download failed" }
        syncbooks.downloadCover({ hash = hash }, {
            settings = settings,
            covers_dir = covers_dir,
        }, function(success, path_or_err, status)
            result.success = success == true
            result.message = path_or_err
            result.status = status
        end)
        local file = io.open(result_path, "w")
        if file then
            file:write(json.encode(result))
            file:close()
        end
    end)
    if not launched or not pid then
        finish_download(false, tostring(pid or "subprocess launch failed"))
        return
    end

    local started_at = os.time()
    local poll
    poll = function()
        if not FFIUtil.isSubProcessDone(pid) then
            if os.time() - started_at < 75 then
                require("ui/uimanager"):scheduleIn(0.1, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            os.remove(result_path)
            finish_download(false, "timeout")
            return
        end
        local file = io.open(result_path, "r")
        local payload = file and file:read("*a") or nil
        if file then file:close() end
        os.remove(result_path)
        local ok_json, result = pcall(require("json").decode, payload or "")
        if not ok_json or type(result) ~= "table" then
            finish_download(false, "invalid background response")
            return
        end
        finish_download(result.success, result.message, result.status)
    end
    require("ui/uimanager"):scheduleIn(0.1, poll)
end

function M.trigger_download(hash)
    if _cover_pending[hash] then return end
    if _missing_covers[hash] then return end
    if not _opts or not _opts.settings or WebDavAuth:needsSetup(_opts.settings) then
        logger.warn("WebDavSync cover skip: " .. tag_for(hash) .. " — WebDAV not configured")
        return
    end
    if _visible_hashes and not _visible_hashes[hash] then return end

    _cover_pending[hash] = true
    table.insert(_download_queue, hash)
    logger.dbg("WebDavSync cover queued: " .. tag_for(hash)
        .. " (queue len=" .. #_download_queue .. ")")
    process_queue()
end

function M.set_visible_hashes(set)
    _visible_hashes = set
    if set == nil then
        logger.dbg("WebDavSync set_visible_hashes: cleared")
    else
        local count = 0
        for _ in pairs(set) do count = count + 1 end
        logger.info("WebDavSync set_visible_hashes: count=" .. count)
    end
end

return M
