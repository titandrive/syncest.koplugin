-- librarywidget.lua
-- Top-level Library view. Constructs a vanilla KOReader Menu and method-
-- mixes in CoverMenu + MosaicMenu (or ListMenu) per zen_ui's group_view.lua
-- pattern, then drives item_table from LibraryStore. Owns the search bar,
-- view-menu button, and group breadcrumb. Triggers lightScan + cloud pull
-- on open.
--
-- See apps/readest.koplugin/docs/library-design.md for the full design and
-- the runtime compatibility/smoke-test reasoning.

local Device       = require("device")
local GestureRange = require("ui/gesturerange")
local InfoMessage  = require("ui/widget/infomessage")
local InputDialog  = require("ui/widget/inputdialog")
local Menu         = require("ui/widget/menu")
local NetworkMgr   = require("ui/network/manager")
local TitleBar     = require("ui/widget/titlebar")
local Trapper      = require("ui/trapper")
local UIManager    = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local logger       = require("logger")
local _            = require("syncest_i18n")

local LibraryStore   = require("syncest_lib.librarystore")
local cloud_covers   = require("syncest_lib.cloud_covers")
local libraryitem    = require("syncest_lib.libraryitem")
local librarypaint   = require("syncest_lib.librarypaint")
local localscanner   = require("syncest_lib.localscanner")
local syncbooks      = require("syncest_lib.syncbooks")

local M = {}

-- ---------------------------------------------------------------------------
-- Module-level state. The widget is a singleton — reopening reuses the
-- store. Account-switching closes + reopens with a fresh user_id.
-- ---------------------------------------------------------------------------
M._store          = nil
M._current_user   = nil
M._opts           = nil  -- last-used opts; needed for refresh after view-menu changes
M._menu           = nil
M._search         = nil  -- transient per-session search query; never persisted to disk
M._group_path     = nil  -- transient: nil = root; "Fantasy/Tolkien" when drilled in
M._archive_dir    = nil
M._archive_paths  = {}
M._archive_original_dirs = {}
M._archive_settings = nil

local function refresh_archive_index()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local lfs = require("libs/libkoreader-lfs")
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/move_to_archive_settings.lua")
    -- The user patch and KOReader plugin use different keys. Respect the
    -- configured value from either implementation; never assume /archive.
    local archive_dir = settings:readSetting("archive_dir")
        or settings:readSetting("archive_dir_path")
    if type(archive_dir) == "string" then
        archive_dir = archive_dir:gsub("/+$", "")
    end
    M._archive_settings = settings
    M._archive_original_dirs =
        settings:readSetting("library_archive_original_dirs") or {}
    if not archive_dir or archive_dir == ""
            or lfs.attributes(archive_dir, "mode") ~= "directory" then
        M._archive_dir = nil
        M._archive_paths = {}
        return
    end
    M._archive_dir = archive_dir
    M._archive_paths = localscanner.bookPathsByHashInDir(archive_dir)
end

local function decorate_archive_row(row)
    local archived_path = row and M._archive_paths[row.hash]
    if not archived_path then return row end
    local copy = {}
    for key, value in pairs(row) do copy[key] = value end
    copy.archived_path = archived_path

    -- An archived copy is intentionally not the active on-device library
    -- copy. Preserve a separate real local copy if one exists elsewhere.
    local lfs = require("libs/libkoreader-lfs")
    local has_regular_copy = type(copy.file_path) == "string"
        and copy.file_path ~= archived_path
        and lfs.attributes(copy.file_path, "mode") == "file"
    if not has_regular_copy then
        copy.local_present = 0
        copy.file_path = nil
    end
    return copy
end

-- The Syncest Library is a cloud catalog, optionally decorated with normal
-- on-device copies. Files in KOReader's archive are explicitly tombstoned by
-- Push Books, so never let their local SQLite rows briefly masquerade as
-- cloud-library entries while that push (or the next authoritative refresh)
-- is still in flight.
local function is_archive_only_row(row)
    return row and M._archive_paths[row.hash] ~= nil
end

-- ---------------------------------------------------------------------------
-- check_renderer_compat: signature + smoke test from the eng review.
-- Returns ok, reason; on failure, librarywidget falls back to a plain Menu
-- with FakeCover-only items so the view still loads.
-- ---------------------------------------------------------------------------
function M.check_renderer_compat()
    local ok_cm, CoverMenu  = pcall(require, "covermenu")
    local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
    local ok_lm, ListMenu   = pcall(require, "listmenu")
    if not (ok_cm and ok_mm and ok_lm) then
        return false, "missing-modules:" .. tostring(not ok_cm and "covermenu" or not ok_mm and "mosaicmenu" or "listmenu")
    end
    local needed = {
        { CoverMenu,  "updateItems" },
        { CoverMenu,  "onCloseWidget" },
        { MosaicMenu, "_recalculateDimen" },
        { MosaicMenu, "_updateItemsBuildUI" },
        { ListMenu,   "_recalculateDimen" },
        { ListMenu,   "_updateItemsBuildUI" },
    }
    for _, n in ipairs(needed) do
        if type(n[1][n[2]]) ~= "function" then
            return false, "missing-method:" .. n[2]
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- canOpen(settings) — used by main.lua's menu-item enable check.
-- ---------------------------------------------------------------------------
function M.canOpen(settings)
    if not settings or not settings.user_id or settings.user_id == "" then
        return false, _("Configure WebDAV sync to open the Library")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- ensure_store(settings) — open the LibraryStore for the active user;
-- close + reopen if the user_id changed since last open (account switch).
-- ---------------------------------------------------------------------------
local function ensure_store(settings)
    local db_path = require("syncest_lib.storage").path("syncest_library")
    if M._store and M._current_user == settings.user_id then return M._store end
    if M._store then M._store:close() end
    M._store = LibraryStore.new({ user_id = settings.user_id, db_path = db_path })
    M._current_user = settings.user_id
    return M._store
end

-- ---------------------------------------------------------------------------
-- get_filters(settings) — read the persisted view-menu state from
-- G_reader_settings.readest_sync.library_*; return a filters table for
-- LibraryStore:listBooks.
-- ---------------------------------------------------------------------------
local function get_filters(settings, search)
    -- Default sort: last_read_at DESC. listBooks COALESCEs with updated_at
    -- so cloud-only books (NULL last_read_at) still sort by their cloud
    -- timestamp instead of falling to the bottom in arbitrary order.
    -- group_by/group_filter are intentionally NOT carried here — the
    -- bookshelf composer (build_item_table) handles them via
    -- listBookshelfGroups + listBookshelfBooks.
    return {
        search       = search,
        sort_by      = settings.library_sort_by or "last_read_at",
        sort_asc     = settings.library_sort_ascending == true,
        show_cloud   = settings.library_show_cloud ~= false,
        show_local   = settings.library_show_local ~= false,
    }
end

-- Translate grouping picker values to LibraryStore column names.
-- Flat, ungrouped books are the default.
local DEFAULT_GROUP_BY = "none"
local GROUP_BY_TO_COLUMN = {
    authors = "author",
    series  = "series",
}
local function active_group_by(settings)
    local g = settings.library_group_by
    if g == nil then g = DEFAULT_GROUP_BY end
    -- "groups" existed before Syncest exposed an explicit ungrouped mode,
    -- but the plugin has no way to assign that legacy catalog field.
    if g == "none" or g == "groups" then return nil end
    return GROUP_BY_TO_COLUMN[g] or g
end

