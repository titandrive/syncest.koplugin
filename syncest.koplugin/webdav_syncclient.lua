local DataStorage = require("datastorage")
local WebDavApi = require("apps/cloudstorage/webdavapi")
local json = require("json")
local logger = require("logger")
local http = require("socket.http")
local socketutil = require("socketutil")
local ok_socket, socket = pcall(require, "socket")
local EXTS = require("syncest_lib.exts")

-- LuaSocket reads http.TIMEOUT on every new TCP connection, so this caps
-- the OS-level TCP connect + transfer time and prevents ANR crashes when
-- the WebDAV server is unreachable (e.g. VPN is off).
local SYNC_TIMEOUT = 3
local PROGRESS_PUSH_TIMEOUT = 2
local PROGRESS_PULL_TIMEOUT = 2
local SYNC_TOTAL_TIMEOUT = socketutil.FILE_TOTAL_TIMEOUT or 60
local SYNC_RETRIES = 2
-- library.json can be materially slower through the Tailscale/WebDAV route
-- used by e-ink devices. It is an explicit library operation, so allow the
-- transfer to use the full request budget instead of the short background
-- sync timeout (which otherwise aborts a healthy response after 3 seconds).
local LIBRARY_TIMEOUT = 60

local WebDavSyncClient = {}

local READ_MISSING = {}
local READ_FAILED = {}

local function now_ms()
    return math.floor(os.time() * 1000)
end

