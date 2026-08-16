-- syncbooks.lua
-- Sync layer for the Library view. Uploads/downloads book files and covers
-- to/from WebDAV, and syncs the book catalog via library.json.

local M = {}

local EXTS = require("syncest_lib.exts")

-- ---------------------------------------------------------------------------
-- build_local_filename: where downloaded book bytes land on disk
-- ---------------------------------------------------------------------------
local MAX_BODY_LEN = 200
local SYNC_TIMEOUT = 15
local SYNC_TOTAL_TIMEOUT = 60
local REACHABILITY_TIMEOUT = 5

local function now_ms()
    return math.floor(os.time() * 1000)
end

local function path_is_in_dir(path, dir)
    if type(path) ~= "string" or type(dir) ~= "string" or dir == "" then
        return false
    end
    path = path:gsub("/+$", "")
    dir = dir:gsub("/+$", "")
    return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

local function file_matches_hash(path, expected_hash)
    if type(path) ~= "string" or path == ""
            or type(expected_hash) ~= "string" or expected_hash == "" then
        return false
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return false end
    local ok_util, util = pcall(require, "util")
    if not ok_util or not util or not util.partialMD5 then return false end
    local ok_hash, actual_hash = pcall(util.partialMD5, path)
    return ok_hash and actual_hash == expected_hash
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
    local json = require("json")
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

local function write_temp_json(data)
    local DataStorage = require("datastorage")
    local path = DataStorage:getSettingsDir()
        .. "/syncest_book_marker_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1000000)) .. ".json"
    local ok, encoded = pcall(encode_pretty_json, data)
    if not ok then return nil end
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(encoded, "\n")
    f:close()
    return path
end

function M.build_local_filename(book)
    if not book then return nil end
    local ext = EXTS[book.format]
    if not ext then return nil end
    local raw = book.source_title or book.title or ""
    if raw == "" then return "book." .. ext end
    local safe = raw:gsub('[<>:|"?*\\/%c]', "_")
    if #safe > MAX_BODY_LEN then safe = safe:sub(1, MAX_BODY_LEN) end
    if safe:match("^_+$") then safe = "book" end
    return safe .. "." .. ext
end

-- ---------------------------------------------------------------------------
-- resolve_collision: bumps {name}.ext → {name} (1).ext on filename clash
-- ---------------------------------------------------------------------------
function M.resolve_collision(candidate, exists)
    if not exists(candidate) then return candidate end
    local base, ext = candidate:match("^(.+)%.([^.]+)$")
    if not base then base = candidate; ext = nil end
    for n = 1, 99 do
        local probe = ext
            and string.format("%s (%d).%s", base, n, ext)
            or  string.format("%s (%d)", base, n)
        if not exists(probe) then return probe end
    end
    return candidate
end

-- ---------------------------------------------------------------------------
-- row_to_wire: internal snake_case row → camelCase wire shape for library.json
-- ---------------------------------------------------------------------------
local function row_to_wire(row)
    if not row then return nil end
    local function num(v) return v and tonumber(v) or v end
    local out = {
        bookHash      = row.hash,
        hash          = row.hash,
        metaHash      = row.meta_hash,
        format        = row.format,
        title         = row.title,
        author        = row.author,
        sourceTitle   = row.source_title,
        groupId       = row.group_id,
        groupName     = row.group_name,
        readingStatus = row.reading_status,
        readingStatusUpdatedAt = num(row.reading_status_updated_at),
        createdAt     = num(row.created_at),
        updatedAt     = num(row.updated_at),
        deletedAt     = num(row.deleted_at),
        uploadedAt    = num(row.uploaded_at),
    }
    if row.metadata_json and row.metadata_json ~= "" then
        local json = require("json")
        local ok, parsed = pcall(json.decode, row.metadata_json)
        if ok and type(parsed) == "table" then out.metadata = parsed end
    end
    if row.progress_lib and row.progress_lib ~= "" then
        local json = require("json")
        local ok, parsed = pcall(json.decode, row.progress_lib)
        if ok and type(parsed) == "table" then out.progress = parsed end
    end
    return out
end
M._row_to_wire = row_to_wire

local function metadata_needs_refresh(row, props)
    if type(row) ~= "table" or type(props) ~= "table" then return false end
    local metadata_missing = not row.metadata_json
        or row.metadata_json == "" or row.metadata_json == "{}"
    local embedded_title = props.title
    local embedded_author = props.authors
    return metadata_missing
        or (embedded_title and embedded_title ~= ""
            and embedded_title ~= row.title)
        or (embedded_author and embedded_author ~= ""
            and embedded_author ~= row.author)
end
M._metadata_needs_refresh = metadata_needs_refresh