-- "↩ Parent" or "↩ Library" depending on whether we'd land at a sub-path
-- or back at root. Used as item_table[1] when drilled in.
local function back_entry_for(current_path)
    local parent
    if current_path then
        for i = #current_path, 1, -1 do
            if current_path:sub(i, i) == "/" then
                parent = current_path:sub(1, i - 1)
                break
            end
        end
    end
    local label = "↩ " .. (parent or _("Library"))
    return libraryitem.entry_back(parent, label)
end

-- ---------------------------------------------------------------------------
-- get_view_mode(settings) — "mosaic" or "list"; defaults to mosaic.
-- ---------------------------------------------------------------------------
local function get_view_mode(settings)
    local mode = settings.library_view_mode
    if mode == "list" then return "list" end
    return "mosaic"
end

-- ---------------------------------------------------------------------------
-- build_item_table(store, settings, search) — query store + map rows to
-- Menu entries via libraryitem.entry_from_row.
-- ---------------------------------------------------------------------------
-- Sort-value extraction for the merged shelf list. Each entry — whether
-- a folder/group or a book row — gets one comparable value per sort_by;
-- groups use their "most recent child" aggregate so they interleave
-- correctly with siblings under date-based sorts. Mirrors Readest's
-- getGroupSortValue + getBookSortValue at
-- apps/readest-app/src/app/library/utils/libraryUtils.ts:313-403.
local SORT_VALUE_FOR_GROUP = {
    last_read_at = function(g) return g.latest_last_read_at or 0 end,
    updated_at   = function(g) return g.latest_updated_at or 0 end,
    created_at   = function(g) return g.latest_created_at or 0 end,
    title        = function(g) return g.display_name or "" end,
    author       = function(g) return g.display_name or "" end,
    series       = function(g) return g.display_name or "" end,
    format       = function(g) return g.display_name or "" end,
}

local SORT_VALUE_FOR_BOOK = {
    -- last_read_at: prefer updated_at when present (matches the SQL
    -- COALESCE in librarystore.listBooks). Without this the Lua-side
    -- merged-shelf sort overrides the SQL sort with the old
    -- "last_read_at first" behaviour, hiding any updated_at bump (e.g.
    -- the dedupe path of "Add to Readest").
    last_read_at = function(r) return r.updated_at or r.last_read_at or 0 end,
    updated_at   = function(r) return r.updated_at or 0 end,
    created_at   = function(r) return r.created_at or 0 end,
    title        = function(r) return r.title or "" end,
    author       = function(r) return r.author or "" end,
    series       = function(r) return r.series or "" end,
    format       = function(r) return r.format or "" end,
}

