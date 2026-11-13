--[[--
Diagnostic log for chasing intermittent sync timing problems (late chapter pushes, slow manual pushes).

When on, one line per event goes to settings/syncest/diagnostic.log with a millisecond timestamp, so a
late push can be lined up afterwards against page turns, queue state and the network. Off by default;
toggled in Syncest > Diagnostic log. The file rolls over to diagnostic.log.1 at about 512 KB.
]]

local DataStorage = require("datastorage")
local logger = require("logger")

local Diag = {
    enabled = false,
}

local MAX_BYTES = 512 * 1024

function Diag.path()
    return DataStorage:getSettingsDir() .. "/syncest/diagnostic.log"
end

local function now_text()
    local ok, FFIUtil = pcall(require, "ffi/util")
    local sec, usec
    if ok and FFIUtil.gettime then sec, usec = FFIUtil.gettime() end
    sec = tonumber(sec) or os.time()
    local ms = math.floor((tonumber(usec) or 0) / 1000)
    return os.date("%Y-%m-%d %H:%M:%S", sec) .. string.format(".%03d", ms)
end

local function rotate(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return end
    local size = lfs.attributes(path, "size")
    if size and size > MAX_BYTES then
        os.remove(path .. ".1")
        os.rename(path, path .. ".1")
    end
end

--- Append one line: `Diag.log("push", "launched", "notify=", notify)`. Arguments are joined with spaces.
function Diag.log(...)
    if not Diag.enabled then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, " ")
    logger.info("Syncest diag:", line)
    local path = Diag.path()
    pcall(function()
        rotate(path)
        local f = io.open(path, "a")
        if not f then return end
        f:write(now_text(), "  ", line, "\n")
        f:close()
    end)
end

--- Wi-Fi state without any network I/O (isOnline may do a lookup; this only asks the OS).
function Diag.network()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok then return "?" end
    local wifi_ok, wifi = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    local conn_ok, conn = pcall(NetworkMgr.isConnected, NetworkMgr)
    return "wifi=" .. (wifi_ok and tostring(wifi) or "?") .. " connected=" .. (conn_ok and tostring(conn) or "?")
end

function Diag.clear()
    os.remove(Diag.path())
    os.remove(Diag.path() .. ".1")
end

function Diag.read()
    local f = io.open(Diag.path(), "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

return Diag