local function normalize_authors(authors)
    if type(authors) == "table" then
        return authors
    end
    if type(authors) == "string" and authors ~= "" then
        local out = {}
        for author in authors:gmatch("[^\n]+") do
            out[#out + 1] = author:gsub("^%s*(.-)%s*$", "%1")
        end
        return out
    end
    return {}
end

local function normalize_identifier(identifier)
    identifier = tostring(identifier or "")
    if identifier:match("urn:") then
        return identifier:match("([^:]+)$")
    elseif identifier:match(":") then
        return identifier:match("^[^:]+:(.+)$")
    end
    return identifier
end

local function identifier_type(raw)
    local lower = tostring(raw or ""):lower()
    if lower:find("isbn", 1, true) then return "isbn" end
    if lower:find("calibre", 1, true) then return "calibre" end
    if lower:find("uuid", 1, true) then return "uuid" end
    if lower:find("google", 1, true) then return "google" end
    local prefix = lower:match("^%s*([^:%s]+):")
    return prefix or "unknown"
end

local function split_identifiers(value, out)
    out = out or {}
    if type(value) == "table" then
        for _, v in pairs(value) do split_identifiers(v, out) end
        return out
    end
    if type(value) ~= "string" and type(value) ~= "number" then
        return out
    end
    for raw in tostring(value):gmatch("[^\n]+") do
        raw = raw:gsub("^%s*(.-)%s*$", "%1")
        if raw ~= "" then
            out[#out + 1] = {
                type = identifier_type(raw),
                value = normalize_identifier(raw),
                raw = raw,
            }
        end
    end
    return out
end

local function extract_isbns(value, out, force_context)
    out = out or {}
    local value_type = type(value)
    if value_type == "table" then
        for _, v in pairs(value) do extract_isbns(v, out, force_context) end
        return out
    end
    if value_type ~= "string" and value_type ~= "number" then
        return out
    end

    local text = tostring(value)
    local lower = text:lower()
    local isbn_context = force_context or lower:find("isbn", 1, true) ~= nil
    for candidate in text:gmatch("[%dXx][%dXx%-%s]*[%dXx]") do
        local cleaned = candidate:gsub("[^%dXx]", ""):upper()
        if #cleaned == 10 and isbn_context then
            out.isbn10 = out.isbn10 or cleaned
        elseif #cleaned == 13 and (isbn_context or cleaned:match("^97[89]")) then
            out.isbn13 = out.isbn13 or cleaned
        end
    end
    out.isbn = out.isbn or out.isbn13 or out.isbn10
    return out
end

local function promoted_identifiers(all_identifiers)
    local out = {}
    for _, item in ipairs(all_identifiers or {}) do
        if item.type == "google" then
            out.googleBooksId = out.googleBooksId or item.value
        elseif item.type == "calibre" then
            out.calibreId = out.calibreId or item.value
        elseif item.type == "uuid" then
            out.uuid = out.uuid or item.value
        end
    end
    return out
end

local function marker_metadata(metadata)
    if type(metadata) ~= "table" then return {} end
    local copied = {}
    local skip = {
        identifiers = true,
        isbn = true,
        ISBN = true,
        isbn10 = true,
        isbn13 = true,
        google = true,
        googleBooksId = true,
        google_books_id = true,
        calibre = true,
        calibreId = true,
        calibre_id = true,
        uuid = true,
        UUID = true,
    }
    for k, v in pairs(metadata) do
        if not skip[k] then copied[k] = v end
    end
    return copied
end

local function is_array(t)
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true, count
end

local function encode_pretty_json(value, indent)
    indent = indent or ""
    if type(value) ~= "table" then return json.encode(value) end

    local child_indent = indent .. "  "
    local array, count = is_array(value)
    local parts = {}
    if array then
        for i = 1, count do
            parts[#parts + 1] = child_indent .. encode_pretty_json(value[i], child_indent)
        end
        if #parts == 0 then return "[]" end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end

    local keys = {}
    for k, v in pairs(value) do
        if v ~= nil then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = child_indent .. json.encode(tostring(k)) .. ": "
            .. encode_pretty_json(value[k], child_indent)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function safe_title_filename(title)
    local name = tostring(title or ""):gsub("^%s*(.-)%s*$", "%1")
    if name == "" then name = "Untitled" end
    name = name:gsub('[<>:|"?*\\/%c]', "_")
    name = name:gsub("%s+", " ")
    name = name:gsub("^%s*(.-)%s*$", "%1")
    if #name > 120 then name = name:sub(1, 120) end
    if name == "" or name:match("^_+$") then name = "Untitled" end
    return "_" .. name .. ".json"
end

local function withTimeout(label, fn, block_timeout, retries)
    block_timeout = block_timeout or SYNC_TIMEOUT
    retries = retries == nil and SYNC_RETRIES or retries
    local prev_timeout = http.TIMEOUT
    local prev_file_block_timeout = socketutil.FILE_BLOCK_TIMEOUT
    local prev_file_total_timeout = socketutil.FILE_TOTAL_TIMEOUT
    http.TIMEOUT = block_timeout
    socketutil.FILE_BLOCK_TIMEOUT = block_timeout
    socketutil.FILE_TOTAL_TIMEOUT = SYNC_TOTAL_TIMEOUT
    local started = now_ms()
    logger.info("WebDavSyncClient " .. label .. ": start timeout=" .. tostring(block_timeout)
        .. " total_timeout=" .. tostring(SYNC_TOTAL_TIMEOUT))
    local ok, a, b, c
    for attempt = 1, retries + 1 do
        ok, a, b, c = pcall(fn)
        local result = tostring(a or "")
        local transient = not ok
            or result:find("No address associated with hostname", 1, true)
            or result:lower():find("temporary failure", 1, true)
            or result:lower():find("network unreachable", 1, true)
            or result:lower():find("timeout", 1, true)
            or result:lower():find("closed", 1, true)
        if not transient or attempt > retries then
            break
        end
        logger.warn("WebDavSyncClient " .. label .. ": transient failure attempt="
            .. tostring(attempt) .. " result=" .. result)
        if ok_socket and socket and socket.sleep then
            socket.sleep(attempt * 2)
        end
    end
    http.TIMEOUT = prev_timeout
    socketutil.FILE_BLOCK_TIMEOUT = prev_file_block_timeout
    socketutil.FILE_TOTAL_TIMEOUT = prev_file_total_timeout
    logger.info("WebDavSyncClient " .. label .. ": done ok="
        .. tostring(ok) .. " result=" .. tostring(a)
        .. " duration_ms=" .. tostring(now_ms() - started))
    return ok, a, b, c
end

function WebDavSyncClient:new(o)
    local t = setmetatable({}, { __index = self })
    t.server   = o.server
    t.username = o.server.username or ""
    t.password = o.server.password or ""
    t._ensured_folders = {}
    return t
end

-- ── URL helpers ────────────────────────────────────────────────────

function WebDavSyncClient:_url(rel_path)
    local base = WebDavApi:getJoinedPath(
        self.server.address, self.server.url or "")
    if rel_path and rel_path ~= "" then
        return WebDavApi:getJoinedPath(base, rel_path)
    end
    return base
end

local function tmp_path(rel_path)
    local suffix = tostring(rel_path or "root"):gsub("[^%w%.%-_]", "_")
    local now = ok_socket and socket.gettime and socket.gettime() or os.time()
    local nonce = tostring(now):gsub("[^%w]", "_") .. "_" .. tostring(math.random(1000000))
    return DataStorage:getSettingsDir() .. "/syncest_tmp_" .. nonce .. "_" .. suffix .. ".json"
end

function WebDavSyncClient:_markPathExists(rel_path)
    self._base_folder_ensured = true
    if not self._ensured_folders then self._ensured_folders = {} end
    local parent = rel_path and rel_path:match("^(.*)/[^/]+$")
    while parent and parent ~= "" do
        self._ensured_folders[parent] = true
        parent = parent:match("^(.*)/[^/]+$")
    end
end

-- ── JSON read/write ────────────────────────────────────────────────

function WebDavSyncClient:_readJSON(rel_path, block_timeout, retries)
    local tmp = tmp_path(rel_path)
    local ok, code = withTimeout("readJSON " .. tostring(rel_path), function()
        return WebDavApi:downloadFile(
            self:_url(rel_path), self.username, self.password, tmp)
    end, block_timeout, retries)
    if not ok then
        logger.warn("WebDavSyncClient _readJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return nil, READ_FAILED
    end
    if code == 404 then
        os.remove(tmp)
        return nil, READ_MISSING
    end
    if code ~= 200 then
        logger.dbg("WebDavSyncClient _readJSON: " .. rel_path .. " → " .. tostring(code))
        os.remove(tmp)
        return nil, READ_FAILED
    end
    self:_markPathExists(rel_path)
    local f = io.open(tmp, "r")
    if not f then return nil, READ_FAILED end
    local data = f:read("*a")
    f:close()
    os.remove(tmp)
    if not data or data == "" then return nil, READ_MISSING end
    local ok, parsed = pcall(json.decode, data)
    if not ok then
        logger.warn("WebDavSyncClient _readJSON: parse error for " .. rel_path)
        return nil, READ_FAILED
    end
    return parsed
end

function WebDavSyncClient:_writeJSON(rel_path, data, block_timeout)
    logger.info("WebDavSyncClient writeJSON " .. tostring(rel_path) .. ": encoding")
    local ok, encoded = pcall(json.encode, data)
    if not ok then
        logger.warn("WebDavSyncClient _writeJSON: encode error: " .. tostring(encoded))
        return false
    end
    local tmp = tmp_path(rel_path)
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    local full_url = self:_url(rel_path)
    local ok2, code = withTimeout("writeJSON " .. tostring(rel_path), function()
        return WebDavApi:uploadFile(full_url, self.username, self.password, tmp)
    end, block_timeout)
    os.remove(tmp)
    if not ok2 then
        logger.warn("WebDavSyncClient _writeJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return false
    end
    local success = type(code) == "number" and code >= 200 and code < 300
    if not success then
        logger.warn("WebDavSyncClient _writeJSON: upload failed code=" .. tostring(code) .. " url=" .. full_url)
    else
        self:_markPathExists(rel_path)
    end
    return success
end

function WebDavSyncClient:_writePrettyJSON(rel_path, data)
    logger.info("WebDavSyncClient writePrettyJSON " .. tostring(rel_path) .. ": encoding")
    local ok, encoded = pcall(encode_pretty_json, data)
    if not ok then
        logger.warn("WebDavSyncClient _writePrettyJSON: encode error: " .. tostring(encoded))
        return false
    end
    encoded = encoded .. "\n"
    local tmp = tmp_path(rel_path)
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    local full_url = self:_url(rel_path)
    local ok2, code = withTimeout("writePrettyJSON " .. tostring(rel_path), function()
        return WebDavApi:uploadFile(full_url, self.username, self.password, tmp)
    end)
    os.remove(tmp)
    if not ok2 then
        logger.warn("WebDavSyncClient _writePrettyJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return false
    end
    local success = type(code) == "number" and code >= 200 and code < 300
    if not success then
        logger.warn("WebDavSyncClient _writePrettyJSON: upload failed code=" .. tostring(code) .. " url=" .. full_url)
    else
        self:_markPathExists(rel_path)
    end
    return success
end

function WebDavSyncClient:_writeBookMarker(folder, book)
    if not folder or type(book) ~= "table" then return true end
    local hash = book.bookHash or book.hash or book.book_hash
    if not hash then return true end
    local meta = book.bookMetadata or book.metadata or {}
    local title = meta.title or book.title or book.sourceTitle or book.source_title
    if not title or title == "" then
        logger.warn("WebDavSyncClient _writeBookMarker: missing title for "
            .. tostring(hash))
        return true
    end
    local metadata = meta.metadata or {}
    local all_identifiers = meta.allIdentifiers or split_identifiers({
        meta.identifiers,
        metadata.identifiers,
        metadata.isbn,
        metadata.ISBN,
        metadata.isbn10,
        metadata.isbn13,
    })
    local ids = promoted_identifiers(all_identifiers)
    ids.googleBooksId = ids.googleBooksId
        or metadata.googleBooksId or metadata.google_books_id or metadata.google
        or meta.googleBooksId or meta.google_books_id or meta.google
    ids.calibreId = ids.calibreId
        or metadata.calibreId or metadata.calibre_id or metadata.calibre
        or meta.calibreId or meta.calibre_id or meta.calibre
    ids.uuid = ids.uuid or metadata.uuid or metadata.UUID or meta.uuid or meta.UUID
    local isbns = extract_isbns({
        all_identifiers,
        metadata.identifiers,
        meta.identifiers,
    })
    extract_isbns(meta.isbn, isbns, true)
    extract_isbns(metadata.isbn, isbns, true)
    extract_isbns(metadata.ISBN, isbns, true)
    extract_isbns(metadata.isbn10, isbns, true)
    extract_isbns(metadata.isbn13, isbns, true)
    ids.isbn = isbns.isbn

    local format = meta.format or book.format
    local ext = format and EXTS[format]
    local marker = {
        bookHash = hash,
        title = title or "",
        author = meta.author or book.author,
        authors = normalize_authors(meta.authors or book.authors or book.author),
        isbn = ids.isbn,
        googleBooksId = ids.googleBooksId,
        calibreId = ids.calibreId,
        uuid = ids.uuid,
        format = format,
        fileName = meta.fileName or book.fileName,
        sourceTitle = meta.sourceTitle or book.sourceTitle or book.source_title,
        bookFile = ext and string.format("%s.%s", hash, ext) or nil,
        coverFile = "cover.png",
        metadata = marker_metadata(metadata),
        bookUpdatedAt = book.updatedAt,
        updatedAt = os.time() * 1000,
    }
    return self:_writePrettyJSON(folder .. "/" .. safe_title_filename(title), marker)
end

function WebDavSyncClient:_ensureBookMarker(folder, book)
    if not folder or type(book) ~= "table" then return true end
    local meta = book.bookMetadata or book.metadata or {}
    local title = meta.title or book.title or book.sourceTitle or book.source_title
    if not title or title == "" then return true end
    local marker_path = folder .. "/" .. safe_title_filename(title)
    local _existing, read_status = self:_readJSON(marker_path)
    if read_status == READ_MISSING then
        return self:_writeBookMarker(folder, book)
    end
    return read_status ~= READ_FAILED
end

function WebDavSyncClient:ensureSyncMarker(book)
    if type(book) ~= "table" then return true end
    local hash = book.bookHash or book.hash or book.book_hash
    if not hash then return true end
    return self:_ensureBookMarker("sync/" .. hash, book)
end

local function strip_marker_metadata(configs)
    local out = {}
    for i, config in ipairs(configs or {}) do
        local copy = {}
        for k, v in pairs(config) do
            if k ~= "bookMetadata" then copy[k] = v end
        end
        out[i] = copy
    end
    return out
end

local function strip_note_marker_metadata(notes)
    local out = {}
    for i, note in ipairs(notes or {}) do
        local copy = {}
        for k, v in pairs(note) do
            if k ~= "bookMetadata" then copy[k] = v end
        end
        out[i] = copy
    end
    return out
end

-- MKCOL, tolerating 405 (already exists) and 301/302 redirects.
function WebDavSyncClient:_ensureFolder(rel_path)
    if self._ensured_folders and self._ensured_folders[rel_path] then
        logger.info("WebDavSyncClient ensureFolder " .. tostring(rel_path)
            .. ": cached")
        return true
    end
    local ok, code = withTimeout("ensureFolder " .. tostring(rel_path), function()
        return WebDavApi:createFolder(
            self:_url(rel_path), self.username, self.password, "")
    end)
    if not ok then return false end
    local success = code == 201 or code == 405
    if success then
        if not self._ensured_folders then self._ensured_folders = {} end
        self._ensured_folders[rel_path] = true
    end
    return success
end

-- ── Merge helpers ──────────────────────────────────────────────────

-- Union-merge notes by id. Tombstone (deletedAt) always wins; otherwise
-- the note with the newer updatedAt replaces the existing one.
function WebDavSyncClient:_mergeNotes(existing, incoming)
    local by_id = {}
    for _, n in ipairs(existing or {}) do
        if n.id then by_id[n.id] = n end
    end
    for _, n in ipairs(incoming or {}) do
        if n.id then
            local ex = by_id[n.id]
            if not ex or n.deletedAt
                    or (n.updatedAt or 0) > (ex.updatedAt or 0) then
                by_id[n.id] = n
            end
        end
    end
    local result = {}
    for _, n in pairs(by_id) do result[#result + 1] = n end
    return result
end

function WebDavSyncClient:_addMissingBookmarkTombstones(existing, incoming, current_ids, book_hash)
    if type(current_ids) ~= "table" then return incoming end
    local present_ids = {}
    for id in pairs(current_ids) do present_ids[id] = true end
    for _, n in ipairs(incoming or {}) do
        if n.id and n.type == "bookmark" and not n.deletedAt and not n.deleted_at then
            present_ids[n.id] = true
        end
    end
    local now = now_ms()
    for _, n in ipairs(existing or {}) do
        if n.id and n.type == "bookmark"
                and not n.deletedAt and not n.deleted_at
                and not present_ids[n.id] then
            local tombstone = {}
            for k, v in pairs(n) do tombstone[k] = v end
            tombstone.bookHash = tombstone.bookHash or book_hash
            tombstone.deletedAt = now
            tombstone.updatedAt = now
            incoming[#incoming + 1] = tombstone
        end
    end
    return incoming
end

-- Union-merge book library rows by hash; newer updatedAt wins.
function WebDavSyncClient:_mergeBooks(existing, incoming)
    local by_hash = {}
    for _, b in ipairs(existing or {}) do
        local h = b.bookHash or b.hash
        if h then by_hash[h] = b end
    end
    for _, b in ipairs(incoming or {}) do
        local h = b.bookHash or b.hash
        if h then
            local ex = by_hash[h]
            if not ex or (b.updatedAt or 0) > (ex.updatedAt or 0) then
                by_hash[h] = b
            end
        end
    end
    local result = {}
    for _, b in pairs(by_hash) do result[#result + 1] = b end
    return result
end

-- Union-merge vocab words by word; higher review_count wins, then newer review_time.
function WebDavSyncClient:_mergeVocab(existing, incoming)
    local by_word = {}
    for _, w in ipairs(existing or {}) do
        if w.word then by_word[w.word] = w end
    end
    for _, w in ipairs(incoming or {}) do
        if w.word then
            local ex = by_word[w.word]
            if not ex
                    or (w.review_count or 0) > (ex.review_count or 0)
                    or ((w.review_count or 0) == (ex.review_count or 0)
                        and (w.review_time or 0) > (ex.review_time or 0)) then
                by_word[w.word] = w
            end
        end
    end
    local result = {}
    for _, w in pairs(by_word) do result[#result + 1] = w end
    return result
end

-- Union-merge stat books by book_hash; union stat pages by
-- (book_hash, page, start_time), taking the longer duration.
function WebDavSyncClient:_mergeStats(existing, incoming_books, incoming_pages)
    local bmap = {}
    for _, b in ipairs(existing.statBooks or {}) do
        if b.book_hash then bmap[b.book_hash] = b end
    end
    for _, b in ipairs(incoming_books or {}) do
        if b.book_hash then bmap[b.book_hash] = b end
    end
    local merged_books = {}
    for _, b in pairs(bmap) do merged_books[#merged_books + 1] = b end

    local pmap = {}
    for _, p in ipairs(existing.statPages or {}) do
        local key = (p.book_hash or "") .. "|" .. (p.page or "") .. "|" .. (p.start_time or "")
        pmap[key] = p
    end
    for _, p in ipairs(incoming_pages or {}) do
        local key = (p.book_hash or "") .. "|" .. (p.page or "") .. "|" .. (p.start_time or "")
        local ex = pmap[key]
        if not ex or (tonumber(p.duration) or 0) > (tonumber(ex.duration) or 0) then
            pmap[key] = p
        end
    end
    local merged_pages = {}
    for _, p in pairs(pmap) do merged_pages[#merged_pages + 1] = p end

    return merged_books, merged_pages
end

-- ── Public API ─────────────────────────────────────────────────────

-- WebDAV layout under {base_path}/:
--   library.json              — book catalog (wire-format rows)
--   sync/{book_hash}/
--     progress.json           — {configs: [...], readingStatus?, readingStatusUpdatedAt?}
--     progress-history/
--       devices.json          — {deviceIds: [...]}
--       {device_id}.json      — {version, deviceId, deviceName, entries: [...]}
--     annotations.json        — {notes: [...]}
--   stats.json                — {statBooks: [...], statPages: [...]}
--   vocab.json                — {words: [...]}
--   books/{book_hash}/
--     {hash}.{ext}            — book file
--     cover.png

function WebDavSyncClient:pullChanges(params, callback)
    logger.info("WebDavSyncClient pullChanges: type=" .. tostring(params and params.type)
        .. " book=" .. tostring(params and params.book)
        .. " since=" .. tostring(params and params.since))
    local t     = params.type
    local book  = params.book
    local since = tonumber(params.since) or 0

    if t == "configs" then
        local data, read_status = self:_readJSON(
            "sync/" .. book .. "/progress.json", PROGRESS_PULL_TIMEOUT,
            params.retries)
        if read_status == READ_FAILED then
            callback(false, {}, "read_failed")
            return
        end
        callback(true, data or {configs = {}}, 200)

    elseif t == "notes" then
        local data, read_status = self:_readJSON("sync/" .. book .. "/annotations.json")
        if read_status == READ_FAILED then
            callback(false, {}, "read_failed")
            return
        end
        callback(true, data or {notes = {}}, 200)

    elseif t == "stats" then
        local data, read_status = self:_readJSON("stats.json")
        if data then
            -- Stats start_time values and the pull cursor are Unix seconds.
            -- Older Syncest builds accidentally persisted milliseconds.
            if since > 100000000000 then since = math.floor(since / 1000) end
            -- Filter pages newer than the cursor; stamp updated_at_ms so the
            -- stats module can advance its pull cursor.
            if since > 0 and data.statPages then
                local filtered = {}
                for _, p in ipairs(data.statPages) do
                    if (tonumber(p.start_time) or 0) > since then
                        filtered[#filtered + 1] = p
                    end
                end
                data.statPages = filtered
            end
            for _, p in ipairs(data.statPages or {}) do
                p.updated_at_ms = (tonumber(p.start_time) or 0) * 1000
            end
            callback(true, data, 200)
        else
            if read_status == READ_FAILED then
                callback(false, {}, "read_failed")
                return
            end
            callback(true, {statBooks = {}, statPages = {}}, 200)
        end

    elseif t == "vocab" then
        local data, read_status = self:_readJSON("vocab.json")
        if read_status == READ_FAILED then
            callback(false, {}, "read_failed")
            return
        end
        callback(true, data or {words = {}}, 200)

    else
        callback(false, nil, 400)
    end
end

local function progress_history_path(book_hash, suffix)
    return "sync/" .. tostring(book_hash) .. "/progress-history/" .. suffix
end

function WebDavSyncClient:_appendProgressHistory(book_hash, history)
    if not book_hash or type(history) ~= "table"
            or not history.deviceId or type(history.entry) ~= "table" then
        return false
    end

    local device_id = tostring(history.deviceId):gsub("[^%w_.%-]", "_")
    if device_id == "" then return false end
    local base = "sync/" .. tostring(book_hash) .. "/progress-history"
    local device_path = progress_history_path(book_hash, device_id .. ".json")
    local remote, read_status = self:_readJSON(device_path)
    if remote == nil and read_status ~= READ_MISSING then return false end
    remote = remote or {}
    local registry_confirmed = remote.registryConfirmed == true
    local entries = type(remote.entries) == "table" and remote.entries or {}
    local entry_id = tostring(history.entry.id or "")
    local found = false
    for _, existing in ipairs(entries) do
        if entry_id ~= "" and tostring(existing.id or "") == entry_id then
            found = true
            break
        end
    end
    if not found then entries[#entries + 1] = history.entry end
    table.sort(entries, function(a, b)
        return (tonumber(a.timestamp) or 0) > (tonumber(b.timestamp) or 0)
    end)
    local limit = math.max(1, tonumber(history.limit) or 100)
    -- Retain the newest entries independently by source. A busy automatic
    -- sync stream must not evict the manual checkpoints users explicitly
    -- saved for recovery. Legacy/missing source values count as automatic,
    -- matching the progress-history UI.
    local retained = {}
    local source_counts = { manual = 0, auto = 0 }
    for _, entry in ipairs(entries) do
        local source = entry.source == "manual" and "manual" or "auto"
        if source_counts[source] < limit then
            retained[#retained + 1] = entry
            source_counts[source] = source_counts[source] + 1
        end
    end
    entries = retained
    local device_body = {
        version = 1,
        deviceId = device_id,
        deviceName = history.deviceName,
        entries = entries,
        registryConfirmed = registry_confirmed,
    }
    if not self:_writeJSON(device_path, device_body) then
        -- Normal pushes avoid three redundant folder probes. Repair the
        -- hierarchy only when a first write proves it is missing (fresh
        -- setup, cloud wipe, or manual server-side deletion).
        if not (self:_ensureFolder("sync")
                and self:_ensureFolder("sync/" .. tostring(book_hash))
                and self:_ensureFolder(base)
                and self:_writeJSON(device_path, device_body)) then
            return false
        end
    end

    -- A confirmed per-device file can skip devices.json entirely. The marker
    -- lives remotely, so a cloud wipe naturally returns to registration.
    if registry_confirmed then return true end

    -- The small registry lets clients discover device-owned files without
    -- depending on WebDAV directory-listing behavior, which varies by server.
    local registry_path = progress_history_path(book_hash, "devices.json")
    local registry, registry_status = self:_readJSON(registry_path)
    if registry == nil and registry_status ~= READ_MISSING then return false end
    registry = registry or {}
    local device_ids = type(registry.deviceIds) == "table"
        and registry.deviceIds or {}
    local registered = false
    for _, existing_id in ipairs(device_ids) do
        if tostring(existing_id) == device_id then registered = true break end
    end
    if not registered then
        device_ids[#device_ids + 1] = device_id
        table.sort(device_ids)
        if not self:_writeJSON(
                registry_path, {version = 1, deviceIds = device_ids}) then
            return false
        end
    end
    -- This marker makes every later checkpoint a two-request read/write.
    -- Failure to persist the optimization marker is harmless: the history
    -- and registry are already durable, and a later push will retry it.
    device_body.registryConfirmed = true
    self:_writeJSON(device_path, device_body)
    return true
end

function WebDavSyncClient:pullProgressHistory(book_hash)
    local registry, status = self:_readJSON(
        progress_history_path(book_hash, "devices.json"))
    if registry == nil then
        return status == READ_MISSING and {} or nil
    end
    local combined = {}
    for _, device_id in ipairs(registry.deviceIds or {}) do
        local device = self:_readJSON(progress_history_path(
            book_hash, tostring(device_id) .. ".json"))
        if type(device) == "table" then
            for _, entry in ipairs(device.entries or {}) do
                if type(entry) == "table" then
                    entry.deviceId = entry.deviceId or device.deviceId or device_id
                    entry.deviceName = entry.deviceName or device.deviceName
                    combined[#combined + 1] = entry
                end
            end
        end
    end
    table.sort(combined, function(a, b)
        return (tonumber(a.timestamp) or 0) > (tonumber(b.timestamp) or 0)
    end)
    return combined
end

function WebDavSyncClient:updateProgressHistoryDeviceName(
        book_hash, device_id, device_name)
    if not book_hash or not device_id or not device_name then return false end
    device_id = tostring(device_id):gsub("[^%w_.%-]", "_")
    if device_id == "" then return false end
    local device_path = progress_history_path(book_hash, device_id .. ".json")
    local remote, status = self:_readJSON(device_path)
    if remote == nil then return status == READ_MISSING end
    remote.deviceId = device_id
    remote.deviceName = tostring(device_name)
    for _, entry in ipairs(remote.entries or {}) do
        if type(entry) == "table" then entry.deviceName = tostring(device_name) end
    end
    return self:_writeJSON(device_path, remote)
end

function WebDavSyncClient:pushChanges(changes, callback)
    logger.info("WebDavSyncClient pushChanges: configs="
        .. tostring(changes.configs and #changes.configs or 0)
        .. " notes=" .. tostring(changes.notes and #changes.notes or 0)
        .. " statBooks=" .. tostring(changes.statBooks and #changes.statBooks or 0)
        .. " statPages=" .. tostring(changes.statPages and #changes.statPages or 0)
        .. " vocab=" .. tostring(changes.vocab and #changes.vocab or 0)
        .. " books=" .. tostring(changes.books and #changes.books or 0))
    local ok = true

    -- Reading progress — last write wins per book
    if changes.configs and #changes.configs > 0 then
        local book_hash = changes.configs[1].bookHash
        if book_hash then
            local progress_configs = strip_marker_metadata(changes.configs)
            local progress_body = {configs = progress_configs}
            if changes.readingStatus ~= nil then
                progress_body.readingStatus = changes.readingStatus
            end
            if changes.readingStatusUpdatedAt ~= nil then
                progress_body.readingStatusUpdatedAt = changes.readingStatusUpdatedAt
            end
            local progress_path = "sync/" .. book_hash .. "/progress.json"
            if self:_writeJSON(progress_path,
                    progress_body, PROGRESS_PUSH_TIMEOUT) then
                -- Keep the critical progress push path to one PUT. Sync markers
                -- are human-readable metadata and can be refreshed by library/book
                -- sync; on slow mobile links the extra marker probe can make a
                -- successful progress push look like a timeout.
            else
                logger.warn("WebDavSyncClient pushChanges: progress write failed, repairing folders")
                if self:_ensureFolder("sync") and self:_ensureFolder("sync/" .. book_hash) then
                    if not self:_writeJSON(progress_path,
                            progress_body, PROGRESS_PUSH_TIMEOUT) then
                        ok = false
                    end
                else
                    ok = false
                end
            end
            if ok and changes.progressHistory then
                local history_ok = self:_appendProgressHistory(
                    book_hash, changes.progressHistory)
                if not history_ok then
                    logger.warn("WebDavSyncClient pushChanges: progress history write failed")
                    -- A manual checkpoint is explicitly requested recovery
                    -- data. Do not report the manual push as complete until
                    -- both latest progress and that checkpoint are durable.
                    local entry = changes.progressHistory.entry
                    if entry and entry.source == "manual" then ok = false end
                end
            end
        end
    end

    -- Annotations — union merge with remote
    if (changes.notes and #changes.notes > 0)
            or (changes.currentBookmarkIds and changes.bookHash) then
        local book_hash = changes.bookHash
            or (changes.notes and changes.notes[1] and changes.notes[1].bookHash)
        if book_hash then
            local ann_path = "sync/" .. book_hash .. "/annotations.json"
            local remote, read_status = self:_readJSON(ann_path)
            if remote == nil and read_status ~= READ_MISSING then
                -- Can't read remote — abort rather than overwrite with local-only subset
                logger.warn("WebDavSyncClient pushChanges: could not read remote annotations, skipping write")
                ok = false
            else
                remote = remote or {notes = {}}
                local notes = strip_note_marker_metadata(changes.notes)
                if changes.currentBookmarkIds then
                    notes = self:_addMissingBookmarkTombstones(
                        remote.notes or {}, notes, changes.currentBookmarkIds, book_hash)
                end
                local merged = self:_mergeNotes(remote.notes or {}, notes)
                if self:_writeJSON(ann_path, {notes = merged}) then
                    -- Do not block annotation sync completion on marker metadata.
                else
                    logger.warn("WebDavSyncClient pushChanges: annotations write failed, repairing folders")
                    if self:_ensureFolder("sync") and self:_ensureFolder("sync/" .. book_hash) then
                        if not self:_writeJSON(ann_path, {notes = merged}) then
                            ok = false
                        end
                    else
                        ok = false
                    end
                end
            end
        end
    end

    -- Stats — union merge with remote
    if (changes.statBooks and #changes.statBooks > 0)
            or (changes.statPages and #changes.statPages > 0) then
        local remote, read_status = self:_readJSON("stats.json")
        if remote == nil and read_status ~= READ_MISSING then
            ok = false
        else
            remote = remote or {}
            local mb, mp = self:_mergeStats(
                remote, changes.statBooks, changes.statPages)
            if not self:_writeJSON("stats.json",
                    {statBooks = mb, statPages = mp}) then
                ok = false
            end
        end
    end

    -- Vocab builder words — union merge with remote
    if changes.vocab then
        local remote, read_status = self:_readJSON("vocab.json")
        if remote == nil and read_status ~= READ_MISSING then
            ok = false
        else
            remote = remote or {words = {}}
            local merged = self:_mergeVocab(remote.words or {}, changes.vocab)
            if not self:_writeJSON("vocab.json", {words = merged}) then
                ok = false
            end
        end
    end

    -- Library book rows — union merge with remote
    if changes.books and #changes.books > 0 then
        local remote, read_status = self:_readJSON("library.json", LIBRARY_TIMEOUT, 0)
        if remote == nil and read_status ~= READ_MISSING then
            ok = false
        else
            remote = remote or {books = {}}
            local merged = self:_mergeBooks(remote.books or {}, changes.books)
            if not self:_writeJSON("library.json",
                    {books = merged, updatedAt = os.time() * 1000},
                    LIBRARY_TIMEOUT) then
                ok = false
            end
        end
    end

    callback(ok, {}, ok and 200 or 500)
end

function WebDavSyncClient:pullBooks(params, callback)
    logger.info("WebDavSyncClient pullBooks: since=" .. tostring(params and params.since))
    local since = tonumber(params.since) or 0
    local data, read_status = self:_readJSON("library.json", LIBRARY_TIMEOUT, 0)
    if not data or not data.books then
        if read_status == READ_FAILED then
            callback(false, {books = {}}, "read_failed")
            return
        end
        callback(true, {books = {}}, 200)
        return
    end
    -- Return rows changed since the watermark
    local filtered = {}
    for _, b in ipairs(data.books) do
        local ts  = tonumber(b.updatedAt)  or 0
        local dts = tonumber(b.deletedAt)  or 0
        if ts > since or dts > since then
            filtered[#filtered + 1] = b
        end
    end
    callback(true, {books = filtered}, 200)
end

return WebDavSyncClient
