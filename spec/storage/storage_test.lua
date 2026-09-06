-- Standalone regression checks: lua spec/storage/storage_test.lua
package.path = './syncest.koplugin/?.lua;' .. package.path
local now = 2000000000
local fs = {}
local function add(path, mode, age)
    fs[path] = { mode = mode or 'file', modification = now - (age or 90000) }
end
local function attrs(path, field)
    return fs[path] and (field and fs[path][field] or fs[path])
end
package.loaded.datastorage = { getSettingsDir = function() return '/settings' end }
package.loaded['libs/libkoreader-lfs'] = {
    attributes = attrs, symlinkattributes = attrs,
    mkdir = function(path) add(path, 'directory', 0); return true end,
    dir = function(dir)
        local names = {}
        for path in pairs(fs) do
            if path:sub(1, #dir + 1) == dir .. '/' then
                local name = path:sub(#dir + 2)
                if not name:find('/') then names[#names + 1] = name end
            end
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded.logger = { warn = function() end, info = function() end, dbg = function() end }
os.time = function() return now end
os.rename = function(old, new)
    assert(fs[old] and not fs[new])
    fs[new], fs[old] = fs[old], nil
    return true
end
os.remove = function(path) fs[path] = nil; return true end
add('/settings', 'directory')
for _, name in ipairs({'syncest_library.sqlite3', 'syncest_library.sqlite3-wal',
        'syncest_library.sqlite3-shm', 'syncest_debug.log'}) do add('/settings/' .. name) end
for _, name in ipairs({'syncest_covers', 'readest_covers', 'syncest_thumbnails',
        'syncest_group_thumbnails', 'syncest_cache'}) do add('/settings/' .. name, 'directory') end
local stale = '/settings/syncest_tmp_1783151959_8077_422010_stats.json.json'
local result = '/settings/syncest_stats_push_1783163251.json'
local recent = '/settings/syncest_progress_push_1999999999.result'
add(stale); add(result); add(recent, 'file', 1)
for _, name in ipairs({'statistics.sqlite3', 'vocabulary_builder.sqlite3',
        'move_to_archive_settings.lua', 'syncest_notes.json'}) do add('/settings/' .. name) end
local link = '/settings/syncest_vocab_pull_1783163251.json'
add(link, 'link')
local S = require('syncest_lib.storage')
S.init()
assert(not fs[stale] and not fs[result])
assert(fs[recent] and fs[link])
assert(fs[S.path('syncest_library')] and fs[S.path('syncest_library') .. '-wal'])
assert(fs[S.path('syncest_covers')] and fs[S.path('readest_covers')])
assert(fs[S.path('syncest_thumbnails')] and fs[S.path('syncest_cache')])
for _, name in ipairs({'statistics.sqlite3', 'vocabulary_builder.sqlite3',
        'move_to_archive_settings.lua', 'syncest_notes.json'}) do assert(fs['/settings/' .. name]) end
local cache_stale = S.tempDir() .. '/syncest_books_push_progress_1783163251.json'
add(cache_stale)
now = now + 3601
S.tempDir()
assert(not fs[cache_stale] and fs[recent])
now = now + 90000
S.tempDir()
assert(not fs[recent])
package.loaded['syncest_lib.storage'] = nil
S = require('syncest_lib.storage')
S.init() -- repeated migration is safe
assert(fs[S.path('syncest_library')])
print('PASS: migration, sidecars, repeat startup, stale cleanup, active/shared/symlink preservation')

-- Exercise the actual WebDAV failure branch with a partially created download.
local downloaded_path
local status = 'throw'
package.loaded['apps/cloudstorage/webdavapi'] = {
    downloadFile = function(_, _, _, _, path)
        downloaded_path = path
        add(path, 'file', 0)
        if status == 'throw' then error('network unreachable') end
        return status
    end,
}
package.loaded.json = { decode = function() return { success = true } end }
package.loaded['socket.http'] = {}
package.loaded.socketutil = {}
package.loaded.socket = { gettime = function() return now end, sleep = function() end }
io.open = function(path)
    if not fs[path] then return nil end
    return { read = function() return '{}' end, close = function() end }
end
local Client = require('webdav_syncclient')
Client._url = function(_, path) return path end
for _, code in ipairs({'throw', 404, 500, 200}) do
    status = code
    local result = Client:_readJSON('stats.json', nil, 0)
    assert(downloaded_path:find('/settings/syncest/cache/tmp/', 1, true) == 1)
    assert(not fs[downloaded_path], 'download leaked for ' .. tostring(code))
    assert((result ~= nil) == (code == 200))
end
print('PASS: network exception, 404, HTTP failure, successful download cleanup')
