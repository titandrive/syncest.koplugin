-- Publish complete JSON with a WebDAV write lock, verified staging files,
-- and a last-good backup. Never PUT over a live document.
local M = {}
local lock_body = [[<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>]]

local function success(code)
    return type(code) == "number" and code >= 200 and code < 300
end

function M.nonce()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(16)
        f:close()
        if bytes and #bytes == 16 then
            return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        end
    end
    return (tostring(os.time()) .. tostring({}) .. tostring(math.random(1000000000)))
        :gsub("[^%w]", "")
end

-- transform(old_body) must validate the old document and return complete JSON.
-- nil means this is the first publication (GET returned 404).
function M.update(url, request, transform, nonce)
    local stage = url .. ".syncest-" .. (nonce or M.nonce()) .. ".tmp"
    local backup_stage = stage .. ".bak"
    local token
    local function checked(method, path, body, headers)
        local code, data, h = request(method, path, body, headers)
        if not success(code) then error(method .. " failed: " .. tostring(code)) end
        return data, h
    end
    local ok, result = xpcall(function()
        local code, old = request("GET", url)
        local exists = code == 200
        if code ~= 404 and not exists then error("stats read failed: " .. tostring(code)) end
        if exists then
            local _, headers = checked("LOCK", url, lock_body, {
                ["Content-Type"] = "application/xml", Depth = "0", Timeout = "Second-180",
            })
            token = headers["lock-token"] or headers["Lock-Token"]
            if type(token) ~= "string" or not token:match("^<[^<>%s]+>$") then
                token = nil
                error("server did not return a usable write lock")
            end
            -- Re-read after acquiring the lock so another device's update is merged.
            old = checked("GET", url)
        else
            old = nil
        end
        local encoded = transform(old)
        assert(type(encoded) == "string" and #encoded > 0, "empty JSON publication")
        checked("PUT", stage, encoded, { ["If-None-Match"] = "*" })
        assert(checked("GET", stage) == encoded, "staged upload verification failed")
        if exists then
            checked("COPY", url, nil, {
                Destination = backup_stage, Overwrite = "F",
            })
            assert(checked("GET", backup_stage) == old, "backup verification failed")
            checked("MOVE", backup_stage, nil, { Destination = url .. ".bak", Overwrite = "T" })
        end
        local headers = { Destination = url, Overwrite = exists and "T" or "F" }
        if token then headers["If"] = "<" .. url .. "> (" .. token .. ")" end
        -- An exception/timeout here may mean MOVE succeeded. Verify live bytes;
        -- never retry an overwrite blindly after losing its response.
        pcall(request, "MOVE", stage, nil, headers)
        assert(checked("GET", url) == encoded, "published upload not confirmed; retry with a fresh merge")
        return true
    end, debug.traceback)
    -- Cleanup is best-effort. A killed process leaves only staging files and
    -- an expiring server lock; it cannot leave a partially uploaded live file.
    pcall(request, "DELETE", stage)
    pcall(request, "DELETE", backup_stage)
    if token then pcall(request, "UNLOCK", url, nil, { ["Lock-Token"] = token }) end
    if not ok then return false, result end
    return result
end

return M
