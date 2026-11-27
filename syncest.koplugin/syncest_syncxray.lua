--[[--
X-Ray (xray.koplugin) analysis sync, per book.

X-Ray keeps what its AI worked out about a book (characters, places, terms, timeline, author) in the book's
sidecar folder as xray_cache.lua. Making that costs AI calls and time, so one device's analysis is shared
with the others through sync/<book hash>/xray.json. The copy analysed furthest into the book wins; a
less-analysed copy never replaces a more-analysed one.

Page numbers: X-Ray stores page numbers throughout (how far it analysed, and the page where each character
note starts, which it uses to avoid spoilers). Pages differ between devices, so a snapshot carries, for each
page number it uses, the position in the book's text where that page starts (an xpointer). The receiving
device turns each position back into its own page number. Fixed-layout documents (PDF, CBZ) keep their
numbers; anything without a position is scaled by the two devices' page counts.

Everything here is a no-op when X-Ray is not installed or is disabled.
]]

local DataStorage = require("datastorage")
local dump = require("dump")
local logger = require("logger")

local SyncXray = {}

SyncXray.FILE = "xray.json"
SyncXray.FORMAT = 1

local PLUGIN_NAME = "xray"
local CACHE_FILE = "xray_cache.lua"

-- ── Discovery ──────────────────────────────────────────────────────

--- The running X-Ray plugin of the open book, or nil.
function SyncXray.instance(ui)
    if not ui then
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        ui = ok and ReaderUI and ReaderUI.instance
    end
    local xray = ui and ui[PLUGIN_NAME]
    if type(xray) == "table" and type(xray.autoLoadCache) == "function" then
        return xray
    end
end

--- X-Ray is installed and enabled.
function SyncXray.installed()
    local disabled = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled[PLUGIN_NAME] then return false end
    if SyncXray.instance() then return true end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return false end
    return lfs.attributes(DataStorage:getDataDir() .. "/plugins/xray.koplugin", "mode") == "directory"
end

local function cache_path(doc_file)
    local DocSettings = require("docsettings")
    local dir = doc_file and DocSettings:getSidecarDir(doc_file)
    return dir and (dir .. "/" .. CACHE_FILE)
end

-- xray_cache.lua is a plain `return { ... }`; load it without giving it access to anything.
local function load_cache_file(path)
    local fn = path and loadfile(path)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then return data end
end

local function load_lua(s)
    if type(s) ~= "string" or s == "" then return nil end
    local fn = loadstring("return " .. s)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, v = pcall(fn)
    if ok and type(v) == "table" then return v end
end

-- ── Pages ──────────────────────────────────────────────────────────

-- Keys whose numbers are page numbers: `page`, and anything ending in `_page` (last_fetch_page, start_page…).
local function is_page_key(k)
    return type(k) == "string" and (k == "page" or k:sub(-5) == "_page")
end

-- Calls fn(table, key, value) for every page number in `data`.
local function each_page(data, fn, seen)
    seen = seen or {}
    if seen[data] then return end
    seen[data] = true
    for k, v in pairs(data) do
        if type(v) == "table" then
            each_page(v, fn, seen)
        elseif type(v) == "number" and is_page_key(k) then
            fn(data, k, v)
        end
    end
end

local function reflowable(ui)
    return ui and ui.rolling and ui.document and type(ui.document.getPageXPointer) == "function"
end

local function page_count(ui)
    local ok, n = pcall(function() return ui.document:getPageCount() end)
    return ok and tonumber(n) or nil
end

-- ── Snapshot ───────────────────────────────────────────────────────

local function count(t) return type(t) == "table" and #t or 0 end

--- How far the analysis reaches (0..1 of the book on the device that made it) and how much it holds.
local function summary(data, pages)
    local furthest = 0
    each_page(data, function(_, k, v)
        if k == "last_fetch_page" and v > furthest then furthest = v end
    end)
    local entities = count(data.characters) + count(data.locations) + count(data.terms)
        + count(data.historical_figures) + count(data.timeline)
    return {
        progress = (pages and pages > 0) and math.min(1, furthest / pages) or 0,
        entities = entities,
        cached_at = tonumber(data.cached_at) or 0,
        pages = pages,
    }
end

--- What a push would change on the server, so an unchanged analysis is not pushed again.
function SyncXray.changeKey(snapshot)
    local s = snapshot and snapshot.summary
    if not s then return nil end
    return table.concat({ s.cached_at, string.format("%.4f", s.progress), s.entities }, ":")
end

