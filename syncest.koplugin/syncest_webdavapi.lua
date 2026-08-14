local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local WebDavApi = {}

local function trim_slashes(value)
    return tostring(value or ""):gsub("^/+", ""):gsub("/+$", "")
end

function WebDavApi:getJoinedPath(address, path)
    local encoded = util.urlEncode(path or "", "/") or ""
    return tostring(address or ""):gsub("/+$", "") .. "/" .. trim_slashes(encoded)
end

local function request(opts)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request(opts))
    socketutil:reset_timeout()
    return code, headers, status
end

function WebDavApi:downloadFile(file_url, user, pass, local_path, progress_callback)
    local file = io.open(local_path, "w")
    if not file then return nil end
    local sink = ltn12.sink.file(file)
    if progress_callback then
        sink = socketutil.chainSinkWithProgressCallback(sink, progress_callback)
    end
    local code, headers = request{
        url = file_url,
        method = "GET",
        sink = sink,
        user = user,
        password = pass,
    }
    return code, headers and headers.etag
end

function WebDavApi:uploadFile(file_url, user, pass, local_path, etag)
    local file = io.open(local_path, "r")
    if not file then return nil end
    if type(etag) == "string" then etag = etag:gsub("^%s*[Ww]/", "") end
    local headers = { ["Content-Length"] = lfs.attributes(local_path, "size") }
    if etag then headers["If-Match"] = etag end
    return request{
        url = file_url,
        method = "PUT",
        source = ltn12.source.file(file),
        user = user,
        password = pass,
        headers = headers,
    }
end

function WebDavApi:createFolder(folder_url, user, pass)
    return request{
        url = folder_url,
        method = "MKCOL",
        user = user,
        password = pass,
    }
end

function WebDavApi:listFolder(address, user, pass, folder_path, folder_mode)
    local path = trim_slashes(folder_path)
    local url = tostring(address or ""):gsub("/+$", "")
    if path ~= "" then url = self:getJoinedPath(url, path) end
    url = url:gsub("/+$", "") .. "/"
    local body = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/></a:prop></a:propfind>]]
    local response = {}
    local code = request{
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Depth"] = "1",
            ["Content-Length"] = #body,
        },
        user = user,
        password = pass,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    if type(code) ~= "number" or code < 200 or code >= 300 then return nil end

    local items = {}
    for item in table.concat(response):gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local href = item:match("<[^:]*:href[^>]*>(.-)</[^:]*:href>")
        href = href and util.urlDecode(href)
        local name = href and ffiUtil.basename(util.htmlEntitiesToUtf8(href))
        local is_file = item:find("<[^:]*:resourcetype%s*/>")
            or item:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>")
        local is_folder = item:find("<[^:]*:collection[^<]*/>")
            or item:find("<[^:]*:collection>%s*</[^:]*:collection>")
        if name and name ~= "" and is_file then
            local size = tonumber(item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>"))
            items[#items + 1] = {
                text = name,
                url = path .. "/" .. name,
                type = "file",
                filesize = size,
                mandatory = size and util.getFriendlySize(size) or nil,
            }
        elseif name and name ~= "" and is_folder then
            items[#items + 1] = {
                text = name .. "/",
                url = path .. "/" .. name,
                type = "folder",
            }
        end
    end
    if folder_mode then
        table.insert(items, 1, { text = "", url = folder_path, type = "folder_long_press", bold = true })
    end
    return items
end

return WebDavApi
