-- Syncest-owned storage. Shared KOReader databases stay in settings/.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local M = {}
local initialized = false
local last_cleanup
local MAX_AGE = 24 * 60 * 60
local locations = {
    syncest_library = "syncest_library.sqlite3",
    syncest_covers = "covers",
    readest_covers = "downloaded_covers",
    syncest_thumbnails = "cache/thumbnails",
    syncest_group_thumbnails = "cache/group_thumbnails",
    syncest_cache = "cache/updater",
    syncest_debug = "debug.log",
}
local result_prefixes = {
    "progress_push", "progress_pull", "stats_push", "stats_pull",
    "vocab_push", "vocab_pull", "annotations_push", "annotations_pull",
    "all_annotations_push", "all_annotations_pull", "marker_ensure",
    "books_push", "books_pull", "books_both", "books_push_progress",
    "books_pull_progress", "books_both_progress", "library_refresh",
}

local function root()
    return DataStorage:getSettingsDir() .. "/syncest"
end

local function mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local ok, err = lfs.mkdir(path)
    assert(ok, "Syncest cannot create " .. path .. ": " .. tostring(err))
end

local function move(old, new)
    if not lfs.symlinkattributes(old) then return end
    -- Never overwrite existing data on a repeated/partially completed migration.
    assert(not lfs.symlinkattributes(new), "Syncest migration conflict: " .. new)
    local ok, err = os.rename(old, new)
    assert(ok, "Syncest cannot migrate " .. old .. ": " .. tostring(err))
end

function M.isTemporary(name)
    if name:match("^syncest_tmp_%d+_[%w_.%-]+%.json$")
            or name:match("^syncest_book_marker_%d+_%d+%.json$")
            or name:match("^syncest_cover_download_%x+%.json$") then
        return true
    end
    for _, prefix in ipairs(result_prefixes) do
        if name:match("^syncest_" .. prefix .. "_%d+%.json$")
                or (prefix == "progress_push"
                    and name:match("^syncest_progress_push_%d+%.result$")) then
            return true
        end
    end
    return false
end

local function clean(dir, now)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if M.isTemporary(name) then
            local path = dir .. "/" .. name
            local attr = lfs.symlinkattributes(path)
            if attr and attr.mode == "file" and now - attr.modification > MAX_AGE then
                local ok, err = os.remove(path)
                if not ok then logger.warn("Syncest cleanup failed", path, err) end
            end
        end
    end
end

function M.init()
    if initialized then return end
    mkdir(root())
    mkdir(root() .. "/cache")
    mkdir(root() .. "/cache/tmp")
    local old = DataStorage:getSettingsDir() .. "/"
    -- Move SQLite sidecars before the database; resume safely if interrupted.
    -- This runs before Syncest opens its library database or starts workers.
    for _, suffix in ipairs({ "-wal", "-shm", "-journal", "" }) do
        move(old .. "syncest_library.sqlite3" .. suffix,
            root() .. "/syncest_library.sqlite3" .. suffix)
    end
    for _, name in ipairs({ "syncest_covers", "readest_covers",
            "syncest_thumbnails", "syncest_group_thumbnails", "syncest_cache" }) do
        move(old .. name, root() .. "/" .. locations[name])
    end
    move(old .. "syncest_debug.log", root() .. "/debug.log")
    initialized = true
    M.cleanup()
end

function M.cleanup()
    local now = os.time()
    if last_cleanup and now - last_cleanup < 3600 then return end
    clean(DataStorage:getSettingsDir(), now)
    clean(root() .. "/cache/tmp", now)
    last_cleanup = now
end

function M.path(name)
    M.init()
    assert(locations[name], "Unknown Syncest storage location: " .. tostring(name))
    return root() .. "/" .. locations[name]
end

function M.tempDir()
    M.init()
    M.cleanup()
    return root() .. "/cache/tmp"
end

-- Database rows can contain absolute cover paths from before migration.
function M.coverMoves()
    local old = DataStorage:getSettingsDir() .. "/"
    return {
        { old .. "syncest_covers/", root() .. "/covers/" },
        { old .. "readest_covers/", root() .. "/downloaded_covers/" },
    }
end

return M