--- The open book's analysis, ready to push: { format, summary, pages, positions, data }.
-- nil when X-Ray has nothing for this book yet. Reads the file X-Ray saved (after letting it finish any
-- save in progress), so it works even when X-Ray has already let go of the book on close.
function SyncXray.snapshot(ui)
    local doc_file = ui and ui.document and ui.document.file
    if not doc_file then return nil end
    local xray = SyncXray.instance(ui)
    if xray and xray.cache_manager and type(xray.cache_manager.flushAsyncSaves) == "function" then
        pcall(function() xray.cache_manager:flushAsyncSaves() end)
    end
    local data = load_cache_file(cache_path(doc_file))
    if not data then return nil end
    local pages = page_count(ui)
    local s = summary(data, pages)
    if s.entities == 0 then return nil end -- placeholder cache: nothing analysed yet

    -- where each page the analysis mentions starts in the text
    local positions
    if reflowable(ui) then
        positions = {}
        each_page(data, function(_, _, v)
            local p = math.floor(v)
            if p >= 1 and (not pages or p <= pages) and not positions[tostring(p)] then
                local ok, xp = pcall(function() return ui.document:getPageXPointer(p) end)
                if ok and type(xp) == "string" and xp ~= "" then positions[tostring(p)] = xp end
            end
        end)
    end

    local Device = require("device")
    return {
        format    = SyncXray.FORMAT,
        summary   = s,
        positions = positions,
        data      = dump(data),
        device    = Device.model or "?",
        pushed_at = os.time(),
    }
end

-- ── Furthest analysis wins ─────────────────────────────────────────

--- true when summary `a` should replace `b`: analysed further into the book; level on that, more found.
-- Otherwise not: X-Ray stamps every save with the time, so "newer" would just bounce one analysis
-- between devices forever.
function SyncXray.better(a, b)
    if type(a) ~= "table" then return false end
    if type(b) ~= "table" then return true end
    local ap, bp = tonumber(a.progress) or 0, tonumber(b.progress) or 0
    if math.abs(ap - bp) > 0.005 then return ap > bp end
    return (tonumber(a.entities) or 0) > (tonumber(b.entities) or 0)
end

--- The server's copy beats this device's analysis of the open book?
function SyncXray.remoteWins(remote, ui)
    if type(remote) ~= "table" or remote.format ~= SyncXray.FORMAT then return false end
    local doc_file = ui and ui.document and ui.document.file
    local local_data = doc_file and load_cache_file(cache_path(doc_file))
    if not local_data then return true end
    if local_data.read_only == true then return false end -- X-Ray's protected external data
    return SyncXray.better(remote.summary, summary(local_data, page_count(ui)))
end

--- X-Ray is busy analysing; a copy written now could be saved over when it finishes.
function SyncXray.busy(ui)
    local xray = SyncXray.instance(ui)
    return xray ~= nil and (xray.bg_fetch_active == true)
end

-- Turn the sending device's page numbers into this device's.
local function translate_pages(data, remote, ui)
    local positions = type(remote.positions) == "table" and remote.positions or {}
    local their_pages = tonumber(remote.summary and remote.summary.pages)
    local our_pages = page_count(ui)
    local can_locate = reflowable(ui)
    local cache = {}
    local function convert(v)
        local p = math.floor(v)
        if cache[p] then return cache[p] end
        local out
        local xp = positions[tostring(p)]
        if xp and can_locate then
            local ok, page = pcall(function() return ui.document:getPageFromXPointer(xp) end)
            if ok and tonumber(page) and page >= 1 then out = tonumber(page) end
        end
        if not out and their_pages and our_pages and their_pages > 0 and their_pages ~= our_pages then
            -- no position to go by: scale, rounding down (X-Ray then re-reads a little rather than skipping)
            out = math.max(1, math.floor(p * our_pages / their_pages))
        end
        out = out or p
        cache[p] = out
        return out
    end
    each_page(data, function(t, k, v) t[k] = convert(v) end)
    -- a scroll offset on the other device's layout; X-Ray only writes it
    data.last_fetch_xpointer = nil
end

--- Replace the open book's analysis with `remote` and have X-Ray show it. Returns true when applied.
-- Never writes behind a running X-Ray: without it there is nothing to reload and it might save over us.
function SyncXray.apply(remote, ui)
    local xray = SyncXray.instance(ui)
    local doc_file = ui and ui.document and ui.document.file
    if not (xray and doc_file and xray.cache_manager) then
        logger.warn("Syncest X-Ray: running X-Ray not found, remote analysis not applied")
        return false
    end
    local data = load_lua(remote and remote.data)
    if not data then
        logger.warn("Syncest X-Ray: remote analysis unreadable")
        return false
    end
    translate_pages(data, remote, ui)
    pcall(function() xray.cache_manager:flushAsyncSaves() end)
    local ok, saved = pcall(function() return xray.cache_manager:saveCache(doc_file, data) end)
    if not (ok and saved) then
        logger.warn("Syncest X-Ray: could not save the remote analysis", tostring(saved))
        return false
    end
    pcall(function() xray:autoLoadCache() end)
    logger.info("Syncest X-Ray: adopted analysis from", tostring(remote.device),
        "progress", tostring(remote.summary and remote.summary.progress))
    return true
end

return SyncXray