-- Refresh catalog metadata from the book itself before a bulk push publishes
-- library.json.  Embedded metadata is authoritative: a KOReader sidecar may
-- contain a filename-derived title (for example "Author - Title") and still
-- look complete enough that a missing-field-only check would preserve it.
function M.enrichLocalMetadata(store)
    if not store then return 0 end
    local logger = require("logger")
    local lfs = require("libs/libkoreader-lfs")
    local ok_registry, DocumentRegistry = pcall(
        require, "document/documentregistry")
    if not ok_registry or not DocumentRegistry then return 0 end
    local json = require("json")
    local updated = 0

    for _, row in ipairs(store:listLocalBooks() or {}) do
        if row.local_present == 1 and row.file_path
                and lfs.attributes(row.file_path, "mode") == "file"
                and DocumentRegistry:hasProvider(row.file_path) then
            local ok_doc, doc = pcall(
                DocumentRegistry.openDocument, DocumentRegistry, row.file_path)
            if ok_doc and doc then
                local loaded = true
                if doc.loadDocument then
                    local ok_load, load_result = pcall(
                        doc.loadDocument, doc, false)
                    loaded = ok_load and load_result ~= false
                end
                local props
                if loaded and doc.getProps then
                    local ok_props, result = pcall(doc.getProps, doc)
                    if ok_props and type(result) == "table" then props = result end
                end
                pcall(doc.close, doc)
                if props and (props.title or props.authors) then
                    local embedded_title = props.title
                    local embedded_author = props.authors
                    local changed = metadata_needs_refresh(row, props)
                    if changed then
                        local ok_json, encoded = pcall(json.encode, props)
                        store:upsertBook({
                            hash = row.hash,
                            title = embedded_title ~= "" and embedded_title
                                or row.title,
                            author = embedded_author ~= "" and embedded_author
                                or row.author,
                            metadata_json = ok_json and encoded
                                or row.metadata_json,
                            updated_at = math.floor(os.time() * 1000),
                        })
                        updated = updated + 1
                    end
                end
            end
        end
    end
    logger.info("WebDavSync enrichLocalMetadata: updated=" .. tostring(updated))
    return updated
end

