-- lua spec/sync/atomic_json_test.lua
package.path = './syncest.koplugin/?.lua;' .. package.path
local Atomic = require('syncest_lib.atomic_json')
local function scenario(options)
    options = options or {}
    local live = 'https://server/stats.json'
    local fs = { [live] = options.missing and nil or 'old', [live .. '.bak'] = 'previous' }
    if options.missing then fs[live] = nil end
    local locked, injected = false, false
    local log = {}
    local function request(method, path, body, headers)
        headers = headers or {}
        log[#log + 1] = {method, path}
        assert(method ~= 'PUT' or path ~= live, 'must never PUT live')
        if options.fail and not injected and options.fail(method, path, headers) then
            injected = true
            if method == 'PUT' then fs[path] = 'partial' end
            error('connection lost')
        end
        if method == 'GET' then
            if options.truncate and path:match('%.tmp$') then return 200, 'partial', {} end
            return fs[path] and 200 or 404, fs[path], {}
        elseif method == 'LOCK' then
            if options.busy then return 423, '', {} end
            if options.competing then fs[live] = 'other-device' end
            locked = true
            return 200, '', { ['lock-token'] = '<valid-token>' }
        elseif method == 'UNLOCK' then
            locked = false; return 204, '', {}
        elseif method == 'PUT' then
            fs[path] = body; return 201, '', {}
        elseif method == 'COPY' then
            assert(locked)
            fs[headers.Destination] = fs[path]; return 201, '', {}
        elseif method == 'MOVE' then
            if headers.Destination == live then
                if options.expire then locked = false; return 412, '', {} end
                if options.create_race then fs[live] = 'other-device'; return 412, '', {} end
                if headers.Overwrite == 'T' then
                    assert(locked and headers['If'] == '<' .. live .. '> (<valid-token>)')
                else assert(not fs[live]) end
            end
            fs[headers.Destination], fs[path] = fs[path], nil
            if options.lost_move_reply and headers.Destination == live then error('lost reply after commit') end
            return 204, '', {}
        elseif method == 'DELETE' then
            fs[path] = nil; return 204, '', {}
        end
        error(method)
    end
    local ok = Atomic.update(live, request, function(old)
        if options.invalid then error('invalid cloud JSON') end
        return (old or 'empty') .. '+local'
    end, 'test')
    assert(not locked, 'lock not released')
    return ok, fs[live], fs[live .. '.bak']
end
local ok, live, backup = scenario()
assert(ok and live == 'old+local' and backup == 'old')
for _, operation in ipairs({'PUT','COPY'}) do
    ok,live,backup=scenario{fail=function(m) return m==operation end}
    assert(not ok and live=='old' and backup=='previous')
end
ok,live=scenario{truncate=true};assert(not ok and live=='old')
ok,live=scenario{fail=function(m,p,h) return m=='MOVE' and h.Destination:match('%.bak$') end}
assert(not ok and live=='old')
ok,live,backup=scenario{fail=function(m,p,h) return m=='MOVE' and h.Destination:match('stats%.json$') end}
assert(not ok and live=='old' and backup=='old')
ok,live=scenario{lost_move_reply=true};assert(ok and live=='old+local')
ok,live=scenario{busy=true};assert(not ok and live=='old')
ok,live=scenario{expire=true};assert(not ok and live=='old')
ok,live=scenario{invalid=true};assert(not ok and live=='old')
ok,live,backup=scenario{competing=true};assert(ok and live=='other-device+local' and backup=='other-device')
ok,live=scenario{missing=true};assert(ok and live=='empty+local')
ok,live=scenario{missing=true,create_race=true};assert(not ok and live=='other-device')
print('PASS: staged verification, interrupted upload/backup/replacement, lost acknowledgement, locks, expiry, competing writers, first publication, invalid source')