local function build_item_table(store, settings, search)
    local group_by = active_group_by(settings)
    local view_mode = get_view_mode(settings)
    local row_entry_opts = { view_mode = view_mode }
    local function add_search_back(items)
        if search and search ~= "" then
            table.insert(items, 1, {
                text = "↩ " .. _("Library"),
                mandatory = "",
                _readest_clear_search = true,
            })
        end
        return items
    end

    if not group_by then
        local rows = store:listBooks(get_filters(settings, search))
        local items = {}
        for _, row in ipairs(rows) do
            if not is_archive_only_row(row) then
                row = decorate_archive_row(row)
                items[#items + 1] = libraryitem.entry_from_row(row, row_entry_opts)
            end
        end
        return add_search_back(items)
    end

    local parent_path = M._group_path
    local filters = get_filters(settings, search)
    local groups = store:listBookshelfGroups(group_by, parent_path, filters)
    local books  = store:listBookshelfBooks(filters, group_by, parent_path)

    local sort_by = settings.library_sort_by or "last_read_at"
    local sort_asc = settings.library_sort_ascending == true
    local g_value = SORT_VALUE_FOR_GROUP[sort_by] or SORT_VALUE_FOR_GROUP.last_read_at
    local b_value = SORT_VALUE_FOR_BOOK[sort_by]  or SORT_VALUE_FOR_BOOK.last_read_at

    logger.dbg("ReadestLibrary build_item_table: group_by=" .. tostring(group_by)
        .. " parent_path=" .. tostring(parent_path)
        .. " sort_by=" .. tostring(sort_by)
        .. " sort_asc=" .. tostring(sort_asc)
        .. " #groups=" .. #groups .. " #books=" .. #books)

    -- Build a single mixed list with each entry's sort_value pre-computed,
    -- then sort once. Stable on already-sorted input either way.
    -- Group cells get a mini-cover preview in both view modes — a 2x2
    -- mosaic for Grid (mosaic) and a 1x4 horizontal strip for List.
    local group_entry_opts = {
        group_by   = group_by,
        with_cover = true,
        shape      = (view_mode == "list") and "list" or "grid",
        store      = store,
        settings   = settings,
    }
    local merged = {}
    for _i, g in ipairs(groups) do
        merged[#merged + 1] = {
            entry = libraryitem.entry_from_group(g, group_entry_opts),
            sort_value = g_value(g),
        }
    end
    for _i, row in ipairs(books) do
        if not is_archive_only_row(row) then
            row = decorate_archive_row(row)
            merged[#merged + 1] = {
                entry = libraryitem.entry_from_row(row, row_entry_opts),
                sort_value = b_value(row),
            }
        end
    end
    table.sort(merged, function(a, b)
        local av, bv = a.sort_value, b.sort_value
        if type(av) ~= type(bv) then
            -- Pathological: a string sort_value next to a numeric one
            -- (shouldn't happen given the table-driven extractors above,
            -- but stay deterministic if a future caller mixes them).
            return tostring(av) < tostring(bv)
        end
        if sort_asc then return av < bv end
        return av > bv
    end)

    local items = {}
    if parent_path then
        items[#items + 1] = back_entry_for(parent_path)
    end
    for _i, m in ipairs(merged) do
        items[#items + 1] = m.entry
    end
    return add_search_back(items)
end

-- ---------------------------------------------------------------------------
-- mix_renderer(menu, view_mode) — apply CoverMenu + (Mosaic|List)Menu
-- methods onto our Menu. Mirrors zen_ui group_view.lua:62-95 layout.
-- ---------------------------------------------------------------------------
local function mix_renderer(menu, view_mode)
    local CoverMenu  = require("covermenu")
    local MosaicMenu = require("mosaicmenu")
    local ListMenu   = require("listmenu")

    menu.updateItems     = CoverMenu.updateItems
    menu.onCloseWidget   = CoverMenu.onCloseWidget

    -- Per-mode mixins
    if view_mode == "mosaic" then
        menu._recalculateDimen   = MosaicMenu._recalculateDimen
        menu._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
        menu._do_cover_images    = true
        menu._do_center_partial_rows = false
        menu._do_hint_opened     = false
    else
        menu._recalculateDimen   = ListMenu._recalculateDimen
        menu._updateItemsBuildUI = ListMenu._updateItemsBuildUI
        menu._do_cover_images    = true
        menu._do_filename_only   = false
    end

    menu.display_mode_type = view_mode

    -- Codex round 2 finding 3: zen_ui supplies these methods because the
    -- mixin's _updateItemsBuildUI calls them as if they were native to the
    -- Menu. Provide real implementations (an empty stub causes
    -- been_opened=nil → MosaicMenu paints the "New" ribbon on every
    -- already-read book — which was every book in the user's bug report).
    if not menu.getBookInfo then
        menu.getBookInfo = function(file_path)
            if not file_path then return {} end
            -- Cloud-only entries use a synthetic readest-cloud:// path;
            -- they're not on disk so DocSettings can't read them. Return
            -- been_opened=false so the renderer doesn't show "New" but
            -- doesn't try to read a percent_finished either.
            if file_path:match("^readest%-cloud://") then
                return { been_opened = false }
            end
            local ok_ds, DocSettings = pcall(require, "docsettings")
            if not ok_ds then return {} end
            if not DocSettings:hasSidecarFile(file_path) then return {} end
            local ok_open, doc = pcall(DocSettings.open, DocSettings, file_path)
            if not ok_open or not doc then return {} end
            local summary = doc:readSetting("summary")
            local stats   = doc:readSetting("stats")
            return {
                been_opened      = true,
                percent_finished = doc:readSetting("percent_finished"),
                status           = summary and summary.status,
                pages            = stats and stats.pages,
            }
        end
    end
    if not menu.resetBookInfoCache then
        menu.resetBookInfoCache = function() end
    end
end

-- ---------------------------------------------------------------------------
-- smoke_test_render(menu) — render one synthetic local + one cloud-only
-- entry off-screen via pcall. If the renderer throws on either, fall back.
-- Catches contract drift in entry shape that the method-existence check
-- alone would miss (codex round 2 finding 3).
-- ---------------------------------------------------------------------------
local function smoke_test_render(menu)
    local probe = { is_file = true, file = "/tmp/readest-smoke.epub", text = "Smoke" }
    local cloud = libraryitem.entry_from_row({
        hash = "00smoke", title = "Cloud Smoke", cloud_present = 1, local_present = 0,
    })
    local saved_table = menu.item_table
    menu.item_table = { probe, cloud }
    local ok, err = pcall(function()
        if menu._recalculateDimen then menu:_recalculateDimen() end
        -- Don't call _updateItemsBuildUI — it appends real widgets to the
        -- menu's content_group which we don't want side-effects from.
        -- The dimension recalc is the failure-prone part anyway.
    end)
    menu.item_table = saved_table
    return ok, err
end

-- ---------------------------------------------------------------------------
-- title_for(search) — build the menu title bar text. When a search is
-- active, surface it so the user can see why their library "looks empty".
-- ---------------------------------------------------------------------------
local function title_for(search)
    local title = _("Syncest Library")
    if M._group_path then
        title = title .. ": " .. M._group_path
    end
    if search and search ~= "" then
        title = title .. " (" .. search .. ")"
    end
    return title
end

-- ---------------------------------------------------------------------------
-- handleSearch(menu, store, settings) — open InputDialog. Search is
-- session-transient (M._search), never persisted: a stuck filter from a
-- previous run was hiding all-but-matching books with no UI hint.
-- Includes a Clear button when a search is active so getting back to the
-- full library is one tap.
-- ---------------------------------------------------------------------------
local function handleSearch(menu, store, settings)
    local has_active = M._search and M._search ~= ""
    local dialog
    local apply = function(q)
        UIManager:close(dialog)
        M._search = (q and q ~= "") and q or nil
        -- switchItemTable accepts the new title as its first positional arg;
        -- call it that way instead of menu:setTitle (which doesn't exist on
        -- Menu — it's on TitleBar). One call updates both title + items.
        menu:switchItemTable(title_for(M._search),
            build_item_table(store, settings, M._search), 1)
    end
    local row = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function() UIManager:close(dialog) end,
        },
    }
    if has_active then
        row[#row + 1] = {
            text = _("Clear"),
            callback = function() apply(nil) end,
        }
    end
    row[#row + 1] = {
        text = _("Search"),
        is_enter_default = true,
        callback = function() apply(dialog:getInputText() or "") end,
    }
    dialog = InputDialog:new{
        title = _("Search library"),
        input = M._search or "",
        input_hint = _("Search title or author"),
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- refresh(menu, store, settings) — re-query store and update visible page.
-- Called after any view-menu change, search change, sync pull, or scan.
-- ---------------------------------------------------------------------------
function M.refresh()
    if not M._menu then return end
    local items = build_item_table(M._store, M._opts.settings, M._search)
    -- Preserve current page so cover-download completions (which call
    -- refresh too) don't yank the user back to page 1 mid-browse. The
    -- third arg to switchItemTable is "jump to this item number"; we
    -- compute the first item of the current page so the same page
    -- re-renders. If the new item count is shorter (e.g. after a sync
    -- delete), clamp to the last available item.
    local page    = M._menu.page    or 1
    local perpage = M._menu.perpage or 1
    local jump_to = math.max(1, math.min((page - 1) * perpage + 1, #items))
    M._menu:switchItemTable(title_for(M._search), items, jump_to)
end

function M.refreshCloud()
    if not M._opts or not M._store or not M._opts.client then return end
    local cloud_covers = require("syncest_lib.cloud_covers")
    cloud_covers.reset_download_failures()
    UIManager:show(InfoMessage:new{
        text = _("Refreshing cloud library in background…"),
        timeout = 2,
    })
    M._runCloudSync(M._opts, M._store, true, function(success)
        UIManager:show(InfoMessage:new{
            text = success
                and _("Cloud library refreshed.")
                or _("Cloud library refresh failed."),
            timeout = 3,
        })
    end)
end

function M.wipeCloudLibrary()
    if not M._opts or not M._store then return end
    local progress = InfoMessage:new{
        text = _("Wiping cloud library…"),
        timeout = 60,
    }
    UIManager:show(progress)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            syncbooks.wipeCloudLibrary({
                settings = M._opts.settings,
            }, function(success, _message, status, catalog_deleted)
                UIManager:close(progress)
                if success or catalog_deleted then
                    -- The authoritative catalog is gone. Preserve device-local
                    -- records, but make every row cloud-invisible immediately.
                    M._store:resetCatalog()
                    M.refresh()
                end
                if success then
                    UIManager:show(InfoMessage:new{
                        text = _("Cloud library wiped."), timeout = 3,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = catalog_deleted
                            and _("Library was cleared, but some cloud files could not be removed.")
                            or _("Cloud library wipe failed.")
                                .. " (status=" .. tostring(status) .. ")",
                        timeout = 5,
                    })
                end
            end)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- close() — tear down the Library Menu if it's open.
-- ---------------------------------------------------------------------------
-- UIManager:close fires the Menu's onCloseWidget, which M.open wraps to
-- clear M._menu + the visible-hash filter. That matters because background
-- work (book-sync and cover-download completions) calls M.refresh(): once
-- M._menu is nil, refresh() no-ops instead of repainting a ghost Library
-- on top of whatever replaced it — e.g. the reader, after a book was
-- opened from the Library. Safe to call when nothing is open.
function M.close()
    if M._menu then
        UIManager:close(M._menu)
    end
end

-- Close the current Menu and rebuild it from scratch using the latest
-- settings. Used after view-menu changes that affect layout dimensions
-- (view mode, column count, cover fit) — those are baked in at Menu
-- construction time via mix_renderer + nb_cols_portrait, so a soft
-- refresh wouldn't pick them up. Settings that only affect the SQL
-- query (sort, group, search) keep using M.refresh() since rebuilding
-- the whole Menu would be needless flicker.
function M.reopen()
    M.close()
    -- A view-mode/columns/cover-fit change is layout-only — keep the
    -- user's current drill-in. _keep_state tells M.open to skip its
    -- per-session resets (group_path, search reset).
    if M._opts then M.open(M._opts, { keep_state = true }) end
end

-- ---------------------------------------------------------------------------
-- runOpenSync(opts, menu) — fired after the menu is shown; runs lightScan
-- + cloud sync in a background-friendly way (Trapper coroutine for the
-- progress dialog; subprocess for the heavy walk happens inside
-- localscanner.fullSidecarWalk on first run / 24h interval).
--
-- Opening the cloud library is always read-only. Uploading books is an
-- explicit user action; auto-sync applies to reading data, not publication
-- of the local book catalog.
-- ---------------------------------------------------------------------------
local function runCloudSync(opts, store, full_refresh, completion_callback)
    if not opts.client then
        logger.info("ReadestLibrary runCloudSync: no client configured, skipping")
        return
    end
    local mode = "pull"
    local DocSettings = require("docsettings")
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    local statussync = require("syncest_lib.statussync")
    local deps = {
        now_ms = function() return os.time() * 1000 end,
        open_summary = function(file_path)
            local ok, ds = pcall(DocSettings.open, DocSettings, file_path)
            if not ok or not ds then return nil end
            return ds:readSetting("summary")
        end,
        write_status = function(file_path, ko_status)
            local ok, ds = pcall(DocSettings.open, DocSettings, file_path)
            if not ok or not ds then return end
            local summary = ds:readSetting("summary") or {}
            summary.status = ko_status  -- nil clears -> KOReader "New"
            summary.modified = os.date("%Y-%m-%d", os.time())
            ds:saveSetting("summary", summary)
            ds:flush()
            if ok_bl and BookList and BookList.setBookInfoCacheProperty then
                BookList.setBookInfoCacheProperty(file_path, "status", ko_status)
            end
        end,
    }
    local function reconcile() statussync.reconcileLocalStatuses(store, deps) end

    logger.info("ReadestLibrary runCloudSync: mode=" .. mode
        .. " auto_sync=" .. tostring(opts.settings.auto_sync))

    local function done(success, msg, status)
        logger.info("ReadestLibrary runCloudSync[" .. mode .. "] done: success="
            .. tostring(success) .. " msg=" .. tostring(msg) .. " status=" .. tostring(status))
        M.refresh()
    end

    -- WebDAV's LuaSocket transport is synchronous. Never execute it on the
    -- UI thread: slow mobile DNS or a route transition can otherwise block
    -- Android long enough to trigger an ANR kill. The child only fetches and
    -- serializes the response; all SQLite mutations remain in the parent.
    if M._cloud_refresh_pid then
        if not full_refresh then
            logger.info("ReadestLibrary cloud refresh already running, skipped")
            return
        end
        -- Manual Refresh is authoritative and supersedes the automatic pull
        -- launched when the library opened.
        local FFIUtil = require("ffi/util")
        FFIUtil.terminateSubProcess(M._cloud_refresh_pid)
        M._cloud_refresh_pid = nil
        logger.info("ReadestLibrary replaced automatic refresh with manual refresh")
    end
    local server = opts.client.server or opts.settings.sync_server
    local FFIUtil = require("ffi/util")
    M._cloud_refresh_generation = (M._cloud_refresh_generation or 0) + 1
    local generation = M._cloud_refresh_generation
    local result_path = require("syncest_lib.storage").tempDir()
        .. "/syncest_library_refresh_" .. tostring(generation) .. ".json"
    os.remove(result_path)

    local function apply_payload(payload)
        local ok_json, result = pcall(require("json").decode, payload or "")
        if not ok_json or type(result) ~= "table" then
            reconcile()
            done(false, "invalid background response", nil)
            return
        end

        -- Reuse the normal catalog-application path with an in-memory client;
        -- this callback performs no network I/O.
        local replay_client = {}
        function replay_client:pullBooks(_params, callback)
            callback(result.success, result.body, result.status)
        end
        syncbooks.pullBooks({
            client = replay_client,
            settings = opts.settings,
            store = store,
            full_refresh = full_refresh == true,
        }, function(success, msg, status)
            reconcile()
            done(success, msg, status)
            if completion_callback then completion_callback(success) end
        end)
    end

    local launched, pid = pcall(FFIUtil.runInSubProcess, function()
        local ok, payload = xpcall(function()
            local json = require("json")
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local result = { success = false, body = { books = {} } }
            client:pullBooks({ since = 0 }, function(success, body, status)
                result.success = success == true
                result.body = body or { books = {} }
                result.status = status
            end)
            return json.encode(result)
        end, debug.traceback)
        if not ok then
            payload = require("json").encode({
                success = false,
                body = { books = {} },
                status = tostring(payload),
            })
        end
        local file = io.open(result_path, "w")
        if file then
            file:write(payload)
            file:close()
        end
    end)
    if not launched or not pid then
        logger.warn("ReadestLibrary cloud refresh launch failed: " .. tostring(pid))
        os.remove(result_path)
        return
    end
    M._cloud_refresh_pid = pid

    local started_at = os.time()
    local poll
    poll = function()
        if not FFIUtil.isSubProcessDone(pid) then
            if os.time() - started_at < 75 then
                UIManager:scheduleIn(0.1, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            if M._cloud_refresh_pid == pid then M._cloud_refresh_pid = nil end
            os.remove(result_path)
            logger.warn("ReadestLibrary cloud refresh timed out")
            return
        end
        if M._cloud_refresh_pid == pid then M._cloud_refresh_pid = nil end
        local file = io.open(result_path, "r")
        local payload = file and file:read("*a") or nil
        if file then file:close() end
        os.remove(result_path)
        apply_payload(payload)
    end
    UIManager:scheduleIn(0.1, poll)
end
M._runCloudSync = runCloudSync

-- Yield once so the cached library paints before the background subprocess
-- starts. Network work itself is isolated by runCloudSync above.
local SYNC_DEFER_SECONDS = 0.05

local function runOpenSync(opts, store, menu)
    Trapper:wrap(function()
        logger.info("ReadestLibrary runOpenSync: start user="
            .. tostring(opts.settings.user_id and opts.settings.user_id:sub(1, 8))
            .. " auto_sync=" .. tostring(opts.settings.auto_sync))

        UIManager:scheduleIn(SYNC_DEFER_SECONDS, function()
            local ok, err = xpcall(function()
                logger.info("ReadestLibrary scheduled cloud sync: enter")
                -- Keep device-local presence independent from the cloud
                -- rebuild. Directory discovery belongs to explicit bulk
                -- push/pull; normal opens only validate known local files and
                -- ReadHistory entries.
                local localscanner = require("syncest_lib.localscanner")
                pcall(localscanner.lightScan, {
                    store = store,
                    ui = opts.ui,
                })
                local android = type(Device.isAndroid) == "function"
                    and Device:isAndroid()
                if not android and NetworkMgr:willRerunWhenOnline(function()
                        logger.info("ReadestLibrary network rerun: cloud sync")
                        local rerun_ok, rerun_err = xpcall(function()
                            runCloudSync(opts, store)
                        end, debug.traceback)
                        if not rerun_ok then
                            logger.warn("ReadestLibrary network rerun failed: " .. tostring(rerun_err))
                        end
                    end) then
                    logger.info("ReadestLibrary scheduled cloud sync: deferred until online")
                    return
                end
                runCloudSync(opts, store)
            end, debug.traceback)
            if not ok then
                logger.warn("ReadestLibrary scheduled cloud sync failed: " .. tostring(err))
            end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- open(opts) — main entry from the Readest plugin menu.
-- opts: { settings = G_reader_settings.readest_sync, sync_path, sync_auth }
-- ---------------------------------------------------------------------------
function M.open(opts, internal)
    local ok, err = pcall(M._open, opts, internal)
    if not ok then
        logger.err("Syncest Library open failed:", err)
        UIManager:show(InfoMessage:new{
            text = "Syncest Library error:\n" .. tostring(err),
            timeout = 10,
        })
    end
end

function M._open(opts, internal)
    local can_open, reason = M.canOpen(opts.settings)
    if not can_open then
        UIManager:show(InfoMessage:new{ text = reason, timeout = 3 })
        return
    end

    M._opts = opts
    -- Each fresh open starts at the root shelf; group drill-in state is
    -- per-session, never persisted to disk. M.reopen passes keep_state
    -- so a layout-change rebuild stays in the user's current folder.
    if not (internal and internal.keep_state) then
        M._group_path = nil
    end
    -- Migrate any stuck pre-fix library_search from settings into the
    -- transient session slot, then strip it from disk so future upgrades
    -- don't have to repeat this. (Leaving it in settings would re-pollute
    -- M._search next session.)
    if opts.settings.library_search then
        M._search = opts.settings.library_search
        opts.settings.library_search = nil
        G_reader_settings:saveSetting("webdav_sync", opts.settings)
    end
    local store = ensure_store(opts.settings)
    refresh_archive_index()

    -- Renderer compatibility check (codex round 2 finding 3)
    local ok, why = M.check_renderer_compat()
    if not ok then
        logger.warn("ReadestLibrary renderer compat check failed:", why)
        UIManager:show(InfoMessage:new{
            text = _("Cover Browser plugin required for full Library rendering. Falling back to plain list."),
            timeout = 5,
        })
        -- Plain Menu fallback: still usable, just no covers
    else
        -- Pass sync auth so the patched BIM can lazily download cloud
        -- cover.png files for cloud-only entries (covers are then
        -- shared between cloud + local presentations of the same hash).
        libraryitem.install({
            settings  = opts.settings,
        })
    end

    local Screen = Device.screen
    local view_mode = get_view_mode(opts.settings)

    local menu
    -- Custom TitleBar: close X on the right (via close_callback), search on
    -- the left, and the centered title acts as a tap target for the View
    -- menu. Stock TitleBar has no title-tap callback, so the actual tap
    -- handler is registered on the Menu's ges_events below — this title
    -- bar just supplies the dimen for the gesture range.
    local view_menu_callback = function()
        local LibraryViewMenu = require("syncest_lib.libraryviewmenu")
        local prev_group_by = active_group_by(opts.settings)
        LibraryViewMenu.show({
            settings         = opts.settings,
            on_change        = function()
                if active_group_by(opts.settings) ~= prev_group_by then
                    M._group_path = nil
                end
                M.refresh()
            end,
            on_layout_change = function()
                if active_group_by(opts.settings) ~= prev_group_by then
                    M._group_path = nil
                end
                M.reopen()
            end,
        })
    end
    local title_bar = TitleBar:new{
        width = Screen:getWidth(),
        fullscreen = "true",
        align = "center",
        title = title_for(M._search),
        left_icon = "appbar.search",
        left_icon_tap_callback  = function() handleSearch(menu, store, opts.settings) end,
        close_callback          = function() if menu then menu:onClose() end end,
    }
    -- Zen UI may rebuild the TitleBar's internal title group, which discards
    -- title_top_padding. Offset the whole rendered bar instead and reserve the
    -- same amount in its reported height so list and mosaic content also move
    -- down without overlapping it.
    local title_bar_offset = Screen:scaleBySize(24)
    local title_content_gap = Screen:scaleBySize(8)
    local title_reserved_space = title_bar_offset + title_content_gap
    title_bar.titlebar_height = title_bar.titlebar_height + title_reserved_space
    title_bar.dimen.h = title_bar.dimen.h + title_reserved_space
    local original_title_bar_paint = title_bar.paintTo
    title_bar.paintTo = function(self, bb, x, y)
        return original_title_bar_paint(self, bb, x, y + title_bar_offset)
    end
    -- Compute the orientation-appropriate per-page count up front and
    -- pass it as items_per_page. Menu's native _recalculateDimen
    -- (menu.lua:648) uses items_per_page; MosaicMenu's mixin uses
    -- nb_rows*nb_cols. Without setting items_per_page they disagree —
    -- Menu's heuristic computed ~14, MosaicMenu's mixin computed 9, the
    -- footer page-nav lagged the cell layout, and the cell layout
    -- attempted to fit 14 cells in 9 visible slots, leaking partial cells
    -- under the page nav. Make both formulas land on the same number by
    -- pre-setting items_per_page.
    local nb_cols_p = opts.settings.library_columns or 3
    local nb_rows_p = opts.settings.library_rows    or 3
    local nb_cols_l = opts.settings.library_columns_landscape or 4
    local nb_rows_l = opts.settings.library_rows_landscape    or 2
    local portrait  = Screen:getWidth() <= Screen:getHeight()
    local items_per_page = portrait and (nb_cols_p * nb_rows_p) or (nb_cols_l * nb_rows_l)

    local function run_book_interaction(kind, callback)
        local interaction_ok, interaction_err = xpcall(callback, debug.traceback)
        -- CoverMenu/MosaicMenu consult the callback result to decide whether
        -- the selection was fully handled.  Always consume Syncest rows; if
        -- this returns nil the stock file-opening path continues after our
        -- download dialog has already been shown.
        if interaction_ok then return true end
        logger.err("Syncest Library " .. kind .. " failed:\n" .. tostring(interaction_err))
        UIManager:show(InfoMessage:new{
            text = _("Book interaction failed."),
            timeout = 3,
        })
        return true
    end

    menu = Menu:new{
        name             = "readest_library",
        -- Zen UI's folder-cover patch treats unknown menus as non-file-manager
        -- views and disables EPUB cover images in MosaicMenu. This marker is
        -- the compatibility contract Zen uses for its own cover-grid tabs.
        _zen_tab_id      = "syncest_library",
        is_borderless    = true,
        is_popout        = false,
        covers_fullscreen = true,
        custom_title_bar = title_bar,
        item_table       = build_item_table(store, opts.settings, M._search),
        width            = Screen:getWidth(),
        height           = Screen:getHeight(),
        items_per_page    = items_per_page,
        nb_cols_portrait  = nb_cols_p,
        nb_rows_portrait  = nb_rows_p,
        nb_cols_landscape = nb_cols_l,
        nb_rows_landscape = nb_rows_l,
        onMenuSelect     = function(_self, item)
            return run_book_interaction("tap", function()
                M.handleTap(item, opts)
            end)
        end,
        onMenuHold       = function(_self, item)
            return run_book_interaction("hold", function()
                M.handleHold(item, opts)
            end)
        end,
    }
    title_bar.show_parent = menu

    if ok then
        mix_renderer(menu, view_mode)
        local smoke_ok, smoke_err = smoke_test_render(menu)
        if not smoke_ok then
            logger.warn("ReadestLibrary smoke test failed:", smoke_err)
            -- Already constructed; just leave the mixin in place. The
            -- smoke test is a tripwire, not a fatal check — we surface
            -- via logger so a future user report includes the trace.
        end
        librarypaint.install(menu)

        -- Wrap updateItems to recompute the visible-page hash set before
        -- any cell paints. Cell paints call BIM:getBookInfo, which calls
        -- trigger_cover_download — and we want THAT to only fire for
        -- on-screen items. set_visible_hashes runs FIRST so when the
        -- subsequent paint hits BIM, the filter is already in place.
        local orig_update = menu.updateItems
        menu.updateItems = function(self, ...)
            libraryitem.set_visible_hashes(self)
            local result = orig_update(self, ...)
            if view_mode == "list" and self.item_group then
                table.insert(self.item_group, 1, VerticalSpan:new{
                    width = Screen:scaleBySize(12),
                })
                self.item_group:resetLayout()
                if self.content_group then self.content_group:resetLayout() end
            end
            return result
        end

        -- Menu:new() ran the stock list renderer before we installed the
        -- CoverMenu/MosaicMenu mixins above. Build the selected cover view
        -- immediately; otherwise the first real grid build does not happen
        -- until the background cloud sync calls M.refresh() a few seconds
        -- later, making cached covers appear no faster than uncached ones.
        menu:updateItems()
    end

    -- Zen UI installs a generic Menu.onTap handler that opens its top menu
    -- for taps in the top 5% of the screen. Handle this menu's title first
    -- at the same event entry point so the two overlapping gesture ranges
    -- cannot race based on table iteration order.
    local inherited_on_tap = menu.onTap
    menu.onTap = function(self, arg, ges_ev)
        local pos = ges_ev and ges_ev.pos
        if pos and title_bar.dimen and pos:intersectWith(title_bar.dimen) then
            local left_dimen = title_bar.left_button and title_bar.left_button.dimen
            local right_dimen = title_bar.right_button and title_bar.right_button.dimen
            if not ((left_dimen and pos:intersectWith(left_dimen))
                    or (right_dimen and pos:intersectWith(right_dimen))) then
                view_menu_callback()
                return true
            end
        end
        if inherited_on_tap then
            return inherited_on_tap(self, arg, ges_ev)
        end
    end
    -- Stock KOReader has no generic Tap event on Menu, so retain a dedicated
    -- title event as the non-Zen path. With Zen present, either matching event
    -- now reaches the same view-menu action.
    menu.ges_events.TapTitle = {
        GestureRange:new{
            ges = "tap",
            range = function() return title_bar.dimen end,
        },
    }
    menu.onTapTitle = function() view_menu_callback() return true end

    -- Drop the module reference whenever this Menu leaves the screen —
    -- the title-bar X, the hardware Back key, M.close() on book-open, or
    -- any other path all funnel through UIManager:close → onCloseWidget.
    -- Without this, M._menu stays set after the Menu is gone and a later
    -- M.refresh() (book-sync or cover-download completion) repaints a
    -- ghost Library over whatever replaced it — e.g. the open reader.
    local prev_on_close_widget = menu.onCloseWidget
    menu.onCloseWidget = function(self, ...)
        if M._menu == self then
            M._menu = nil
            libraryitem.set_visible_hashes(nil)
        end
        if prev_on_close_widget then return prev_on_close_widget(self, ...) end
    end

    M._menu = menu
    UIManager:show(menu)

    runOpenSync(opts, store, menu)
end

-- ---------------------------------------------------------------------------
local function downloadDialogTitle(download_dir, filename)
    return tostring(download_dir or "") .. "/" .. tostring(filename or "")
end

-- Download callbacks run while their progress dialog is being dismissed.
-- Refresh both Syncest's menu and KOReader's underlying library/file views
-- after the UI stack has processed that close. Merely rebuilding our own
-- item table leaves KOReader's cached File Manager/History views stale until
-- they are manually refreshed or the application is restarted.
function M.refreshAfterDownload(callback)
    UIManager:nextTick(function()
        M.refresh()
        if M._menu then
            UIManager:setDirty(M._menu, "ui")
        end

        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm = ok and FileManager.instance
        if fm then
            if fm.history and fm.history.booklist_menu then
                fm.history:updateItemTable()
            end
            if fm.collections and fm.collections.booklist_menu then
                fm.collections:updateItemTable()
            end
            if fm.filesearcher and fm.filesearcher.booklist_menu then
                fm.filesearcher:updateItemTable()
            end
            if fm.file_chooser then
                fm:onRefresh()
                UIManager:setDirty(fm, "ui")
            end
        end

        if callback then callback() end
    end)
end

local function unarchiveBook(row, opts)
    local archived_path = row and row.archived_path
    local lfs = require("libs/libkoreader-lfs")
    if type(archived_path) ~= "string"
            or lfs.attributes(archived_path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = _("Archived copy could not be found."),
            timeout = 3,
        })
        refresh_archive_index()
        M.refresh()
        return false
    end

    local destination_dir = M._archive_original_dirs[archived_path]
        or opts.settings.library_download_dir
        or G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
    if type(destination_dir) == "string" then
        destination_dir = destination_dir:gsub("/+$", "")
    end
    if not destination_dir or destination_dir == ""
            or destination_dir == M._archive_dir
            or lfs.attributes(destination_dir, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = _("Set a valid library download or HOME folder first."),
            timeout = 3,
        })
        return false
    end

    local util = require("util")
    local _source_dir, filename = util.splitFilePathName(archived_path)
    local destination = destination_dir .. "/" .. filename
    if lfs.attributes(destination, "mode") == "file" then
        UIManager:show(InfoMessage:new{
            text = _("A book with this filename already exists in the destination."),
            timeout = 3,
        })
        return false
    end

    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager:moveFile(archived_path, destination_dir) then
        UIManager:show(InfoMessage:new{
            text = _("Could not move the book out of the archive."),
            timeout = 3,
        })
        return false
    end

    require("readhistory"):updateItem(archived_path, destination)
    require("readcollection"):updateItem(archived_path, destination)
    require("docsettings").updateLocation(archived_path, destination, false)
    M._archive_original_dirs[archived_path] = nil
    if M._archive_settings then
        M._archive_settings:saveSetting(
            "library_archive_original_dirs", M._archive_original_dirs)
        M._archive_settings:flush()
    end
    M._archive_paths[row.hash] = nil
    M._store:upsertBook({
        hash                 = row.hash,
        title                = row.title,
        local_present        = 1,
        file_path            = destination,
        _force_local_present = true,
    })
    M.refreshAfterDownload()
    UIManager:show(InfoMessage:new{
        text = _("Book moved out of archive."),
        timeout = 3,
    })
    return true
end

local function showCloudBookInformation(row)
    local metadata = {}
    if type(row.metadata_json) == "string" then
        local ok, parsed = pcall(require("json").decode, row.metadata_json)
        if ok and type(parsed) == "table" then metadata = parsed end
    end
    local lines = {
        _("Title") .. ": " .. tostring(row.title or metadata.title or ""),
        _("Author") .. ": " .. tostring(row.author or metadata.authors or ""),
        _("Format") .. ": " .. tostring(row.format or ""),
    }
    local optional = {
        { _("Series"), row.series or metadata.series },
        { _("Publisher"), metadata.publisher },
        { _("Language"), metadata.language },
        { _("Description"), metadata.description or metadata.summary },
    }
    for _, field in ipairs(optional) do
        if field[2] and tostring(field[2]) ~= "" then
            lines[#lines + 1] = field[1] .. ": " .. tostring(field[2])
        end
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Book information"),
        title_multilines = true,
        text = table.concat(lines, "\n\n"),
        text_type = "book_info",
    })
end

local function showCloudDownloadDialog(row, opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local PathChooser = require("ui/widget/pathchooser")
    local ConfirmBox = require("ui/widget/confirmbox")

    local download_dir = opts.settings.library_download_dir
        or G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
        or require("datastorage"):getDataDir()
    local filename = syncbooks.build_local_filename(row)
    if not filename then
        UIManager:show(InfoMessage:new{
            text = _("Unsupported book format."),
            timeout = 3,
        })
        return
    end

    local dialog
    local function refreshTitle()
        dialog:setTitle(downloadDialogTitle(download_dir, filename))
    end
    local function startDownload()
        UIManager:close(dialog)
        local progress = InfoMessage:new{
            text = _("Downloading…") .. " " .. (row.title or ""),
        }
        UIManager:show(progress)
        syncbooks.downloadBook(row, {
            settings = opts.settings,
            download_dir = download_dir,
            local_filename = filename,
        }, function(success, dst_or_err, status)
            UIManager:close(progress)
            if not success then
                local msg = (status == 404)
                    and _("Cloud copy unavailable.")
                    or _("Download failed.")
                UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
                return
            end
            M._store:upsertBook({
                hash = row.hash,
                title = row.title,
                local_present = 1,
                file_path = dst_or_err,
            })
            local read_prompt = ConfirmBox:new{
                text = _("File saved to:")
                    .. "\n" .. dst_or_err
                    .. "\n\n" .. _("Would you like to read the downloaded book now?"),
                ok_text = _("Read now"),
                cancel_text = _("Done"),
                ok_callback = function()
                    local ReaderUI = require("apps/reader/readerui")
                    M.close()
                    ReaderUI:showReader(dst_or_err)
                end,
            }
            M.refreshAfterDownload(function()
                UIManager:show(read_prompt)
            end)
        end)
    end

    local primary_buttons = {
        {
            text = _("Download"),
            callback = startDownload,
        },
    }
    if row.archived_path then
        primary_buttons[#primary_buttons + 1] = {
            text = _("Unarchive"),
            callback = function()
                UIManager:close(dialog)
                unarchiveBook(row, opts)
            end,
        }
    end

    dialog = ButtonDialog:new{
        title = downloadDialogTitle(download_dir, filename),
        title_multilines = true,
        buttons = {
            primary_buttons,
            {
                {
                    text = _("Choose folder"),
                    callback = function()
                        local picker
                        picker = PathChooser:new{
                            title = _("Pick a folder for downloaded books"),
                            path = download_dir,
                            select_directory = true,
                            select_file = false,
                            onConfirm = function(path)
                                download_dir = path
                                opts.settings.library_download_dir = path
                                G_reader_settings:saveSetting(
                                    "webdav_sync", opts.settings)
                                refreshTitle()
                            end,
                        }
                        UIManager:show(picker)
                    end,
                },
                {
                    text = _("Change filename"),
                    callback = function()
                        local input
                        input = InputDialog:new{
                            title = _("Enter filename"),
                            input = filename,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(input)
                                        end,
                                    },
                                    {
                                        text = _("Set filename"),
                                        is_enter_default = true,
                                        callback = function()
                                            local value = input:getInputValue()
                                            if value and value ~= "" then
                                                filename = value
                                            end
                                            UIManager:close(input)
                                            refreshTitle()
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(input)
                        input:onShowKeyboard()
                    end,
                },
            },
            {
                {
                    text = _("Book information"),
                    callback = function()
                        showCloudBookInformation(row)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        return true
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- handleTap(item, opts) — tap dispatch. Local books open immediately;
-- cloud-only books use an OPDS-style download workflow.
-- ---------------------------------------------------------------------------
function M.handleTap(item, opts)
    if not item then return end

    if item._readest_clear_search then
        M._search = nil
        M.refresh()
        return
    end

    -- Group folder entry → drill in
    if item._readest_group then
        M._group_path = item._readest_group.name
        M.refresh()
        return
    end

    -- "↩ Back" entry → pop one level (or up to root)
    if item._readest_is_back then
        M._group_path = item._readest_back_to
        M.refresh()
        return
    end

    if not item._readest_row then return end
    local row = item._readest_row
    local lfs = require("libs/libkoreader-lfs")

    if row.local_present == 1 and row.file_path then
        -- Tap-time recovery: file vanished from device
        if lfs.attributes(row.file_path, "mode") ~= "file" then
            -- If it's in the cloud, offer download instead of rescan
            if row.cloud_present ~= 1 then
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("File moved or deleted. Refresh the local index?"),
                    ok_callback = function()
                        Trapper:wrap(function()
                            localscanner.fullSidecarWalk({
                                store    = M._store,
                                home_dir = G_reader_settings:readSetting("home_dir"),
                            })
                            M.refresh()
                        end)
                    end,
                })
                return
            end
            -- cloud_present=1 — fall through to download path below
        else
            -- File exists locally — open it
            local ReaderUI = require("apps/reader/readerui")
            M.close()
            ReaderUI:showReader(row.file_path)
            return
        end
    end

    -- Cloud-only path: OPDS-style download options and post-download prompt.
    if row.cloud_present == 1 then
        showCloudDownloadDialog(row, opts)
        return
    end
end

-- ---------------------------------------------------------------------------
-- Action helpers (used by handleHold's button dialog)
-- ---------------------------------------------------------------------------

-- Run a book download without auto-opening the reader on success. In the
-- long-press action sheet the user wants the file on device, not to start
-- reading immediately.
local function downloadBookOnly(row, opts, after_cb)
    local download_dir = opts.settings.library_download_dir
        or G_reader_settings:readSetting("home_dir")
    if not download_dir or download_dir == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set Home folder in File Manager first to enable downloads."),
            timeout = 3,
        })
        if after_cb then after_cb(false) end
        return
    end
    local progress = InfoMessage:new{
        text = _("Downloading…") .. " " .. (row.title or ""),
    }
    UIManager:show(progress)
    syncbooks.downloadBook(row, {
        settings     = opts.settings,
        download_dir = download_dir,
    }, function(success, dst_or_err, status)
        UIManager:close(progress)
        if not success then
            local msg = (status == 404)
                and _("Cloud copy unavailable.")
                or _("Download failed.")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
            if after_cb then after_cb(false) end
            return
        end
        M._store:upsertBook({
            hash = row.hash, title = row.title,
            local_present = 1, file_path = dst_or_err,
        })
        M.refreshAfterDownload(function()
            if after_cb then after_cb(true) end
        end)
    end)
end

-- Remove the local file for a book and clear local_present in the store.
-- Returns true on success. Cloud-side state (cloud_present, deleted_at)
-- is untouched.
local function removeLocalFile(row)
    local lfs = require("libs/libkoreader-lfs")
    if not row.file_path or row.file_path == "" then return false end
    if lfs.attributes(row.file_path, "mode") == "file" then
        local ok = os.remove(row.file_path)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Could not delete the file."), timeout = 3,
            })
            return false
        end
    end
    -- Reset local presence in the store; cloud_present stays as-is so
    -- the row remains visible (and re-downloadable) if it's in the cloud.
    M._store:upsertBook({
        hash                 = row.hash,
        title                = row.title,
        local_present        = 0,
        _force_local_present = true,
        _clear_fields        = { "file_path" },
    })
    return true
end

-- ---------------------------------------------------------------------------
-- handleHold(item, opts) — long-press action sheet
-- ---------------------------------------------------------------------------
-- Presence-aware actions for cloud books and their optional local copies.
local function buildZenHoldHeader(item, row, zen_font)
    local Screen          = Device.screen
    local Size            = require("ui/size")
    local Geom            = require("ui/geometry")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local TextWidget      = require("ui/widget/textwidget")
    local ImageWidget     = require("ui/widget/imagewidget")

    -- These are the same measurements used by Zen UI's file context menu.
    local border = Size.border.thin
    local gap = Screen:scaleBySize(8)
    local dialog_w = math.floor(
        math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local available_w = dialog_w
        - 2 * (Size.border.window + Size.padding.button)
        - 2 * (Size.padding.default + Size.margin.default)
    local cover_max_h = Screen:scaleBySize(140)
    local cover_bb

    if row.local_present == 1 and row.file_path then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim then
            local info = BookInfoManager:getBookInfo(row.file_path, true)
            if info and info.cover_bb and info.has_cover and not info.ignore_cover then
                cover_bb = info.cover_bb:copy()
            end
        end
    elseif item and type(item.file) == "string" then
        local hash = cloud_covers.hash_from_uri(item.file)
        if hash then cover_bb = cloud_covers.load_cover_bb(hash, "list") end
    end

    local font_face = function(size)
        if zen_font then return zen_font.getFace(size) end
        return require("ui/font"):getFace("cfont", size)
    end
    local text_stack = VerticalGroup:new{ align = "left" }
    local text_col_w = available_w
    local cover_widget
    local header_h

    if cover_bb then
        local scale = math.min(
            cover_max_h / cover_bb:getHeight(),
            math.floor(cover_max_h * 0.72) / cover_bb:getWidth())
        local rendered_w = math.floor(cover_bb:getWidth() * scale)
        local rendered_h = math.floor(cover_bb:getHeight() * scale)
        cover_widget = FrameContainer:new{
            padding = 0,
            bordersize = border,
            ImageWidget:new{
                image = cover_bb,
                image_disposable = true,
                scale_factor = scale,
            },
        }
        header_h = rendered_h + 2 * border
        text_col_w = math.max(
            available_w - rendered_w - 2 * border - gap,
            Screen:scaleBySize(60))
    end

    table.insert(text_stack, TextWidget:new{
        text = row.title or "",
        face = font_face(20),
        bold = true,
        max_width = text_col_w,
    })
    if row.author and row.author ~= "" then
        table.insert(text_stack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
        table.insert(text_stack, TextWidget:new{
            text = row.author,
            face = font_face(17),
            max_width = text_col_w,
        })
    end
    if row.series and row.series ~= "" then
        table.insert(text_stack, VerticalSpan:new{ width = Screen:scaleBySize(3) })
        table.insert(text_stack, TextWidget:new{
            text = row.series,
            face = font_face(14),
            max_width = text_col_w,
        })
    end

    local text_h = text_stack:getSize().h
    header_h = math.max(header_h or 0, text_h)
    local content
    if cover_widget then
        content = HorizontalGroup:new{
            align = "center",
            cover_widget,
            HorizontalSpan:new{ width = gap },
            text_stack,
        }
    else
        content = text_stack
    end
    return LeftContainer:new{
        dimen = Geom:new{ w = available_w, h = header_h },
        content,
    }
end

function M.handleHold(item, opts)
    if not item or not item._readest_row then return end
    local row = item._readest_row
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox   = require("ui/widget/confirmbox")
    -- Match Zen UI's file-browser context menu when it is installed:
    -- left-aligned Nerd Font icons and the configured library font/size.
    -- Keep plain-text fallbacks so the cloud library remains standalone.
    local ok_icons, zen_icons = pcall(require, "common/inline_icon_map")
    local ok_font, zen_font = pcall(
        require, "modules/filebrowser/patches/library_font")
    local zen_font_name = ok_font and zen_font.getFontName()
    local zen_font_size = ok_font and zen_font.scaleValue(20) or nil

    local on_cloud = row.cloud_present == 1
    local lfs = require("libs/libkoreader-lfs")
    local on_local = row.local_present == 1
        and type(row.file_path) == "string"
        and row.file_path ~= ""
        and lfs.attributes(row.file_path, "mode") == "file"

    local dialog
    local function close() UIManager:close(dialog) end

    local rows = {}
    local function add_row(text, cb, icon)
        local label = text
        if ok_icons and icon and zen_icons[icon] then
            label = zen_icons[icon] .. "  " .. text
        end
        rows[#rows + 1] = {{
            text = label,
            align = "left",
            font_face = zen_font_name,
            font_size = zen_font_size,
            text_font_face = zen_font_name,
            text_font_size = zen_font_size,
            callback = cb,
        }}
    end

    -- Hide the row in the authoritative catalog before deleting its bytes.
    -- A failed cleanup then leaves only a harmless orphan; reversing this
    -- order can leave a visible catalog entry whose book file is already gone.
    local function doCloudDelete(after_cb)
        local progress = InfoMessage:new{
            text = _("Removing from cloud…") .. " " .. (row.title or ""),
        }
        UIManager:show(progress)
        local now = math.floor(os.time() * 1000)
        local tombstone = {}
        for k, v in pairs(row) do tombstone[k] = v end
        tombstone.deleted_at = now
        tombstone.updated_at = now
        syncbooks.pushBook(tombstone, {
            client = opts.client,
            settings = opts.settings,
        }, function(success)
            if not success then
                UIManager:close(progress)
                UIManager:show(InfoMessage:new{
                    text = _("Cloud catalog removal failed."), timeout = 3,
                })
                if after_cb then after_cb(false) end
                return
            end
            local local_copy_kept = on_local
            M._store:upsertBook({
                hash = row.hash, title = row.title,
                cloud_present = 0,
                deleted_at = local_copy_kept and nil or now,
                updated_at = now,
                _force_cloud_present = true,
                _clear_fields = local_copy_kept and { "deleted_at" } or nil,
            })
            M.refresh()
            syncbooks.deleteCloudFiles(row, {
                settings = opts.settings,
            }, function(cleaned, _msg, status)
                UIManager:close(progress)
                if not cleaned then
                    UIManager:show(InfoMessage:new{
                        text = _("Book was removed from the catalog, but cloud file cleanup failed.")
                            .. " (status=" .. tostring(status) .. ")",
                        timeout = 5,
                    })
                end
                if after_cb then after_cb(true, now, cleaned) end
            end)
        end)
    end

    -- Delete sub-options (parity with BookDetailView's three-item dropdown).
    if on_cloud and on_local then
        add_row(_("Remove from Cloud & Device"), function()
            close()
            UIManager:show(ConfirmBox:new{
                text = _("Remove this book from cloud and device?")
                    .. "\n\n" .. (row.title or ""),
                ok_text = _("Remove"),
                ok_callback = function()
                    doCloudDelete(function(success, now)
                        if not success then return end
                        removeLocalFile(row)
                        M._store:upsertBook({
                            hash = row.hash, title = row.title,
                            cloud_present = 0, local_present = 0,
                            deleted_at = now, updated_at = now,
                            _force_cloud_present = true,
                        })
                        M.refresh()
                    end)
                end,
            })
        end, "delete")
    end
    if on_cloud then
        add_row(_("Remove from Cloud"), function()
            close()
            UIManager:show(ConfirmBox:new{
                text = _("Remove this book from the cloud only?")
                    .. "\n\n" .. (row.title or ""),
                ok_text = _("Remove"),
                ok_callback = function()
                    doCloudDelete(function(success)
                        if success then M.refresh() end
                    end)
                end,
            })
        end, "delete")
    end
    if on_local then
        add_row(_("Remove from Device"), function()
            close()
            UIManager:show(ConfirmBox:new{
                text = _("Remove the local copy of this book?")
                    .. "\n\n" .. (row.title or ""),
                ok_text = _("Remove"),
                ok_callback = function()
                    if removeLocalFile(row) then M.refresh() end
                end,
            })
        end, "delete")
    end

    if row.archived_path and not on_local then
        add_row(_("Unarchive"), function()
            close()
            unarchiveBook(row, opts)
        end, "folder_open")
    end

    if on_cloud and not on_local then
        add_row(_("Download Book"), function()
            close()
            downloadBookOnly(row, opts)
        end, "download")
    end

    if #rows == 0 then return end

    local header = buildZenHoldHeader(item, row, ok_font and zen_font or nil)
    dialog = ButtonDialog:new{
        buttons = rows,
        _added_widgets = { header },
    }
    UIManager:show(dialog)
end

return M