local function rich_book_marker(book)
    local wire = row_to_wire(book) or {}
    local metadata = wire.metadata or {}
    local all_identifiers = wire.allIdentifiers or split_identifiers({
        wire.identifiers,
        metadata.identifiers,
        metadata.isbn,
        metadata.ISBN,
        metadata.isbn10,
        metadata.isbn13,
    })
    local ids = promoted_identifiers(all_identifiers)
    ids.googleBooksId = ids.googleBooksId
        or metadata.googleBooksId or metadata.google_books_id or metadata.google
    ids.calibreId = ids.calibreId
        or metadata.calibreId or metadata.calibre_id or metadata.calibre
    ids.uuid = ids.uuid or metadata.uuid or metadata.UUID
    local isbns = extract_isbns({
        all_identifiers,
        metadata.identifiers,
    })
    extract_isbns(wire.isbn, isbns, true)
    extract_isbns(wire.isbn10, isbns, true)
    extract_isbns(wire.isbn13, isbns, true)
    extract_isbns(metadata.isbn, isbns, true)
    extract_isbns(metadata.ISBN, isbns, true)
    extract_isbns(metadata.isbn10, isbns, true)
    extract_isbns(metadata.isbn13, isbns, true)
    ids.isbn = isbns.isbn

    local ext = EXTS[book.format]
    local authors = {}
    if book.author and book.author ~= "" then
        for author in tostring(book.author):gmatch("[^\n]+") do
            authors[#authors + 1] = author:gsub("^%s*(.-)%s*$", "%1")
        end
    end

    return {
        bookHash = book.hash,
        title = book.title or book.source_title or "",
        author = book.author,
        authors = authors,
        isbn = ids.isbn,
        googleBooksId = ids.googleBooksId,
        calibreId = ids.calibreId,
        uuid = ids.uuid,
        format = book.format,
        fileName = book.file_path and book.file_path:match("([^/]+)$") or nil,
        sourceTitle = book.source_title,
        bookFile = ext and string.format("%s.%s", book.hash, ext) or nil,
        coverFile = "cover.png",
        metadata = marker_metadata(metadata),
        createdAt = wire.createdAt,
        bookUpdatedAt = wire.updatedAt,
        uploadedAt = wire.uploadedAt,
        updatedAt = os.time() * 1000,
    }
end

-- ---------------------------------------------------------------------------
-- WebDAV helpers
-- ---------------------------------------------------------------------------
-- Returns the WebDavApi module and base URL components from opts.settings.
local function webdav(opts)
    local ok_webdav, WebDavApi = pcall(require, "apps/cloudstorage/webdavapi")
    if not ok_webdav then WebDavApi = require("syncest_webdavapi") end
    local srv = opts.settings.sync_server or {}
    local base = WebDavApi:getJoinedPath(srv.address or "", srv.url or "")
    local function url(rel)
        return WebDavApi:getJoinedPath(base, rel)
    end
    return WebDavApi, url, srv.username or "", srv.password or ""
end

local function server_reachable(opts)
    local logger = require("logger")
    local socket = require("socket")
    local srv = opts and opts.settings and opts.settings.sync_server or {}
    local addr = srv.address or ""
    local host = addr:match("https?://([^/:]+)")
    if not host then
        logger.warn("WebDavSync reachable: invalid server address")
        return false
    end
    local port = tonumber(addr:match("//[^/]*:(%d+)"))
        or (addr:match("^https://") and 443 or 80)
    logger.info("WebDavSync reachable: checking host=" .. tostring(host)
        .. " port=" .. tostring(port))
    local ok, connected = pcall(function()
        local s = socket.tcp()
        if not s then return false end
        s:settimeout(REACHABILITY_TIMEOUT)
        local result = s:connect(host, port)
        s:close()
        return result == 1
    end)
    logger.info("WebDavSync reachable: ok=" .. tostring(ok)
        .. " connected=" .. tostring(connected))
    return ok and connected == true
end

local function safe_webdav_call(label, fn, block_timeout, total_timeout)
    local logger = require("logger")
    local http = require("socket.http")
    local ok_sutil, socketutil = pcall(require, "socketutil")
    local prev_timeout = http.TIMEOUT
    local prev_file_block_timeout = ok_sutil and socketutil.FILE_BLOCK_TIMEOUT
    local prev_file_total_timeout = ok_sutil and socketutil.FILE_TOTAL_TIMEOUT
    block_timeout = block_timeout or SYNC_TIMEOUT
    total_timeout = total_timeout or SYNC_TOTAL_TIMEOUT
    local started = now_ms()

    logger.info("WebDavSync " .. tostring(label) .. ": start timeout=" .. tostring(block_timeout))
    http.TIMEOUT = block_timeout
    if ok_sutil then
        socketutil.FILE_BLOCK_TIMEOUT = block_timeout
        socketutil.FILE_TOTAL_TIMEOUT = total_timeout
        pcall(function() socketutil:set_timeout(block_timeout, total_timeout) end)
    end

    local ok, result = pcall(fn)

    if ok_sutil then
        pcall(function() socketutil:reset_timeout() end)
        socketutil.FILE_BLOCK_TIMEOUT = prev_file_block_timeout
        socketutil.FILE_TOTAL_TIMEOUT = prev_file_total_timeout
    end
    http.TIMEOUT = prev_timeout

    if not ok then
        logger.warn("WebDavSync " .. tostring(label) .. ": failed err="
            .. tostring(result) .. " duration_ms=" .. tostring(now_ms() - started))
        return nil, result
    end
    logger.info("WebDavSync " .. tostring(label) .. ": done result="
        .. tostring(result) .. " duration_ms=" .. tostring(now_ms() - started))
    return result
end

-- MKCOL tolerating 405 (already exists).
local function ensure_folder(api, url, user, pass)
    local code = safe_webdav_call("MKCOL", function()
        return api:createFolder(url, user, pass, "")
    end, 15, 180)
    return code == 201 or code == 405, code == 201
end

-- Inspect the actual WebDAV objects for a bulk push. The catalog cache is not
-- evidence that books/{hash}/{hash}.{ext} still exists (the server may have
-- been wiped or a previous upload may have stopped halfway through).
local function inventory_state(row, files)
    local ext = row and EXTS[row.format]
    local state = { book = false, cover = false }
    for _, item in ipairs(type(files) == "table" and files or {}) do
        if ext and item.text == row.hash .. "." .. ext then state.book = true end
        if item.text == "cover.png" then state.cover = true end
    end
    return state
end
M._inventory_state = inventory_state

local function remote_book_inventory(rows, opts)
    local api, url, user, pass = webdav(opts)
    local inventory = {}
    local total = #(rows or {})
    if opts.on_inventory_progress then
        opts.on_inventory_progress({ phase = "verify", done = 0, total = total })
    end
    for index, row in ipairs(rows or {}) do
        local files = safe_webdav_call("list books/" .. tostring(row.hash), function()
            return api:listFolder(url("books/" .. row.hash), user, pass, "", false)
        end, 10, 30)
        inventory[row.hash] = inventory_state(row, files)
        if opts.on_inventory_progress then
            opts.on_inventory_progress({
                phase = "verify",
                done = index,
                total = total,
                title = row.title,
                hash = row.hash,
            })
        end
    end
    return inventory
end
M._remote_book_inventory = remote_book_inventory

-- DELETE a WebDAV URL (file or collection). Returns HTTP status.
local function webdav_delete(full_url, user, pass)
    local socket     = require("socket")
    local http       = require("socket.http")
    local ltn12      = require("ltn12")
    return safe_webdav_call("DELETE", function()
        return socket.skip(1, http.request{
            url      = full_url,
            method   = "DELETE",
            user     = user,
            password = pass,
            sink     = ltn12.sink.null(),
        })
    end)
end

-- ---------------------------------------------------------------------------
-- pushBook / pushChangedBooks — push book metadata rows to library.json
-- ---------------------------------------------------------------------------
function M.pushBook(book_row, opts, cb)
    if not book_row or not book_row.hash then
        if cb then cb(false, "missing book row") end
        return
    end
    local client = opts.client
    if not client then
        if cb then cb(false, "no sync client") end
        return
    end
    client:pushChanges(
        {books = {row_to_wire(book_row)}, notes = {}, configs = {}},
        function(success, _, _)
            if cb then cb(success, success and nil or "push failed") end
        end)
end

function M.pushChangedBooks(opts, cb)
    local logger = require("logger")
    local store  = opts.store
    local client = opts.client
    if not store or not client then
        if cb then cb(false, "missing store or client") end
        return
    end

    local since = store:getLastPulledAt() or 0
    local changed = opts.full_push
        and store:listLocalBooks()
        or store:getChangedBooks(since)
    local lfs = require("libs/libkoreader-lfs")
    local archive_dir = opts.settings and opts.settings.syncest_archive_dir
    local library_dir = opts.settings and opts.settings.syncest_library_dir
    local eligible_hashes = opts.settings and opts.settings.syncest_eligible_hashes
    local archived_hashes = opts.settings and opts.settings.syncest_archived_hashes
    local archived_paths = opts.settings and opts.settings.syncest_archived_paths
    local function is_archived(row)
        return path_is_in_dir(row.file_path, archive_dir)
            or (archived_paths and archived_paths[row.file_path]) == true
            or (archived_hashes and archived_hashes[row.hash]) == true
    end
    local archived_tombstones = {}
    if archive_dir or archived_hashes or archived_paths then
        local filtered = {}
        for _, row in ipairs(changed) do
            if is_archived(row) then
                if opts.full_push then
                    local tombstone = {}
                    for key, value in pairs(row) do tombstone[key] = value end
                    local deleted_at = now_ms()
                    tombstone.deleted_at = deleted_at
                    tombstone.updated_at = math.max(
                        tonumber(tombstone.updated_at) or 0, deleted_at)
                    archived_tombstones[#archived_tombstones + 1] = tombstone
                end
            else
                filtered[#filtered + 1] = row
            end
        end
        logger.info("WebDavSync pushChangedBooks: excluded "
            .. tostring(#changed - #filtered) .. " archived row(s); tombstones="
            .. tostring(#archived_tombstones))
        changed = filtered
    end
    if opts.full_push then
        local existing_files = {}
        for _, row in ipairs(changed) do
            if row.file_path
                    and lfs.attributes(row.file_path, "mode") == "file"
                    and library_dir
                    and path_is_in_dir(row.file_path, library_dir)
                    and eligible_hashes
                    and eligible_hashes[row.hash] == true then
                -- Full push is an explicit assertion that every eligible
                -- local file belongs in the cloud. A newer remote tombstone
                -- must not beat this row during the library.json LWW merge,
                -- otherwise delete -> Push books can never restore a book.
                local resurrected = {}
                for key, value in pairs(row) do resurrected[key] = value end
                resurrected.deleted_at = nil
                resurrected.updated_at = now_ms()
                existing_files[#existing_files + 1] = resurrected
            end
        end
        changed = existing_files
    end
    logger.info("WebDavSync pushChangedBooks: full=" .. tostring(opts.full_push == true)
        .. " since=" .. since .. " found=" .. #changed)
    if #changed == 0 and #archived_tombstones == 0 then
        if cb then cb(true, 0) end
        return
    end

    -- Verify remote bytes before trusting cached cloud flags. Upload/repair
    -- objects first; only successfully backed rows may enter library.json.
    local inventory = opts.full_push and remote_book_inventory(changed, opts) or {}
    local DataStorage = require("datastorage")
    local covers_dir = DataStorage:getSettingsDir() .. "/syncest_covers"
    local uploaded, failed, covers_repaired, covers_failed = 0, 0, 0, 0
    local publish_rows = {}
    local total_uploads = 0
    for _, row in ipairs(changed) do
        local remote = inventory[row.hash]
        local need_book = opts.full_push
            and (not remote or not remote.book)
            or (not opts.full_push
                and (row.cloud_present ~= 1 or not row.uploaded_at))
        if need_book then total_uploads = total_uploads + 1 end
    end
    local progress_done = 0
    if opts.on_upload_progress and total_uploads > 0 then
        opts.on_upload_progress({ uploaded = 0, failed = 0, done = 0,
            total = total_uploads })
    end

    for _, original in ipairs(changed) do
        local row = {}
        for key, value in pairs(original) do row[key] = value end
        local remote = inventory[row.hash]
        local need_book = opts.full_push
            and (not remote or not remote.book)
            or (not opts.full_push
                and (row.cloud_present ~= 1 or not row.uploaded_at))
        local book_ready = not need_book
        if need_book then
            local call_ok, up_ok, err_up = pcall(M.uploadBook, row, {
                client = client, settings = opts.settings, covers_dir = covers_dir,
            }, nil)
            book_ready = call_ok and up_ok == true
            if book_ready then
                uploaded = uploaded + 1
                row.uploaded_at = now_ms()
                row.updated_at = math.max(tonumber(row.updated_at) or 0,
                    row.uploaded_at)
            else
                failed = failed + 1
                logger.warn("Syncest uploadBook failed: " .. tostring(err_up))
            end
            progress_done = progress_done + 1
            if opts.on_upload_progress then
                opts.on_upload_progress({ uploaded = uploaded, failed = failed,
                    done = progress_done, total = total_uploads,
                    title = row.title, hash = row.hash })
            end
        elseif opts.full_push and remote and not remote.cover then
            local call_ok, cover_ok = pcall(M.uploadBookCover, row, {
                client = client, settings = opts.settings, covers_dir = covers_dir,
            })
            if call_ok and cover_ok then
                covers_repaired = covers_repaired + 1
            else
                covers_failed = covers_failed + 1
                logger.warn("Syncest uploadBookCover repair failed: "
                    .. tostring(row.hash))
            end
        end
        if book_ready and not row.uploaded_at then
            row.uploaded_at = now_ms()
            row.updated_at = math.max(tonumber(row.updated_at) or 0,
                row.uploaded_at)
        end
        if book_ready then publish_rows[#publish_rows + 1] = row end
    end

    local books_wire = {}
    local max_ts = since
    for _, row in ipairs(publish_rows) do
        books_wire[#books_wire + 1] = row_to_wire(row)
        max_ts = math.max(max_ts, tonumber(row.updated_at) or 0,
            tonumber(row.deleted_at) or 0)
    end
    for _, row in ipairs(archived_tombstones) do
        books_wire[#books_wire + 1] = row_to_wire(row)
        max_ts = math.max(max_ts, tonumber(row.updated_at) or 0,
            tonumber(row.deleted_at) or 0)
    end

    logger.info("Syncest pushChangedBooks: verified=" .. #publish_rows
        .. " uploaded=" .. uploaded .. " failed=" .. failed
        .. " covers_repaired=" .. covers_repaired
        .. " covers_failed=" .. covers_failed)
    if #books_wire == 0 then
        if cb then cb(false, tostring(failed) .. " book file upload(s) failed") end
        return
    end

    logger.info("WebDavSync pushChangedBooks: publishing " .. #books_wire .. " row(s)")
    client:pushChanges({books = books_wire, notes = {}, configs = {}},
        function(success, _, status)
            if not success then
                if cb then cb(false, "catalog push failed (HTTP "
                    .. tostring(status) .. ")") end
                return
            end
            for _, row in ipairs(publish_rows) do
                store:upsertBook({
                    hash = row.hash, title = row.title,
                    cloud_present = 1, uploaded_at = row.uploaded_at,
                    updated_at = row.updated_at,
                    _clear_fields = { "deleted_at" },
                })
            end
            for _, row in ipairs(archived_tombstones) do
                store:upsertBook({
                    hash = row.hash, title = row.title,
                    cloud_present = 0, deleted_at = row.deleted_at,
                    updated_at = row.updated_at,
                    _force_cloud_present = true,
                })
            end
            store:setLastPulledAt(max_ts)
            if failed > 0 then
                if cb then cb(false, tostring(failed)
                    .. " book file upload(s) failed") end
            elseif cb then
                cb(true, #books_wire)
            end
        end)
end

-- ---------------------------------------------------------------------------
-- syncBooks — convenience wrapper (push / pull / both)
-- ---------------------------------------------------------------------------
function M.syncBooks(opts, mode, cb, before_push)
    mode = mode or "both"
    local logger = require("logger")
    logger.info("WebDavSync syncBooks: mode=" .. tostring(mode))
    if mode == "push" then
        -- Push must never begin with a catalog pull. Besides being needless
        -- for the strict home-directory snapshot used by a full push, doing
        -- so can merge recently deleted cloud rows back into the local index
        -- before their tombstones are published.
        if before_push then before_push() end
        M.pushChangedBooks(opts, cb)
    elseif mode == "pull" then
        M.pullBooks(opts, cb)
    else
        M.pullBooks(opts, function(pull_ok, pull_msg, pull_status)
            if before_push then before_push() end
            M.pushChangedBooks(opts, function(push_ok, push_msg)
                if cb then
                    cb(pull_ok and push_ok,
                        string.format("pull=%s/%s push=%s/%s",
                            tostring(pull_ok), tostring(pull_msg),
                            tostring(push_ok), tostring(push_msg)),
                        pull_status)
                end
            end)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- pullBooks — download library.json and upsert changed rows into LibraryStore
-- ---------------------------------------------------------------------------
function M.pullBooks(opts, cb)
    local logger       = require("logger")
    local LibraryStore = require("syncest_lib.librarystore")
    local client       = opts.client
    local store        = opts.store

    if not client or not store then
        if cb then cb(false, "missing sync client or store") end
        return
    end

    -- Always fetch the full cloud library (since=0) so the Syncest Library
    -- always reflects exactly what's in WebDAV regardless of push watermarks.
    logger.info("WebDavSync pullBooks: full cloud fetch")

    client:pullBooks({since = 0}, function(success, body, _)
        if not success then
            if cb then cb(false, "pull failed") end
            return
        end
        local rows    = body and body.books or {}
        local max_ts  = 0
        local upserted = 0
        local local_snapshot
        if opts.full_refresh and store.resetCatalog then
            -- A full refresh is a literal catalog replacement. Preserve only
            -- per-device file identity so it can be joined back to the fresh
            -- cloud rows by hash; do not retain old cloud metadata.
            local_snapshot = store:listLocalBooks()
            store:resetCatalog()
        else
            store:clearCloudPresent()
        end
        for _, raw in ipairs(rows) do
            local parsed = LibraryStore.parseSyncRow(raw)
            if parsed then
                local remote_deleted_at = parsed.deleted_at
                local existing = store:_getRowRaw(parsed.hash)
                -- A live cloud row can legitimately resurrect a previously
                -- deleted hash. upsertBook preserves omitted fields by
                -- default, so explicitly clear an older local tombstone;
                -- otherwise the fresh row remains permanently hidden.
                if not remote_deleted_at and existing and existing.deleted_at
                        and (tonumber(parsed.updated_at) or 0)
                            >= (tonumber(existing.deleted_at) or 0) then
                    parsed._clear_fields = { "deleted_at" }
                end
                -- A cloud-only removal must not hide/delete a retained local
                -- copy. Keep the tombstone's cloud absence while preserving
                -- the local row as an uploadable device-only book.
                if remote_deleted_at and existing
                        and tonumber(existing.local_present) == 1 then
                    parsed.deleted_at = nil
                    parsed._clear_fields = { "deleted_at" }
                end
                parsed.user_id = opts.settings.user_id
                store:upsertBook(parsed)
                upserted = upserted + 1
                if parsed.updated_at and parsed.updated_at > max_ts then
                    max_ts = parsed.updated_at
                end
                if remote_deleted_at and remote_deleted_at > max_ts then
                    max_ts = remote_deleted_at
                end
            end
        end
        for _, local_row in ipairs(local_snapshot or {}) do
            local fresh = store:_getRowRaw(local_row.hash)
            if fresh then
                store:upsertBook({
                    hash = local_row.hash,
                    title = fresh.title,
                    local_present = 1,
                    file_path = local_row.file_path,
                    cover_path = local_row.cover_path,
                    _clear_fields = fresh.deleted_at and { "deleted_at" } or nil,
                })
            else
                -- Local-only rows remain available to explicit Push Books but
                -- stay invisible in the Cloud Library (cloud_present defaults
                -- to zero).
                local restored = {}
                for key, value in pairs(local_row) do restored[key] = value end
                restored.cloud_present = 0
                restored.deleted_at = nil
                restored._force_cloud_present = true
                restored._clear_fields = { "deleted_at" }
                store:upsertBook(restored)
            end
        end
        if max_ts > 0 then store:setLastPulledAt(max_ts) end
        logger.info("WebDavSync pullBooks: upserted=" .. upserted)
        if cb then cb(true, upserted) end
    end)
end

-- ---------------------------------------------------------------------------
-- downloadBook — pull a book file from WebDAV books/{hash}/{hash}.{ext}
-- ---------------------------------------------------------------------------
function M.downloadBook(book, opts, cb)
    local logger = require("logger")
    local lfs    = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)

    if not server_reachable(opts) then
        if cb then cb(false, "unreachable") end
        return false, "unreachable"
    end

    local ext = EXTS[book.format]
    if not ext then
        if cb then cb(false, "unsupported format") end
        return false, "unsupported format"
    end

    local rel   = string.format("books/%s/%s.%s", book.hash, book.hash, ext)
    local local_name = opts.local_filename or M.build_local_filename(book)
    if not local_name then
        if cb then cb(false, "could not build local filename") end
        return false, "could not build local filename"
    end
    local_name = local_name:match("([^/\\]+)$")
    if not local_name or local_name == "" then
        if cb then cb(false, "invalid local filename") end
        return false, "invalid local filename"
    end

    if not lfs.attributes(opts.download_dir, "mode") then
        lfs.mkdir(opts.download_dir)
    end
    if file_matches_hash(book.file_path, book.hash) then
        if cb then cb(true, book.file_path, nil, true) end
        return true, book.file_path, nil, true
    end
    local exists = function(name)
        return lfs.attributes(opts.download_dir .. "/" .. name, "mode") ~= nil
    end
    local candidate = opts.download_dir .. "/" .. local_name
    if exists(local_name) and file_matches_hash(candidate, book.hash) then
        if cb then cb(true, candidate, nil, true) end
        return true, candidate, nil, true
    end
    local dst = opts.download_dir .. "/" .. M.resolve_collision(local_name, exists)

    logger.info("WebDavSync downloadBook: " .. rel .. " -> " .. dst)
    local code, err = safe_webdav_call("downloadBook " .. rel, function()
        return api:downloadFile(url(rel), user, pass, dst)
    end)
    if code == 200 then
        if cb then cb(true, dst) end
        return true, dst, nil, false
    else
        os.remove(dst)
        if cb then cb(false, err or "download failed", code) end
        return false, err or "download failed", code
    end
end

-- ---------------------------------------------------------------------------
-- downloadMissingBooks — download every cloud-library book not on device
-- ---------------------------------------------------------------------------
function M.downloadMissingBooks(opts, cb)
    local logger = require("logger")
    local store = opts and opts.store
    local download_dir = opts and opts.download_dir
    if not store or not download_dir or download_dir == "" then
        local err = not store and "missing store" or "missing download directory"
        if cb then cb(false, nil, err) end
        return false, nil, err
    end

    local rows = store:listBooks()
    local candidates = {}
    local already_local = 0
    for _, row in ipairs(rows) do
        local local_file_exists = row.local_present == 1
            and file_matches_hash(row.file_path, row.hash)
        local is_cloud_book = row.cloud_present == 1
            or row.uploaded_at ~= nil
        if local_file_exists then
            already_local = already_local + 1
        elseif is_cloud_book then
            candidates[#candidates + 1] = row
        end
    end

    local downloaded, failed, processed = 0, 0, 0
    if opts.on_download_progress then
        opts.on_download_progress({
            phase = "download",
            downloaded = downloaded,
            failed = failed,
            done = 0,
            total = #candidates,
            already_local = already_local,
        })
    end

    for _, row in ipairs(candidates) do
        local success, dst_or_err, _, was_existing = M.downloadBook(row, {
            client = opts.client,
            settings = opts.settings,
            download_dir = download_dir,
        })
        if success then
            if was_existing then
                already_local = already_local + 1
            else
                downloaded = downloaded + 1
            end
            store:upsertBook({
                hash = row.hash,
                title = row.title,
                local_present = 1,
                file_path = dst_or_err,
            })
        else
            failed = failed + 1
            logger.warn("Syncest downloadMissingBooks failed for "
                .. tostring(row.hash) .. ": " .. tostring(dst_or_err))
        end
        processed = processed + 1
        if opts.on_download_progress then
            opts.on_download_progress({
                phase = "download",
                downloaded = downloaded,
                failed = failed,
                done = processed,
                total = #candidates,
                already_local = already_local,
                title = row.title,
                hash = row.hash,
            })
        end
    end

    local summary = {
        downloaded = downloaded,
        failed = failed,
        already_local = already_local,
        total = #rows,
    }
    -- Reaching the end means the bulk pull itself completed. Individual
    -- failures remain in the summary so the caller can report a partial
    -- result without discarding successful downloads or treating the entire
    -- catalog pull as failed.
    if cb then cb(true, summary) end
    return true, summary
end

function M.countMissingBooks(store)
    if not store then return 0, 0 end
    local missing, total = 0, 0
    for _, row in ipairs(store:listBooks()) do
        total = total + 1
        if not (row.local_present == 1
                and file_matches_hash(row.file_path, row.hash)) then
            missing = missing + 1
        end
    end
    return missing, total
end

-- ---------------------------------------------------------------------------
-- extractLocalCover — decode the embedded cover to an RGB PNG.
-- FileManagerBookInfo:getCoverImage() routes JPEGs through ffi/pic, which
-- deliberately decodes to grayscale on monochrome devices. For CRE formats
-- (EPUB, FB2, etc.) fetch the original embedded bytes and render them through
-- MuPDF instead, whose output is RGB regardless of the display hardware.
-- ---------------------------------------------------------------------------
function M.extractLocalCover(file_path, dst_png)
    if not file_path or not dst_png then return false end
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if ok_registry and DocumentRegistry then
        local ok_doc, doc = pcall(DocumentRegistry.openDocument,
            DocumentRegistry, file_path)
        if ok_doc and doc then
            local ok_load = true
            if doc.loadDocument then
                ok_load = pcall(doc.loadDocument, doc, false)
            end
            if ok_load and doc._document
                    and doc._document.getCoverPageImageData then
                local ok_data, data, size = pcall(
                    doc._document.getCoverPageImageData, doc._document)
                if ok_data and data and size then
                    local RenderImage = require("ui/renderimage")
                    local ok_render, cover_bb = pcall(
                        RenderImage.renderImageDataWithMupdf,
                        RenderImage, data, size)
                    local ffi = require("ffi")
                    pcall(ffi.C.free, data)
                    if ok_render and cover_bb then
                        local wrote = cover_bb:writeToFile(dst_png, "png")
                        if cover_bb.free then cover_bb:free() end
                        doc:close()
                        return wrote == true
                    end
                end
            end
            doc:close()
        end
    end
    local ok, FileManagerBookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok or not FileManagerBookInfo then return false end
    local got, cover_bb = pcall(
        FileManagerBookInfo.getCoverImage,
        FileManagerBookInfo, nil, file_path, true)
    if not got or not cover_bb then return false end
    local wrote = cover_bb:writeToFile(dst_png, "png")
    if cover_bb.free then cover_bb:free() end
    return wrote == true
end

function M.uploadBookCover(book, opts)
    local lfs = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)
    if not book or not book.hash or not book.file_path or not opts.covers_dir then
        return false
    end
    if lfs.attributes(book.file_path, "mode") ~= "file" then return false end
    if not lfs.attributes(opts.covers_dir, "mode") then
        lfs.mkdir(opts.covers_dir)
    end
    -- Keep this separate from downloaded cloud covers (<hash>.png). Files
    -- carrying this suffix were generated by the source-color decoder above.
    local cover_path = opts.covers_dir .. "/" .. book.hash .. ".source.png"
    if lfs.attributes(cover_path, "mode") ~= "file"
            and not M.extractLocalCover(book.file_path, cover_path) then
        return false
    end
    -- A metadata row may survive an interrupted/legacy upload even when its
    -- books/{hash}/ collection does not. Cover-only repair must recreate the
    -- remote parent just like uploadBook does, otherwise WebDAV rejects the
    -- PUT with 409 Conflict.
    local book_dir = string.format("books/%s", book.hash)
    if not ensure_folder(api, url("books"), user, pass)
            or not ensure_folder(api, url(book_dir), user, pass) then
        return false
    end
    local cover_rel = string.format("books/%s/cover.png", book.hash)
    local code = safe_webdav_call("uploadCover " .. cover_rel, function()
        return api:uploadFile(url(cover_rel), user, pass, cover_path)
    end, 15, 300)
    return type(code) == "number" and code >= 200 and code <= 299
end

-- ---------------------------------------------------------------------------
-- uploadBook — push book file (and cover) to WebDAV books/{hash}/
-- ---------------------------------------------------------------------------
function M.uploadBook(book, opts, cb)
    local logger = require("logger")
    local lfs    = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)

    if not book or not book.hash or not book.format or not book.file_path then
        if cb then cb(false, "missing book info") end
        return false, "missing book info"
    end
    local ext = EXTS[book.format]
    if not ext then
        if cb then cb(false, "unsupported format") end
        return false, "unsupported format"
    end
    if not lfs.attributes(book.file_path, "mode") then
        if cb then cb(false, "local file missing") end
        return false, "local file missing"
    end

    -- Ensure books/{hash}/ folder exists
    local book_dir = string.format("books/%s", book.hash)
    local books_ok = ensure_folder(api, url("books"), user, pass)
    local book_ok = ensure_folder(api, url(book_dir), user, pass)
    if not books_ok or not book_ok then
        if cb then cb(false, "could not create cloud folder") end
        return false, "could not create cloud folder"
    end

    -- Upload book file
    local file_rel = string.format("books/%s/%s.%s", book.hash, book.hash, ext)
    logger.info("WebDavSync uploadBook: uploading " .. file_rel)
    local code, err = safe_webdav_call("uploadBook " .. file_rel, function()
        return api:uploadFile(url(file_rel), user, pass, book.file_path)
    end, 15, 300)
    if type(code) ~= "number" or code < 200 or code > 299 then
        if cb then cb(false, err or "book upload failed", code) end
        return false, err or "book upload failed", code
    end

    local marker = write_temp_json(rich_book_marker(book))
    if marker then
        local marker_rel = string.format("books/%s/%s", book.hash,
            safe_title_filename(book.title or book.source_title))
        safe_webdav_call("uploadBookMarker " .. marker_rel, function()
            return api:uploadFile(url(marker_rel), user, pass, marker)
        end, 15, 180)
        os.remove(marker)
    end

    -- Upload source-color cover (best-effort).
    M.uploadBookCover(book, opts)

    if cb then cb(true) end
    return true
end

-- ---------------------------------------------------------------------------
-- downloadCover — fetch cover.png from WebDAV books/{hash}/cover.png
-- ---------------------------------------------------------------------------
function M.downloadCover(book, opts, cb)
    local logger = require("logger")
    local lfs = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)

    if not server_reachable(opts) then
        if cb then cb(false, "unreachable") end
        return false, "unreachable"
    end

    local rel = string.format("books/%s/cover.png", book.hash)
    if not lfs.attributes(opts.covers_dir, "mode") then
        lfs.mkdir(opts.covers_dir)
    end
    local dst = opts.covers_dir .. "/" .. book.hash .. ".png"

    logger.info("WebDavSync downloadCover: " .. rel .. " -> " .. dst)
    local code, err = safe_webdav_call("downloadCover " .. rel, function()
        return api:downloadFile(url(rel), user, pass, dst)
    end)
    if code == 200 then
        if cb then cb(true, dst) end
        return true, dst
    elseif code == 404 then
        os.remove(dst)
        if cb then cb(false, "no-cover", 404) end
        return false, "no-cover", 404
    else
        os.remove(dst)
        if cb then cb(false, err or "download failed", code) end
        return false, err or "download failed", code
    end
end

-- ---------------------------------------------------------------------------
-- deleteCloudFiles — DELETE books/{hash}/ collection on WebDAV
-- ---------------------------------------------------------------------------
function M.deleteCloudFiles(book, opts, cb)
    local logger = require("logger")
    local _, url, user, pass = webdav(opts)

    if not book or not book.hash then
        if cb then cb(false, "missing book") end
        return false, "missing book"
    end

    local rel  = string.format("books/%s/", book.hash)
    local code = webdav_delete(url(rel), user, pass)
    logger.info("WebDavSync deleteCloudFiles: " .. rel .. " → " .. tostring(code))

    local ok = code == 200 or code == 204 or code == 404
    if cb then cb(ok, ok and 1 or 0, code) end
    return ok, code
end

-- Permanently remove the shared catalog and every uploaded book object. Delete
-- the catalog first so a partial failure can leave only invisible orphan files,
-- never visible rows that point at files already removed.
function M.wipeCloudLibrary(opts, cb)
    local logger = require("logger")
    local _, url, user, pass = webdav(opts)
    local catalog_code = webdav_delete(url("library.json"), user, pass)
    local catalog_ok = catalog_code == 200 or catalog_code == 204
        or catalog_code == 404
    logger.info("WebDavSync wipeCloudLibrary: library.json → "
        .. tostring(catalog_code))
    if not catalog_ok then
        if cb then cb(false, "catalog delete failed", catalog_code, false) end
        return false, catalog_code
    end

    local books_code = webdav_delete(url("books/"), user, pass)
    local books_ok = books_code == 200 or books_code == 204 or books_code == 404
    logger.info("WebDavSync wipeCloudLibrary: books/ → " .. tostring(books_code))
    if cb then
        cb(books_ok, books_ok and nil or "book cleanup failed",
            books_code, true)
    end
    return books_ok, books_code
end

return M
