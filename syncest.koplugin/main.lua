local Dispatcher = require("dispatcher")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Menu = require("ui/widget/menu")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local FFIUtil = require("ffi/util")
local Time = require("ui/time")
local T = FFIUtil.template
local _ = require("gettext")

local WebDavAuth = require("webdav_auth")
local SyncConfig = require("syncest_syncconfig")
local SyncAnnotations = require("syncest_syncannotations")
local SyncStats = require("syncest_syncstats")
local SyncVocab = require("syncest_syncvocab")

local Syncest = WidgetContainer:new{
    name = "syncest",
    title = _("Syncest"),
    settings = nil,
}

local API_CALL_DEBOUNCE_DELAY = 30
local AUTO_PUSH_SUPPRESS_AFTER_PULL = 45
local AUTO_PUSH_WEBDAV_ENABLED = true
local STARTUP_AUTO_PULL_PROGRESS_ENABLED = true
local SYNC_PLUGIN_INERT_DIAGNOSTIC = false
local AUTO_SYNC_POLL_INTERVAL = 0.25
local PROGRESS_PULL_POLL_INTERVAL = 0.05
local STARTUP_PROGRESS_PULL_WAIT = 0.35
local PAGE_TURN_PUSH_DELAY = 5
local CHAPTER_PUSH_DELAY = 0.1
local AUTO_SYNC_MAX_POLLS = 260
local BOOKS_SYNC_MAX_POLLS = 1200
local RESUME_PROGRESS_PULL_DEBOUNCE = 5
local RESUME_PROGRESS_INITIAL_DELAY = 0.5
local RESUME_PROGRESS_RETRY_DELAYS = { 2, 5 }
local PROGRESS_HISTORY_RETENTION = 25

local function progress_history_device_id(settings)
    if settings.progress_history_device_id
            and settings.progress_history_device_id ~= "" then
        return settings.progress_history_device_id
    end
    local raw = table.concat({
        tostring(os.time()),
        tostring(math.random(100000, 999999)),
    }, "-")
    settings.progress_history_device_id = raw
    return raw
end

local function progress_history_device_name(settings)
    if settings.progress_history_device_name
            and settings.progress_history_device_name ~= "" then
        return settings.progress_history_device_name
    end
    local name = "KOReader"
    if Device and Device.getModel then
        local ok, model = pcall(Device.getModel, Device)
        if ok and model and tostring(model) ~= "" then name = tostring(model) end
    end
    return name
end

local function first_sentence(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    local sentence_end = text:find("[%.%!%?…][\"'’”%)]*%s")
    if sentence_end then text = text:sub(1, sentence_end) end
    local max_chars = 140
    if #text > max_chars then
        text = text:sub(1, max_chars):gsub("%s+%S*$", "") .. "…"
    end
    return text
end

local function progress_history_context(ui, config)
    local context = {}
    if not ui or not ui.document then return context end
    local page = tonumber(config and config.currentPage)
        or (ui.getCurrentPage and ui:getCurrentPage())
    if page and ui.toc and ui.toc.getTocTitleByPage then
        local ok, chapter = pcall(ui.toc.getTocTitleByPage, ui.toc, page)
        if ok and type(chapter) == "string" and chapter ~= "" then
            context.chapterTitle = chapter:gsub("%s+", " ")
        end
    end

    if not ui.document.getTextFromPositions then return context end
    local ok, result = pcall(function()
        if ui.document.info and ui.document.info.has_pages
                and ui.document.getTextBoxes and page then
            local boxes = ui.document:getTextBoxes(page)
            local first_line = boxes and boxes[1]
            local last_line = boxes and boxes[#boxes]
            local first = first_line and first_line[1]
            local last = last_line and last_line[#last_line]
            if not (first and last) then return nil end
            return ui.document:getTextFromPositions(
                { x = first.x0, y = first.y0, page = page },
                { x = last.x1, y = last.y1, page = page }, true)
        end
        return ui.document:getTextFromPositions(
            { x = 0, y = 0 },
            { x = Device.screen:getWidth(), y = Device.screen:getHeight() },
            true)
    end)
    if ok and type(result) == "table" then
        context.excerpt = first_sentence(result.text)
    end
    return context
end

local function add_progress_history(payload, settings, source, reason, ui)
    local config = payload and payload.configs and payload.configs[1]
    if type(config) ~= "table" then return payload end
    local timestamp = tonumber(config.updatedAt) or os.time() * 1000
    local device_id = progress_history_device_id(settings)
    local resolved_source = source == "manual" and "manual" or "auto"
    local progress = type(config.progress) == "table" and config.progress or {}
    local location_key = tostring(config.currentPage or progress[1]
        or config.xpointer or ""):gsub("[^%w_.%-]", "_")
    local context = progress_history_context(ui, config)
    payload.progressHistory = {
        deviceId = device_id,
        deviceName = progress_history_device_name(settings),
        limit = tonumber(settings.progress_history_retention)
            or PROGRESS_HISTORY_RETENTION,
        entry = {
            id = table.concat({
                device_id,
                tostring(timestamp),
                resolved_source,
                location_key,
            }, "-"),
            timestamp = timestamp,
            source = resolved_source,
            reason = reason,
            config = config,
            chapterTitle = context.chapterTitle,
            excerpt = context.excerpt,
        },
    }
    return payload
end

local function write_background_result(path, success, message)
    local file = io.open(path, "w")
    if not file then return end
    file:write(success and "ok" or "error", "\n", message or "")
    file:close()
end

local function read_background_result(path)
    local file = io.open(path, "r")
    if not file then return false, "background sync produced no result" end
    local status = file:read("*l")
    local message = file:read("*a")
    file:close()
    os.remove(path)
    return status == "ok", message
end

local function write_background_json_result(path, data)
    local ok_json, json = pcall(require, "json")
    if not ok_json then return false end
    local ok, encoded = pcall(json.encode, data or {})
    if not ok then return false end
    local file = io.open(path, "w")
    if not file then return false end
    file:write(encoded)
    file:close()
    return true
end

local function read_background_json_result(path)
    local file = io.open(path, "r")
    if not file then return nil, "background sync produced no result" end
    local content = file:read("*a")
    file:close()
    os.remove(path)
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "json module unavailable" end
    local ok, parsed = pcall(json.decode, content or "")
    if not ok or type(parsed) ~= "table" then
        return nil, "background sync produced invalid result"
    end
    return parsed
end

local function peek_background_json_result(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil end
    local ok, parsed = pcall(json.decode, content or "")
    if not ok or type(parsed) ~= "table" then return nil end
    return parsed
end

local function copy_settings(settings)
    local copied = {}
    for k, v in pairs(settings or {}) do
        if type(v) == "table" then
            local nested = {}
            for nk, nv in pairs(v) do nested[nk] = nv end
            copied[k] = nested
        else
            copied[k] = v
        end
    end
    return copied
end

function Syncest:_runSafely(label, fn, interactive)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then return true end
    logger.warn("Syncest " .. tostring(label) .. " failed: " .. tostring(err))
    if interactive then
        UIManager:show(InfoMessage:new{
            text = _("Syncest sync failed. Check the KOReader log for details."),
            timeout = 4,
        })
    end
    return false
end

function Syncest:_runBackgroundJSON(label, result_prefix, child_fn, on_complete, on_failure, max_polls, on_poll)
    if not self._background_jobs then self._background_jobs = {} end
    if self._background_jobs[label] then
        logger.info("Syncest " .. label .. ": already running, skipped")
        return false
    end

    local DataStorage = require("datastorage")
    local result_file = DataStorage:getSettingsDir()
        .. "/" .. result_prefix .. "_" .. tostring(os.time()) .. ".json"
    os.remove(result_file)

    logger.info("Syncest " .. label .. ": launching")
    local launch_ok, pid_or_err = pcall(FFIUtil.runInSubProcess, function()
        local ok, result = xpcall(child_fn, debug.traceback)
        if not ok then
            result = { success = false, message = tostring(result) }
        elseif type(result) ~= "table" then
            result = { success = result == true, message = tostring(result) }
        elseif result.success == nil then
            result.success = true
        end
        write_background_json_result(result_file, result)
    end)
    if not launch_ok or not pid_or_err then
        logger.warn("Syncest " .. label .. ": launch failed "
            .. tostring(pid_or_err))
        os.remove(result_file)
        if on_failure then on_failure("launch failed") end
        return false
    end

    local pid = pid_or_err
    self._background_jobs[label] = pid
    local polls = 0
    local poll
    poll = function()
        polls = polls + 1
        if on_poll then on_poll() end
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < (max_polls or AUTO_SYNC_MAX_POLLS) then
                UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Syncest " .. label .. ": timed out")
            self._background_jobs[label] = nil
            os.remove(result_file)
            if on_failure then on_failure("timed out") end
            return
        end

        self._background_jobs[label] = nil
        local result, message = read_background_json_result(result_file)
        if not result or result.success ~= true then
            logger.warn("Syncest " .. label .. ": failed "
                .. tostring(result and result.message or message))
            if on_failure then
                on_failure(result and result.message or message)
            end
            return
        end
        logger.info("Syncest " .. label .. ": success")
        self:_syncConnectionRestored()
        if on_complete then on_complete(result) end
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
    return true
end

function Syncest:_isProgressSyncBusy()
    return self._auto_push_progress_running
        or self._auto_pull_progress_running
        or self._pending_auto_push_progress ~= nil
end

function Syncest:_isAnnotationSyncBusy()
    local jobs = self._background_jobs or {}
    return jobs["background annotations push"] ~= nil
        or jobs["background annotations pull"] ~= nil
        or self["_deferred_background annotations push"] ~= nil
        or self["_deferred_background annotations pull"] ~= nil
end

function Syncest:_isOtherDataSyncBusy()
    local jobs = self._background_jobs or {}
    return jobs["background stats push"] ~= nil
        or jobs["background stats pull"] ~= nil
        or jobs["background vocab push"] ~= nil
        or jobs["background vocab pull"] ~= nil
        or self["_deferred_background stats push"] ~= nil
        or self["_deferred_background stats pull"] ~= nil
        or self["_deferred_background vocab push"] ~= nil
        or self["_deferred_background vocab pull"] ~= nil
end

function Syncest:_isAutoSyncBundleBusy()
    return self:_isProgressSyncBusy()
        or self:_isAnnotationSyncBusy()
        or self:_isOtherDataSyncBusy()
end

function Syncest:_scheduleAutoSyncBundleNotifyFlush()
    if self._auto_sync_bundle_notify_task then
        UIManager:unschedule(self._auto_sync_bundle_notify_task)
    end
    local started_at = os.time()
    self._auto_sync_bundle_notify_task = function()
        if self:_isAutoSyncBundleBusy() then
            if os.time() - started_at < 20 then
                UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL,
                    self._auto_sync_bundle_notify_task)
            else
                self._auto_sync_bundle_notify_task = nil
            end
            return
        end
        self._auto_sync_bundle_notify_task = nil
        if self._notify_task then
            UIManager:unschedule(self._notify_task)
        end
        self._notify_task = function()
            self:_flushAutoNotify()
        end
        UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, self._notify_task)
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL,
        self._auto_sync_bundle_notify_task)
end

function Syncest:_deferUntilProgressIdle(key, fn, delay)
    if not self:_isProgressSyncBusy() then return false end
    local task_key = "_deferred_" .. key
    if self[task_key] then
        UIManager:unschedule(self[task_key])
    end
    logger.info("Syncest " .. key .. ": deferred until progress sync is idle")
    self[task_key] = function()
        self[task_key] = nil
        fn()
    end
    UIManager:scheduleIn(delay or 3, self[task_key])
    return true
end

function Syncest:_deferUntilProgressAndAnnotationsIdle(key, fn, delay)
    if not self:_isProgressSyncBusy() and not self:_isAnnotationSyncBusy() then
        return false
    end
    local task_key = "_deferred_" .. key
    if self[task_key] then
        UIManager:unschedule(self[task_key])
    end
    logger.info("Syncest " .. key .. ": deferred until progress/annotations are idle")
    self[task_key] = function()
        self[task_key] = nil
        fn()
    end
    UIManager:scheduleIn(delay or 3, self[task_key])
    return true
end

function Syncest:_queueSyncMarker(book)
    if type(book) ~= "table" then return false end
    local hash = book.bookHash or book.hash or book.book_hash
    if not hash then return false end
    if not self._pending_sync_markers then self._pending_sync_markers = {} end
    local copied = {}
    for k, v in pairs(book) do
        if type(v) == "table" then
            local nested = {}
            for nk, nv in pairs(v) do nested[nk] = nv end
            copied[k] = nested
        else
            copied[k] = v
        end
    end
    self._pending_sync_markers[hash] = copied
    self:_scheduleSyncMarkerEnsure()
    return true
end

function Syncest:_scheduleSyncMarkerEnsure(delay)
    if self._sync_marker_task then return end
    self._sync_marker_task = function()
        self._sync_marker_task = nil
        self:_runSyncMarkerEnsure()
    end
    UIManager:scheduleIn(delay or 8, self._sync_marker_task)
end

function Syncest:_runSyncMarkerEnsure()
    if not self._pending_sync_markers then return false end
    if self:_isProgressSyncBusy()
            or self:_isAnnotationSyncBusy()
            or self:_isOtherDataSyncBusy() then
        self:_scheduleSyncMarkerEnsure(5)
        return false
    end
    if self._background_jobs
            and self._background_jobs["background sync marker ensure"] then
        self:_scheduleSyncMarkerEnsure(5)
        return false
    end
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    local hash, book = next(self._pending_sync_markers)
    if not hash or not book then return false end
    self._pending_sync_markers[hash] = nil

    return self:_runBackgroundJSON(
        "background sync marker ensure",
        "syncest_marker_ensure",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local ok = client:ensureSyncMarker(book)
            return { success = ok == true }
        end,
        function()
            if self._pending_sync_markers and next(self._pending_sync_markers) then
                self:_scheduleSyncMarkerEnsure(2)
            end
        end,
        function(message)
            logger.warn("Syncest sync marker ensure failed: " .. tostring(message))
            if self._pending_sync_markers and next(self._pending_sync_markers) then
                self:_scheduleSyncMarkerEnsure(10)
            end
        end,
        AUTO_SYNC_MAX_POLLS)
end

function Syncest:_progressPayloadSignature(payload)
    if type(payload) ~= "table"
            or type(payload.configs) ~= "table"
            or type(payload.configs[1]) ~= "table" then
        return nil
    end
    local config = payload.configs[1]
    local progress = type(config.progress) == "table" and config.progress or {}
    return table.concat({
        tostring(config.bookHash or ""),
        tostring(progress[1] or config.currentPage or ""),
        tostring(progress[2] or config.pageCount or ""),
        tostring(config.xpointer or ""),
        tostring(payload.readingStatus or ""),
        tostring(payload.readingStatusUpdatedAt or ""),
    }, "|")
end

function Syncest:_progressPayloadAlreadyPushed(payload)
    if not self.ui or not self.ui.doc_settings then return false end
    local signature = self:_progressPayloadSignature(payload)
    if not signature then return false end
    local doc_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
    return doc_sync.last_pushed_progress_signature == signature
end

function Syncest:_markProgressPayloadPushed(payload)
    if not self.ui or not self.ui.doc_settings then return end
    local signature = self:_progressPayloadSignature(payload)
    if not signature then return end
    local doc_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
    doc_sync.last_pushed_progress_signature = signature
    doc_sync.last_pushed_at_config = os.time()
    self.ui.doc_settings:saveSetting("webdav_sync", doc_sync)
    self.ui.doc_settings:flush()
end

function Syncest:_notifyProgressPushResult(notify, success, unchanged)
    if not notify or not self:_notificationEnabled("progress") then return end
    if notify == "chapter" then
        local text
        if not success then
            text = _("Chapter progress push failed")
        elseif unchanged then
            text = _("Chapter progress already synced")
        else
            text = _("Chapter progress pushed")
        end
        UIManager:show(Notification:new{
            text = text,
            timeout = 2,
        })
    elseif notify == "manual" then
        UIManager:show(Notification:new{
            text = success
                and (unchanged and _("Progress already synced")
                    or _("Progress pushed"))
                or _("Progress push failed"),
            timeout = 2,
        })
    elseif success then
        self:_autoNotify("progress", "pushed")
    else
        self:_autoFailureNotify("progress")
    end
end

function Syncest:_backgroundPushProgress(payload, notify)
    local config = payload and payload.configs and payload.configs[1]
    local book_hash = config and config.bookHash
    local history_entry = payload and payload.progressHistory
        and payload.progressHistory.entry
    local manual_history = history_entry
        and history_entry.source == "manual"
    if self:_progressPayloadAlreadyPushed(payload) and not manual_history then
        logger.info("Syncest background progress push: unchanged, skipped")
        self:_notifyProgressPushResult(notify, true, true)
        return true
    end
    if self._auto_push_progress_running then
        logger.info("Syncest background progress push: already running, queued latest")
        self._pending_auto_push_progress = {
            payload = payload,
            notify = notify,
        }
        return false
    end
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then
        logger.warn("Syncest background progress push: missing sync server")
        self:_notifyProgressPushResult(notify, false)
        return false
    end

    local DataStorage = require("datastorage")
    local result_file = DataStorage:getSettingsDir()
        .. "/syncest_progress_push_" .. tostring(os.time()) .. ".result"
    local committed_file = result_file .. ".committed"
    os.remove(result_file)
    os.remove(committed_file)

    logger.info("Syncest background progress push: launching")
    local launch_ok, pid_or_err = pcall(FFIUtil.runInSubProcess, function()
        local ok, success, message = xpcall(function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local done_success = false
            local done_message = nil
            client:pushChanges(
                payload,
                function(success2, _response, status)
                    done_success = success2 == true
                    done_message = tostring(status or "")
                end,
                notify == "chapter" and function()
                    write_background_result(committed_file, true, "committed")
                end or nil)
            return done_success, done_message
        end, debug.traceback)
        if not ok then
            write_background_result(result_file, false, success)
        else
            write_background_result(result_file, success, message)
        end
    end)
    if not launch_ok or not pid_or_err then
        logger.warn("Syncest background progress push: launch failed "
            .. tostring(pid_or_err))
        os.remove(result_file)
        os.remove(committed_file)
        self:_notifyProgressPushResult(notify, false)
        return false
    end

    local pid = pid_or_err
    self._auto_push_progress_running = true
    self._auto_push_progress_pid = pid
    local polls = 0
    local committed_notified = false
    local poll
    poll = function()
        polls = polls + 1
        if not committed_notified and notify == "chapter"
                and peek_background_json_result(committed_file) then
            committed_notified = true
            os.remove(committed_file)
            self:_markProgressPayloadPushed(payload)
            self:_notifyProgressPushResult(notify, true)
        end
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < AUTO_SYNC_MAX_POLLS then
                UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Syncest background progress push: timed out")
            self._auto_push_progress_running = false
            self._auto_push_progress_pid = nil
            os.remove(result_file)
            os.remove(committed_file)
            if not committed_notified then
                self:_notifyProgressPushResult(notify, false)
            end
            return
        end

        self._auto_push_progress_running = false
        self._auto_push_progress_pid = nil
        os.remove(committed_file)
        local success, message = read_background_result(result_file)
        if success then
            logger.info("Syncest background progress push: success")
            self:_syncConnectionRestored()
            if payload and payload.configs and payload.configs[1] then
                self:_queueSyncMarker(payload.configs[1])
            end
            if not committed_notified then
                self:_markProgressPayloadPushed(payload)
                self:_notifyProgressPushResult(notify, true)
            end
        else
            logger.warn("Syncest background progress push: failed "
                .. tostring(message))
            -- Once progress.json is committed, a later history-bookkeeping
            -- failure must not turn the chapter acknowledgement into a
            -- contradictory failure notification.
            if not committed_notified then
                self:_notifyProgressPushResult(notify, false)
            end
        end
        local pending = self._pending_auto_push_progress
        if pending then
            self._pending_auto_push_progress = nil
            self:_backgroundPushProgress(pending.payload, pending.notify)
        end
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
    return true
end

function Syncest:_promptBackwardProgress(book_hash, config, apply_result)
    local message = _("Cloud progress is behind your current location.")
        .. "\n\n" .. _("Go back to cloud progress?")
    if type(apply_result) == "table"
            and type(apply_result.current) == "number"
            and type(apply_result.target) == "number" then
        message = T(
            _("Cloud progress is behind your current location.\n\nCurrent page: %1\nCloud page: %2\n\nGo back to cloud progress?"),
            tostring(apply_result.current),
            tostring(apply_result.target))
    end
    UIManager:show(ConfirmBox:new{
        text = message,
        ok_text = _("Go back"),
        cancel_text = _("Stay here"),
        ok_callback = function()
            if self:getBookIdentifiers() ~= book_hash then
                return
            end
            SyncConfig:applyBookConfig(self.ui, config, true)
        end,
    })
end

function Syncest:_backgroundPullProgress(book_hash, notify, force_apply, file, options)
    options = options or {}
    local function failed(message)
        if notify and not options.suppress_failure_notify then
            self:_autoFailureNotify("progress")
        end
        if options.on_failure then options.on_failure(message) end
    end
    if self._auto_pull_progress_running then
        logger.info("Syncest background progress pull: already running, skipped")
        return false
    end
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" or not book_hash then
        logger.warn("Syncest background progress pull: missing sync server/book")
        return false
    end

    local DataStorage = require("datastorage")
    local result_file = DataStorage:getSettingsDir()
        .. "/syncest_progress_pull_" .. tostring(os.time()) .. ".json"
    os.remove(result_file)

    logger.info("Syncest background progress pull: launching book="
        .. tostring(book_hash))
    local launch_ok, pid_or_err = pcall(FFIUtil.runInSubProcess, function()
        local result = { success = false, message = "" }
        local ok, err = xpcall(function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            client:pullChanges({
                since = 0,
                type = "configs",
                book = book_hash,
                retries = options.retries,
            }, function(success, response, status)
                result.success = success == true
                result.status = status
                if result.success and response and response.configs then
                    result.config = response.configs[1]
                    result.readingStatus = response.readingStatus
                    result.readingStatusUpdatedAt = response.readingStatusUpdatedAt
                else
                    result.message = tostring(status or "")
                end
            end)
        end, debug.traceback)
        if not ok then
            result.success = false
            result.message = tostring(err)
        end
        write_background_json_result(result_file, result)
    end)
    if not launch_ok or not pid_or_err then
        logger.warn("Syncest background progress pull: launch failed "
            .. tostring(pid_or_err))
        os.remove(result_file)
        failed("launch failed")
        return false
    end

    local pid = pid_or_err
    self._auto_pull_progress_running = true
    self._auto_pull_progress_pid = pid
    local polls = 0
    local function finish()
        self._auto_pull_progress_running = false
        self._auto_pull_progress_pid = nil
        local result, message = read_background_json_result(result_file)
        if not result or result.success ~= true then
            logger.warn("Syncest background progress pull: failed "
                .. tostring(result and result.message or message))
            failed(result and result.message or message)
            return
        end

        logger.info("Syncest background progress pull: success")
        self:_syncConnectionRestored()
        if options.on_success then options.on_success() end
        if file then
            if result.config then
                self:_applyFileProgress(file, result.config)
            end
            self:_applyProgressReadingStatus(book_hash, result)
            if notify then self:_autoNotify("progress", "pulled", 0) end
            return
        end
        if self:getBookIdentifiers() ~= book_hash then
            logger.warn("Syncest background progress pull: current book changed, skipping apply")
            return
        end
        self._suppress_auto_push_config_until =
            os.time() + AUTO_PUSH_SUPPRESS_AFTER_PULL
        if self.ui and self.ui.doc_settings then
            local doc_readest_sync =
                self.ui.doc_settings:readSetting("webdav_sync") or {}
            doc_readest_sync.last_synced_at_config = os.time()
            self.ui.doc_settings:saveSetting("webdav_sync", doc_readest_sync)
            self.ui.doc_settings:flush()
        end
        local apply_result
        if result.config then
            apply_result = SyncConfig:applyBookConfig(
                self.ui, result.config, force_apply == true)
            self:_applyProgressReadingStatus(book_hash, result)
            if not force_apply and apply_result
                    and apply_result.status == "skipped_backward" then
                self:_promptBackwardProgress(book_hash, result.config, apply_result)
                return
            end
        else
            self:_applyProgressReadingStatus(book_hash, result)
        end
        if notify then self:_autoNotify("progress", "pulled", 0) end
    end
    local poll
    poll = function()
        polls = polls + 1
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < AUTO_SYNC_MAX_POLLS then
                UIManager:scheduleIn(PROGRESS_PULL_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Syncest background progress pull: timed out")
            self._auto_pull_progress_running = false
            self._auto_pull_progress_pid = nil
            os.remove(result_file)
            failed("timed out")
            return
        end
        finish()
    end
    -- ReaderReady runs while Android input is already inhibited. Give the
    -- normally fast WebDAV child a tightly bounded chance to finish here so
    -- its location can be applied before KOReader paints the first page.
    -- Slow/offline requests remain asynchronous and cannot stall startup.
    if options.startup_wait then
        local deadline = Time.now() + Time.s(STARTUP_PROGRESS_PULL_WAIT)
        while not FFIUtil.isSubProcessDone(pid) and Time.now() < deadline do
            FFIUtil.usleep(10000)
        end
        if FFIUtil.isSubProcessDone(pid) then
            logger.info("Syncest startup progress pull: completed before first paint")
            finish()
            return true
        end
        logger.info("Syncest startup progress pull: continuing asynchronously")
    end
    -- Progress pulls happen at book-open time, where even small scheduling
    -- delays are noticeable. Check once on the next UI tick, then fall back to
    -- the normal polling cadence if the WebDAV child is still running.
    UIManager:scheduleIn(0, poll)
    return true
end

function Syncest:_backgroundPushStats(notify, manual, retried)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    if self:_deferUntilProgressAndAnnotationsIdle("background stats push", function()
            self:_backgroundPushStats(notify, manual, retried)
        end) then return false end
    local settings = copy_settings(self.settings)
    local failure_fn = notify and function() self:_autoFailureNotify("stats") end or nil
    return self:_runBackgroundJSON("background stats push", "syncest_stats_push", function()
        local Stats = require("syncest_syncstats")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        -- A manual push is also the repair path: resend the complete local
        -- history so older rows missed by another device can be merged into
        -- stats.json. Automatic pushes remain incremental.
        local cursor = manual and 0 or (settings.stats_push_cursor or 0)
        local books, pages = Stats:collectSince(cursor)
        if #pages == 0 then
            return { success = true, empty = true }
        end
        local max_start = cursor
        for _, p in ipairs(pages) do
            if p.start_time > max_start then max_start = p.start_time end
        end
        local pushed = false
        local message = nil
        client:pushChanges({
            books = {},
            notes = {},
            configs = {},
            statBooks = books,
            statPages = pages,
        }, function(success, _body, status)
            pushed = success == true
            message = tostring(status or "")
        end)
        if not pushed then
            return { success = false, message = message }
        end
        return {
            success = true,
            stats_push_cursor = max_start,
            stats_last_pushed_at = os.time(),
        }
    end, function(result)
        if result.empty then
            if manual and notify and self:_notificationEnabled("stats") then
                UIManager:show(Notification:new{
                    text = _("No new reading statistics to push."), timeout = 2,
                })
            elseif not retried then
                UIManager:scheduleIn(2, function()
                    self:_backgroundPushStats(notify, false, true)
                end)
            end
        else
            self.settings.stats_push_cursor = result.stats_push_cursor
            self.settings.stats_last_pushed_at = result.stats_last_pushed_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            if notify then self:_autoNotify("stats", "pushed") end
        end
    end, failure_fn)
end

function Syncest:_backgroundPullStats(notify, manual)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    if self:_deferUntilProgressAndAnnotationsIdle("background stats pull", function()
            self:_backgroundPullStats(notify, manual)
        end) then return false end
    local settings = copy_settings(self.settings)
    local failure_fn = notify and function() self:_autoFailureNotify("stats") end or nil
    return self:_runBackgroundJSON("background stats pull", "syncest_stats_pull", function()
        local Stats = require("syncest_syncstats")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        -- A manual pull must reconcile the complete remote history. Using the
        -- saved cursor here can permanently hide an older row that was missed
        -- before the cursor advanced. Automatic pulls remain incremental.
        local since = manual and 0 or (settings.stats_pull_cursor or 0)
        if since > 100000000000 then since = math.floor(since / 1000) end
        local pulled = false
        local message = nil
        local response_data = nil
        client:pullChanges({
            since = since,
            type = "stats",
            book = "",
            meta_hash = "",
        }, function(success, response, status)
            pulled = success == true
            response_data = response
            message = tostring(status or "")
        end)
        if not pulled then
            return { success = false, message = message }
        end
        local stat_books = response_data and response_data.statBooks or {}
        local stat_pages = response_data and response_data.statPages or {}
        Stats:applyRemote(stat_books, stat_pages)
        local newest = since
        for _, p in ipairs(stat_pages) do
            local u = tonumber(p.start_time) or 0
            if u > newest then newest = u end
        end
        return {
            success = true,
            stats_pull_cursor = newest,
            changed = newest > since,
            count = #stat_pages,
        }
    end, function(result)
        if result.changed then
            self.settings.stats_pull_cursor = result.stats_pull_cursor
            G_reader_settings:saveSetting("webdav_sync", self.settings)
        end
        if notify then
            if (tonumber(result.count) or 0) > 0 then
                self:_autoNotify("stats", "pulled")
            elseif manual and self:_notificationEnabled("stats") then
                UIManager:show(Notification:new{
                    text = _("No new reading statistics to pull."), timeout = 2,
                })
            end
        end
    end, failure_fn)
end

function Syncest:_backgroundPushVocab(notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    if self:_deferUntilProgressAndAnnotationsIdle("background vocab push", function()
            self:_backgroundPushVocab(notify)
        end) then return false end
    local failure_fn = notify and function() self:_autoFailureNotify("vocab") end or nil
    return self:_runBackgroundJSON("background vocab push", "syncest_vocab_push", function()
        local Vocab = require("syncest_syncvocab")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        local words = Vocab:getWords()
        if #words == 0 then
            return { success = true, empty = true }
        end
        local pushed = false
        local message = nil
        client:pushChanges({ vocab = words }, function(success, _response, status)
            pushed = success == true
            message = tostring(status or "")
        end)
        if not pushed then
            return { success = false, message = message }
        end
        return { success = true, vocab_last_pushed_at = os.time() }
    end, function(result)
        if not result.empty then
            self.settings.vocab_last_pushed_at = result.vocab_last_pushed_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            if notify then self:_autoNotify("vocab", "pushed") end
        end
    end, failure_fn)
end

function Syncest:_backgroundPullVocab(notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    if self:_deferUntilProgressAndAnnotationsIdle("background vocab pull", function()
            self:_backgroundPullVocab(notify)
        end) then return false end
    local failure_fn = notify and function() self:_autoFailureNotify("vocab") end or nil
    return self:_runBackgroundJSON("background vocab pull", "syncest_vocab_pull", function()
        local Vocab = require("syncest_syncvocab")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        local pulled = false
        local response_data = nil
        local message = nil
        client:pullChanges({ type = "vocab" }, function(success, response, status)
            pulled = success == true
            response_data = response
            message = tostring(status or "")
        end)
        if not pulled then
            return { success = false, message = message }
        end
        local words = response_data and response_data.words or {}
        local added = Vocab:applyWords(words)
        return {
            success = true,
            added = added,
            vocab_last_pulled_at = os.time(),
        }
    end, function(result)
        self.settings.vocab_last_pulled_at = result.vocab_last_pulled_at
        G_reader_settings:saveSetting("webdav_sync", self.settings)
        if notify and (tonumber(result.added) or 0) > 0 then
            self:_autoNotify("vocab", "pulled")
        end
    end, failure_fn)
end

function Syncest:_backgroundPushAnnotations(payload, notify, doc_path)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    if self:_deferUntilProgressIdle("background annotations push", function()
            self:_backgroundPushAnnotations(payload, notify, doc_path)
        end) then return false end
    local failure_fn = notify and function() self:_autoFailureNotify("annotations") end or nil
    return self:_runBackgroundJSON(
        "background annotations push",
        "syncest_annotations_push",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local pushed = false
            local message = nil
            client:pushChanges(payload, function(success, _response, status)
                pushed = success == true
                message = tostring(status or "")
            end)
            if not pushed then
                return { success = false, message = message }
            end
            return {
                success = true,
                last_notes_sync_at = os.time() * 1000,
                last_pushed_at_notes = os.time(),
            }
        end,
        function(result)
            if payload and payload.notes and payload.notes[1] then
                self:_queueSyncMarker(payload.notes[1])
            end
            self.settings.last_notes_sync_at = result.last_notes_sync_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            local doc_settings = self.ui and self.ui.doc_settings
            if doc_path then
                local DocSettings = require("docsettings")
                local ok, opened = pcall(DocSettings.open, DocSettings, doc_path)
                if ok then doc_settings = opened end
            end
            if doc_settings then
                local synced = doc_settings:readSetting("webdav_sync") or {}
                synced.last_pushed_at_notes = result.last_pushed_at_notes
                synced.deleted_notes = nil
                doc_settings:saveSetting("webdav_sync", synced)
                doc_settings:flush()
            end
            if notify then self:_autoNotify("annotations", "pushed") end
        end,
        failure_fn)
end

function Syncest:_backgroundPullAnnotations(book_hash, full_sync, notify, doc_path)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" or not book_hash then return false end
    if self:_deferUntilProgressIdle("background annotations pull", function()
            self:_backgroundPullAnnotations(book_hash, full_sync, notify, doc_path)
        end) then return false end
    local since = full_sync and 0 or (self.settings.last_notes_sync_at or 0)
    local failure_fn = notify and function() self:_autoFailureNotify("annotations") end or nil
    return self:_runBackgroundJSON(
        "background annotations pull",
        "syncest_annotations_pull",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local pulled = false
            local response_data = nil
            local message = nil
            client:pullChanges({
                since = since,
                type = "notes",
                book = book_hash,
            }, function(success, response, status)
                pulled = success == true
                response_data = response
                message = tostring(status or "")
            end)
            if not pulled then
                return { success = false, message = message }
            end
            return {
                success = true,
                notes = response_data and response_data.notes or {},
            }
        end,
        function(result)
            if not doc_path and self:getBookIdentifiers() ~= book_hash then
                logger.warn("Syncest background annotations pull: current book changed, skipping apply")
                return
            end
            if self.ui and self.ui.document and self.ui.document.info
                    and self.ui.document.info.has_pages then
                logger.warn("Syncest background annotations pull: paged document, skipping apply")
                return
            end
            local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
            if doc_path then
                self:_applyFileAnnotations(doc_path, book_hash, result.notes, notify_fn)
            else
                SyncAnnotations:applyPulledNotes(
                    self.ui, self.settings, result.notes, book_hash, self.dialog, notify_fn)
            end
        end,
        failure_fn)
end

function Syncest:pushBookConfigAsync(notify, history_source, history_reason)
    logger.info("Syncest pushBookConfigAsync: notify=" .. tostring(notify))
    local config = SyncConfig:getCurrentBookConfig(self.ui)
    if not config then return end
    local payload = self:_addProgressReadingStatus({
        books = {},
        notes = {},
        configs = { config },
    })
    add_progress_history(
        payload, self.settings, history_source, history_reason, self.ui)
    if notify == true and history_source == "manual" then
        notify = "manual"
    end
    local already_pushed = self:_progressPayloadAlreadyPushed(payload)
    if NetworkMgr:willRerunWhenOnline(
            function()
                self:pushBookConfigAsync(notify, history_source, history_reason)
            end) then
        return
    end
    local launched = self:_backgroundPushProgress(payload, notify)
    if launched then
        self.last_sync_timestamp = os.time()
    end
    if launched and not already_pushed then
        self:_mirrorProgressToKOSync()
    end
end

function Syncest:pullBookConfigAsync(notify, force_apply)
    logger.info("Syncest pullBookConfigAsync: notify=" .. tostring(notify)
        .. " force_apply=" .. tostring(force_apply))
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookConfigAsync(notify, force_apply) end) then
        return
    end
    self._suppress_auto_push_config_until =
        os.time() + AUTO_PUSH_SUPPRESS_AFTER_PULL
    logger.info("Syncest pullBookConfigAsync: suppressing auto push until "
        .. tostring(self._suppress_auto_push_config_until))
    self:_backgroundPullProgress(book_hash, notify, force_apply)
end

Syncest.default_settings = {
    sync_server              = nil,
    auto_sync                = false,
    -- Granular auto sync flags (all default on; only meaningful when auto_sync=true)
    auto_push_progress       = true,
    auto_push_progress_close = true,
    auto_push_progress_chapter = false,
    push_every_x_pages       = true,
    push_page_interval       = 1,
    auto_pull_progress       = true,
    auto_pull_progress_resume = false,
    auto_push_annotations    = true,
    auto_push_annotations_close = true,
    auto_pull_annotations    = true,
    auto_push_stats          = true,
    auto_pull_stats          = true,
    auto_pull_stats_book_open = false,
    auto_sync_catalog        = true,
    check_updates            = true,
    connection_notifications = true,
    progress_notifications   = true,
    annotation_notifications = true,
    stats_notifications      = true,
    vocab_notifications      = true,
    books_notifications      = true,
    mirror_to_kosync         = false,
    progress_history_filter  = "both",
    progress_history_count   = 25,
    progress_history_retention = PROGRESS_HISTORY_RETENTION,
    user_id      = nil,
    user_name    = nil,
    last_sync_at = nil,
}

-- ── Lifecycle ──────────────────────────────────────────────────────

function Syncest:_autoNotifyCompactAt()
    local Screen = Device and Device.screen
    local width = Screen and Screen.getWidth and Screen:getWidth() or 0
    if width > 0 and width < 700 then
        return 2
    elseif width >= 1000 then
        return 4
    end
    return 3
end

function Syncest:_notificationEnabled(kind)
    local keys = {
        progress = "progress_notifications",
        annotations = "annotation_notifications",
        stats = "stats_notifications",
        vocab = "vocab_notifications",
        books = "books_notifications",
        connection = "connection_notifications",
    }
    local key = keys[kind]
    return not key or self.settings[key] ~= false
end

function Syncest:_flushAutoNotify()
    if not self._notify_labels then
        self._notify_task = nil
        self._notify_batching = nil
        self._notify_action_filter = nil
        self._notify_batch_flush_delay = nil
        return
    end
    local order = { "progress", "annotations", "stats", "vocab" }
    local label_names = {
        progress = _("progress"),
        annotations = _("annotations"),
        stats = _("stats"),
        vocab = _("vocab"),
    }
    local parts = {}
    local actions = {}
    local shared_action
    local mixed_actions = false
    for _, k in ipairs(order) do
        local action = self._notify_labels[k]
        if action and self:_notificationEnabled(k) then
            parts[#parts + 1] = label_names[k] or k
            actions[#actions + 1] = action
            if not shared_action then
                shared_action = action
            elseif shared_action ~= action then
                mixed_actions = true
            end
        end
    end
    if #parts > 0 then
        local text
        local compact_at = self:_autoNotifyCompactAt()
        if #parts >= compact_at and not mixed_actions and shared_action == "pushed" then
            text = T(_("Syncest pushed %1 items"), tostring(#parts))
        elseif #parts >= compact_at and not mixed_actions and shared_action == "pulled" then
            text = T(_("Syncest pulled %1 items"), tostring(#parts))
        elseif #parts >= compact_at and not mixed_actions then
            text = T(_("Syncest synced %1 items"), tostring(#parts))
        elseif not mixed_actions and shared_action == "pushed" then
            text = _("Pushed: ") .. table.concat(parts, ", ")
        elseif not mixed_actions and shared_action == "pulled" then
            text = _("Pulled: ") .. table.concat(parts, ", ")
        else
            local mixed = {}
            for i, label in ipairs(parts) do
                mixed[#mixed + 1] = label .. " " .. tostring(actions[i])
            end
            text = table.concat(mixed, ", ")
        end
        UIManager:show(Notification:new{
            text = text,
            timeout = 2,
        })
    end
    self._notify_labels = nil
    self._notify_task = nil
    self._notify_batching = nil
    self._notify_action_filter = nil
    self._notify_batch_flush_delay = nil
end

function Syncest:_beginAutoNotifyBatch(timeout, reset, action_filter, flush_delay)
    if self._notify_task then UIManager:unschedule(self._notify_task) end
    if reset then self._notify_labels = nil end
    self._notify_batching = true
    self._notify_action_filter = action_filter
    self._notify_batch_flush_delay = flush_delay
    self._notify_task = function()
        self:_flushAutoNotify()
    end
    UIManager:scheduleIn(timeout or 10, self._notify_task)
end

function Syncest:_autoNotify(label, action, delay)
    if not self:_notificationEnabled(label) then return end
    if self._notify_action_filter then
        if type(self._notify_action_filter) == "table" then
            local allowed = false
            for _, value in ipairs(self._notify_action_filter) do
                if action == value then
                    allowed = true
                    break
                end
            end
            if not allowed then return end
        elseif action ~= self._notify_action_filter then
            return
        end
    end
    if not self._notify_labels then self._notify_labels = {} end
    self._notify_labels[label] = action
    if self._notify_batching then
        if not self._notify_task then
            self._notify_task = function()
                self:_flushAutoNotify()
            end
            UIManager:scheduleIn(self._notify_batch_flush_delay or delay or 1.5,
                self._notify_task)
        end
        return
    end
    if self._notify_task then UIManager:unschedule(self._notify_task) end
    self._notify_task = function()
        self:_flushAutoNotify()
    end
    UIManager:scheduleIn(delay or 0.5, self._notify_task)
end

function Syncest:_showConnectionNotification(kind)
    if not self:_notificationEnabled("connection") then return end
    local now = os.time()
    if self._last_connection_notification == kind
        and self._last_connection_notification_at
        and now - self._last_connection_notification_at < 5 then
        return
    end
    self._last_connection_notification = kind
    self._last_connection_notification_at = now
    UIManager:show(Notification:new{
        text = kind == "connected"
            and _("Syncest connected")
            or _("Syncest disconnected"),
        timeout = 2,
    })
end

function Syncest:_showBooksSyncNotification(text, _timeout)
    if not self:_notificationEnabled("books") then return end
    if self._books_sync_notification then
        pcall(function() UIManager:close(self._books_sync_notification) end)
        self._books_sync_notification = nil
    end
    local notification = Notification:new{
        text = text,
        timeout = 2,
    }
    self._books_sync_notification = notification
    UIManager:show(notification)
end

function Syncest:_currentDocumentPath()
    local path = self.ui and self.ui.doc_settings
        and self.ui.doc_settings:readSetting("doc_path") or nil
    return path ~= "" and path or nil
end

function Syncest:_mirrorProgressToKOSync()
    if not self.settings.mirror_to_kosync then return false end
    local kosync = self.ui and self.ui.kosync
    if not kosync and self.ui then
        for _, child in ipairs(self.ui) do
            if type(child) == "table"
                    and type(child.updateProgress) == "function"
                    and (child.name == "kosync" or child.title == "KOSync") then
                kosync = child
                break
            end
        end
    end
    if not kosync or type(kosync.updateProgress) ~= "function" then
        logger.warn("Syncest KOSync mirror: KOSync module not available")
        return false
    end
    local ok, err = pcall(function()
        kosync:updateProgress(true, false)
    end)
    if not ok then
        logger.warn("Syncest KOSync mirror failed: " .. tostring(err))
        return false
    end
    logger.info("Syncest KOSync mirror: progress push requested")
    return true
end

function Syncest:_autoFailureNotify(_label)
    if self._syncest_connection_state == false then return end
    self._syncest_connection_state = false
    if self._failure_notify_task then
        UIManager:unschedule(self._failure_notify_task)
    end
    self._failure_notify_task = function()
        if self._syncest_connection_state == false then
            self:_showConnectionNotification("disconnected")
        end
        self._failure_notify_task = nil
    end
    UIManager:scheduleIn(0.2, self._failure_notify_task)
end

function Syncest:_cancelAutoPullTasks()
    local tasks = {
        "_auto_pull_progress_task",
        "_auto_pull_annotations_task",
        "_auto_pull_book_stats_task",
        "_auto_pull_stats_task",
        "_auto_pull_vocab_task",
    }
    for _, name in ipairs(tasks) do
        if self[name] then
            UIManager:unschedule(self[name])
            self[name] = nil
        end
    end
end

function Syncest:_scheduleStartupGlobalPulls()
    if not self.settings.auto_sync or WebDavAuth:needsSetup(self.settings) then
        return
    end
    if self.settings.auto_pull_stats ~= false then
        self._auto_pull_stats_task = function()
            self._auto_pull_stats_task = nil
            self:_runSafely("startup pull stats", function()
                self:pullBookStats(false, true)
            end)
        end
        UIManager:scheduleIn(12, self._auto_pull_stats_task)
    end
    if self.settings.auto_pull_vocab ~= false then
        self._auto_pull_vocab_task = function()
            self._auto_pull_vocab_task = nil
            self:_runSafely("startup pull vocab", function()
                self:pullVocab(false, true)
            end)
        end
        UIManager:scheduleIn(18, self._auto_pull_vocab_task)
    end
end

function Syncest:_syncConnectionRestored()
    if self._failure_notify_task then
        UIManager:unschedule(self._failure_notify_task)
        self._failure_notify_task = nil
    end
    if self._syncest_connection_state ~= false then
        self._syncest_connection_state = true
        return
    end
    self._syncest_connection_state = true
    self:_showConnectionNotification("connected")
end

local function annotation_items_from_data(data)
    local items = {}
    for _, item in ipairs(data and data.annotations or {}) do
        if item.drawer or type(item.page) == "string" then
            items[#items + 1] = item
        end
    end
    for _, page_items in pairs(data and data.highlight or {}) do
        if type(page_items) == "table" then
            for _, item in ipairs(page_items) do
                if item.drawer then items[#items + 1] = item end
            end
        end
    end
    return items
end

local function annotation_item_key(item)
    if item.id then return "id:" .. tostring(item.id) end
    if item.pos0 then
        return "pos:" .. tostring(item.pos0) .. "|" .. tostring(item.pos1 or "")
    end
    return "dt:" .. tostring(item.datetime or "") .. "|"
        .. tostring(item.text or "") .. "|" .. tostring(item.page or "")
end

local function annotation_snapshot(data)
    local snapshot = {}
    for _, item in ipairs(annotation_items_from_data(data)) do
        snapshot[annotation_item_key(item)] = {
            id = item.id, drawer = item.drawer, pos0 = item.pos0,
            pos1 = item.pos1, page = item.page, pageno = item.pageno,
            text = item.text, note = item.note, color = item.color,
            datetime = item.datetime, datetime_updated = item.datetime_updated,
        }
    end
    return snapshot
end

local function annotation_snapshot_changed(before, after)
    for key, item in pairs(before) do
        local current = after[key]
        if not current then return true end
        if tostring(item.note or "") ~= tostring(current.note or "")
                or tostring(item.drawer or "") ~= tostring(current.drawer or "")
                or tostring(item.color or "") ~= tostring(current.color or "") then
            return true
        end
    end
    for key in pairs(after) do
        if not before[key] then return true end
    end
    return false
end

function Syncest:_installFileAnnotationWatcher()
    local DocSettings = require("docsettings")
    if DocSettings._syncest_original_open then return end
    local plugin = self
    local function has_live_reader()
        local ReaderUI = require("apps/reader/readerui")
        return ReaderUI and ReaderUI.instance and ReaderUI.instance.document
    end
    DocSettings._syncest_original_open = DocSettings.open
    DocSettings.open = function(class, file, ...)
        local settings = DocSettings._syncest_original_open(class, file, ...)
        if not settings then return settings end
        if settings._syncest_flush_wrapped then
            settings._syncest_annotation_file = file
            if not has_live_reader() then
                settings._syncest_annotation_snapshot =
                    annotation_snapshot(settings.data)
            end
            return settings
        end
        settings._syncest_flush_wrapped = true
        settings._syncest_annotation_file = file
        settings._syncest_annotation_snapshot = annotation_snapshot(settings.data)
        local original_flush = settings.flush
        settings.flush = function(instance, ...)
            local before = instance._syncest_annotation_snapshot or {}
            local result = original_flush(instance, ...)
            if has_live_reader() then
                -- Reader-side annotation changes use AnnotationsModified.
                -- Avoid an O(annotation count) snapshot on every document save.
                instance._syncest_annotation_snapshot = nil
                return result
            end
            local after = annotation_snapshot(instance.data)
            instance._syncest_annotation_snapshot = after
            if not plugin.ui.document
                    and annotation_snapshot_changed(before, after) then
                local deleted = {}
                for key, item in pairs(before) do
                    if not after[key] then deleted[#deleted + 1] = item end
                end
                logger.info("Syncest file annotation watcher: changed file="
                    .. tostring(instance._syncest_annotation_file)
                    .. " deleted=" .. tostring(#deleted))
                if #deleted > 0 then
                    if not instance:readSetting("partial_md5_checksum") then
                        local ok, hash = pcall(require("util").partialMD5,
                            instance._syncest_annotation_file)
                        if ok and hash then
                            instance:saveSetting("partial_md5_checksum", hash)
                        end
                    end
                    for _, item in ipairs(deleted) do
                        SyncAnnotations:recordDeletion(instance, item)
                    end
                end
                if plugin.settings.auto_sync
                        and plugin.settings.auto_push_annotations ~= false
                        and not WebDavAuth:needsSetup(plugin.settings) then
                    plugin:pushFileAnnotations(
                        instance._syncest_annotation_file, true)
                else
                    logger.info("Syncest file annotation watcher: auto-push disabled")
                end
            end
            return result
        end
        return settings
    end
end

-- KOReader's stock bookmark viewer emits AnnotationsModified when it removes
-- highlights and notes, but not when it removes a plain dog-ear bookmark.
-- Bridge that missing event into Syncest's existing deletion/tombstone path.
function Syncest:_installReaderBookmarkDeletionWatcher()
    local ReaderBookmark = require("apps/reader/modules/readerbookmark")
    ReaderBookmark._syncest_plugin = self
    if ReaderBookmark._syncest_original_remove_item_by_index then return end

    ReaderBookmark._syncest_original_remove_item_by_index =
        ReaderBookmark.removeItemByIndex
    ReaderBookmark.removeItemByIndex = function(bookmark, index, ...)
        local item = bookmark.ui and bookmark.ui.annotation
            and bookmark.ui.annotation.annotations
            and bookmark.ui.annotation.annotations[index]
        local result = ReaderBookmark._syncest_original_remove_item_by_index(
            bookmark, index, ...)
        if item and not item.drawer then
            local plugin = ReaderBookmark._syncest_plugin
            if plugin and plugin.ui == bookmark.ui then
                plugin:onAnnotationsModified({
                    item,
                    index_modified = -index,
                })
            end
        end
        return result
    end
end

function Syncest:init()
    self.last_sync_timestamp = 0
    self._last_pushed_page = nil
    self._last_observed_page = nil
    self.settings = G_reader_settings:readSetting("webdav_sync", self.default_settings)
    if self.settings.pending_pushes ~= nil
            or self.settings.auto_push_on_suspend ~= nil
            or self.settings.auto_push_progress_suspend ~= nil
            or self.settings.auto_push_annotations_suspend ~= nil
            or self.settings.auto_push_stats_suspend ~= nil then
        self.settings.pending_pushes = nil
        self.settings.auto_push_on_suspend = nil
        self.settings.auto_push_progress_suspend = nil
        self.settings.auto_push_annotations_suspend = nil
        self.settings.auto_push_stats_suspend = nil
        G_reader_settings:saveSetting("webdav_sync", self.settings)
        G_reader_settings:flush()
    end
    local progress_history_settings_changed = false
    if self.settings.progress_history_retention ~= PROGRESS_HISTORY_RETENTION then
        self.settings.progress_history_retention = PROGRESS_HISTORY_RETENTION
        progress_history_settings_changed = true
    end
    if (tonumber(self.settings.progress_history_count) or 25) > 25 then
        self.settings.progress_history_count = 25
        progress_history_settings_changed = true
    end
    if not self.settings.progress_history_device_id then
        progress_history_device_id(self.settings)
        progress_history_settings_changed = true
    end
    if progress_history_settings_changed then
        G_reader_settings:saveSetting("webdav_sync", self.settings)
    end
    if not self.settings.progress_push_mode_migrated then
        if self.settings.auto_push_progress ~= false then
            self.settings.push_every_x_pages = true
            self.settings.push_page_interval = 1
        end
        self.settings.progress_push_mode_migrated = true
        G_reader_settings:saveSetting("webdav_sync", self.settings)
    elseif self.settings.push_page_interval == nil then
        self.settings.push_page_interval = 1
        G_reader_settings:saveSetting("webdav_sync", self.settings)
    end
    if SYNC_PLUGIN_INERT_DIAGNOSTIC then
        logger.warn("Syncest init: inert diagnostic mode enabled; no menus, hooks, or WebDAV")
        return
    end

    -- Migrate pre-SyncService settings (webdav_address/username/password → sync_server)
    if not self.settings.sync_server and self.settings.webdav_address then
        self.settings.sync_server = {
            address  = self.settings.webdav_address,
            username = self.settings.webdav_username or "",
            password = self.settings.webdav_password or "",
            url      = self.settings.webdav_base_path or "",
            type     = "webdav",
            name     = self.settings.user_name or "",
        }
        self.settings.webdav_address   = nil
        self.settings.webdav_username  = nil
        self.settings.webdav_password  = nil
        self.settings.webdav_base_path = nil
        G_reader_settings:saveSetting("webdav_sync", self.settings)
    end

    self.ui.menu:registerToMainMenu(self)
    self:_installFileAnnotationWatcher()
    self:_installReaderBookmarkDeletionWatcher()
    self:onDispatcherRegisterActions()
    self:registerFileDialogButton()
    self:backgroundUpdateCheck()
    self:_scheduleStartupGlobalPulls()
end

function Syncest:onDispatcherRegisterActions()
    Dispatcher:registerAction("syncest_open_library",
        { category="none", event="SyncestOpenLibrary",
          title=_("Syncest: Open Syncest Library"), general=true })
    Dispatcher:registerAction("syncest_push_books",
        { category="none", event="SyncestPushBooks",
          title=_("Syncest: Push Syncest book library"), general=true })
    Dispatcher:registerAction("syncest_pull_books",
        { category="none", event="SyncestPullBooks",
          title=_("Syncest: Pull Syncest book library"), general=true })
    Dispatcher:registerAction("syncest_push_stats",
        { category="none", event="SyncestPushStats",
          title=_("Syncest: Push reading statistics to Syncest"), general=true })
    Dispatcher:registerAction("syncest_pull_stats",
        { category="none", event="SyncestPullStats",
          title=_("Syncest: Pull reading statistics from Syncest"), general=true })
    Dispatcher:registerAction("syncest_push_vocab",
        { category="none", event="SyncestPushVocab",
          title=_("Syncest: Push vocabulary to Syncest"), general=true })
    Dispatcher:registerAction("syncest_pull_vocab",
        { category="none", event="SyncestPullVocab",
          title=_("Syncest: Pull vocabulary from Syncest"), general=true })
    Dispatcher:registerAction("syncest_push_all_annotations",
        { category="none", event="SyncestPushAllAnnotations",
          title=_("Syncest: Push all annotations to Syncest"), general=true })
    Dispatcher:registerAction("syncest_pull_all_annotations",
        { category="none", event="SyncestPullAllAnnotations",
          title=_("Syncest: Pull all annotations from Syncest"), general=true })
    Dispatcher:registerAction("syncest_push_all",
        { category="none", event="SyncestPushAll",
          title=_("Syncest: Push Syncest progress, annotations, stats, and vocab"), general=true })
    Dispatcher:registerAction("syncest_pull_all",
        { category="none", event="SyncestPullAll",
          title=_("Syncest: Pull Syncest progress, annotations, stats, and vocab"), general=true })
end

function Syncest:onDispatcherRegisterReaderActions()
    Dispatcher:registerAction("syncest_set_autosync",
        { category="string", event="SyncestToggleAutoSync",
          title=_("Syncest: Set auto progress sync"), reader=true,
          args={true, false}, toggle={_("on"), _("off")} })
    Dispatcher:registerAction("syncest_toggle_autosync",
        { category="none", event="SyncestToggleAutoSync",
          title=_("Syncest: Toggle auto Syncest sync"), reader=true })
    Dispatcher:registerAction("syncest_open_progress_history",
        { category="none", event="SyncestOpenProgressHistory",
          title=_("Syncest: Open progress history"), reader=true })
    Dispatcher:registerAction("syncest_push_progress",
        { category="none", event="SyncestPushProgress",
          title=_("Syncest: Push progress to Syncest"), reader=true })
    Dispatcher:registerAction("syncest_pull_progress",
        { category="none", event="SyncestPullProgress",
          title=_("Syncest: Pull progress from Syncest"), reader=true, separator=true })
    Dispatcher:registerAction("syncest_push_annotations",
        { category="none", event="SyncestPushAnnotations",
          title=_("Syncest: Push annotations to Syncest"), reader=true })
    Dispatcher:registerAction("syncest_pull_annotations",
        { category="none", event="SyncestPullAnnotations",
          title=_("Syncest: Pull annotations from Syncest"), reader=true, separator=true })
end

function Syncest:onReaderReady()
    if self.x_page_push_task then
        UIManager:unschedule(self.x_page_push_task)
        self.x_page_push_task = nil
    end
    self.x_page_push_notify = nil
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        if STARTUP_AUTO_PULL_PROGRESS_ENABLED
                and self.settings.auto_pull_progress ~= false then
            self:_runSafely("auto pull progress", function()
                local book_hash = self:getBookIdentifiers()
                if book_hash then
                    self:_backgroundPullProgress(
                        book_hash, true, false, nil, { startup_wait = true })
                end
            end)
        else
            logger.warn("Syncest onReaderReady: startup auto progress pull disabled")
        end
        if self.settings.auto_pull_annotations ~= false then
            self._auto_pull_annotations_task = function()
                self._auto_pull_annotations_task = nil
                self:_runSafely("auto pull annotations", function()
                    self:pullBookNotes(false, false, true)
                end)
            end
            UIManager:scheduleIn(5, self._auto_pull_annotations_task)
        end
        if self.settings.auto_pull_stats_book_open == true then
            self._auto_pull_book_stats_task = function()
                self._auto_pull_book_stats_task = nil
                self:_runSafely("book open pull stats", function()
                    self:pullBookStats(false, true)
                end)
            end
            UIManager:scheduleIn(8, self._auto_pull_book_stats_task)
        end
    end
    self._last_pushed_page = nil
    self._last_observed_page = nil
    self:onDispatcherRegisterReaderActions()
end

-- ── File dialog "Add to Syncest" button ───────────────────────────

local _readest_format_for_ext = nil
local function readest_format_for_ext(ext)
    if not _readest_format_for_ext then
        _readest_format_for_ext = {}
        local EXTS = require("syncest_lib.exts")
        for fmt, e in pairs(EXTS) do _readest_format_for_ext[e] = fmt end
    end
    return ext and _readest_format_for_ext[ext:lower()]
end

local zen_wrapped_file_choosers = setmetatable({}, { __mode = "k" })

function Syncest:registerZenFileDialogSubmenu(file_manager)
    if not rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM") then return end
    local file_chooser = file_manager and file_manager.file_chooser
    if not file_chooser or zen_wrapped_file_choosers[file_chooser]
            == file_chooser.showFileDialog then
        return
    end

    local plugin = self
    local original_showFileDialog = file_chooser.showFileDialog
    if type(original_showFileDialog) ~= "function" then return end

    local function wrapped_showFileDialog(self_fc, item, ...)
        if type(item) == "table" and item.is_file and item.path then
            local ext = item.path:match("%.([^./\\]+)$")
            if readest_format_for_ext(ext) then
                local extra = type(item._zen_extra_buttons) == "table"
                    and item._zen_extra_buttons or {}
                for i = #extra, 1, -1 do
                    if extra[i]._syncest_submenu_row then table.remove(extra, i) end
                end

                local row = {{
                    text = "\u{F04E6}  " .. _("Syncest") .. "  \u{25B8}",
                    align = "left",
                    callback = function()
                        if self_fc.file_dialog then
                            UIManager:close(self_fc.file_dialog)
                        end
                        UIManager:nextTick(function()
                            local ButtonDialog = require("ui/widget/buttondialog")
                            local submenu
                            local enabled = not WebDavAuth:needsSetup(plugin.settings)
                            local function action(icon, label, callback)
                                return {{
                                    text = icon .. "  " .. label,
                                    align = "left",
                                    enabled = enabled,
                                    callback = function()
                                        UIManager:close(submenu)
                                        callback()
                                    end,
                                }}
                            end
                            submenu = ButtonDialog:new{
                                title = _("Syncest"),
                                title_align = "center",
                                buttons = {
                                    action("\u{F067}", _("Add to library"), function()
                                        plugin:addToLibrary(item.path)
                                    end),
                                    action("\u{F0CE2}", _("Push progress"), function()
                                        plugin:pushFileProgress(item.path, true)
                                    end),
                                    action("\u{F0CDC}", _("Pull progress"), function()
                                        plugin:pullFileProgress(item.path, true)
                                    end),
                                    action("\u{F0CE2}", _("Push annotations"), function()
                                        plugin:pushFileAnnotations(item.path, true)
                                    end),
                                    action("\u{F0CDC}", _("Pull annotations"), function()
                                        plugin:pullFileAnnotations(item.path, true)
                                    end),
                                },
                            }
                            UIManager:show(submenu)
                        end)
                    end,
                }}
                row._syncest_submenu_row = true
                table.insert(extra, row)
                item._zen_extra_buttons = extra
            end
        end
        return original_showFileDialog(self_fc, item, ...)
    end

    file_chooser.showFileDialog = wrapped_showFileDialog
    zen_wrapped_file_choosers[file_chooser] = wrapped_showFileDialog
end

function Syncest:registerFileDialogButton()
    local plugin = self
    UIManager:scheduleIn(0, function()
        local ok_FM, FileManager = pcall(require, "apps/filemanager/filemanager")
        if not ok_FM or not FileManager.instance then return end
        FileManager.instance:addFileDialogButtons("syncest_add_to_library",
            function(file, is_file, _book_props)
                if not is_file then return nil end
                local ext = file:match("%.([^./\\]+)$")
                if not readest_format_for_ext(ext) then return nil end
                return {{
                    text = _("Add to library"),
                    enabled = not WebDavAuth:needsSetup(plugin.settings),
                    callback = function()
                        local fc = FileManager.instance and FileManager.instance.file_chooser
                        local dlg = fc and fc.file_dialog
                        if dlg then UIManager:close(dlg) end
                        plugin:addToLibrary(file)
                    end,
                }, {
                    text = _("Push progress"),
                    enabled = not WebDavAuth:needsSetup(plugin.settings),
                    callback = function()
                        plugin:pushFileProgress(file, true)
                    end,
                }, {
                    text = _("Pull progress"),
                    enabled = not WebDavAuth:needsSetup(plugin.settings),
                    callback = function()
                        plugin:pullFileProgress(file, true)
                    end,
                }, {
                    text = _("Push annotations"),
                    enabled = not WebDavAuth:needsSetup(plugin.settings),
                    callback = function()
                        plugin:pushFileAnnotations(file, true)
                    end,
                }, {
                    text = _("Pull annotations"),
                    enabled = not WebDavAuth:needsSetup(plugin.settings),
                    callback = function()
                        plugin:pullFileAnnotations(file, true)
                    end,
                }}
            end)
        plugin:registerZenFileDialogSubmenu(FileManager.instance)
    end)
end

function Syncest:onZenUIReady()
    local plugin = self
    UIManager:scheduleIn(0, function()
        local ok_FM, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok_FM then
            plugin:registerZenFileDialogSubmenu(FileManager.instance)
        end
    end)
end

local function open_file_annotation_ui(file)
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, file)
    if not ok or not doc_settings then return nil end
    local annotations = doc_settings:readSetting("annotations") or {}
    local annotation = { annotations = annotations }
    function annotation:addItem(item)
        self.annotations[#self.annotations + 1] = item
        return #self.annotations
    end
    return {
        doc_settings = doc_settings,
        annotation = annotation,
        document = {
            info = { has_pages = false },
            getPageFromXPointer = function(_, _xp) return nil end,
        },
        handleEvent = function() end,
    }
end

local function ensure_file_book_hash(file_ui, file)
    local book_hash = SyncConfig:getDocumentIdentifier(file_ui)
    if book_hash then return book_hash end
    local ok, hash = pcall(require("util").partialMD5, file)
    if not ok or not hash then
        logger.warn("Syncest file annotations: could not hash " .. tostring(file))
        return nil
    end
    file_ui.doc_settings:saveSetting("partial_md5_checksum", hash)
    file_ui.doc_settings:flush()
    logger.info("Syncest file annotations: stored book hash for " .. tostring(file))
    return hash
end

local function file_progress_config(file_ui, book_hash)
    local doc = file_ui.doc_settings
    local xpointer = doc:readSetting("last_xpointer") or ""
    local current_page = tonumber(doc:readSetting("last_page"))
    local page_count = tonumber(doc:readSetting("doc_pages"))
    local percent = tonumber(doc:readSetting("percent_finished"))

    if not current_page and (not xpointer or xpointer == "") then return nil end
    local config = {
        bookHash = book_hash,
        progress = current_page and { current_page, page_count or 0 } or "",
        xpointer = xpointer,
        currentPage = current_page,
        pageCount = page_count,
        progressPercent = percent,
        updatedAt = os.time() * 1000,
        bookMetadata = SyncConfig:getMetadataHashInfo(file_ui),
    }
    return config
end

function Syncest:pushFileProgress(file, notify)
    logger.info("Syncest pushFileProgress: file=" .. tostring(file))
    if WebDavAuth:needsSetup(self.settings) then return false end
    local file_ui = open_file_annotation_ui(file)
    if not file_ui then return false end
    local book_hash = ensure_file_book_hash(file_ui, file)
    if not book_hash then return false end
    local config = file_progress_config(file_ui, book_hash)
    if not config then
        if notify then
            UIManager:show(InfoMessage:new{
                text = _("No saved reading progress found for this book."), timeout = 3,
            })
        end
        return false
    end
    local payload = self:_addProgressReadingStatus({
        books = {}, notes = {}, configs = { config },
    }, book_hash)
    return self:_backgroundPushProgress(payload, notify)
end

function Syncest:_applyFileProgress(file, config)
    if not config then return false end
    local file_ui = open_file_annotation_ui(file)
    if not file_ui then return false end
    local doc = file_ui.doc_settings
    local progress = config.progress
    local page = tonumber(config.currentPage)
        or (type(progress) == "table" and tonumber(progress[1]))
    local page_count = tonumber(config.pageCount)
        or (type(progress) == "table" and tonumber(progress[2]))
    local percent = tonumber(config.progressPercent)
    if not percent and page and page_count and page_count > 0 then
        percent = page / page_count
    end
    if config.xpointer and config.xpointer ~= "" then
        doc:saveSetting("last_xpointer", config.xpointer)
    elseif page then
        doc:saveSetting("last_page", page)
    else
        return false
    end
    if percent then doc:saveSetting("percent_finished", percent) end
    local sync = doc:readSetting("webdav_sync") or {}
    sync.last_synced_at_config = os.time()
    doc:saveSetting("webdav_sync", sync)
    doc:flush()
    return true
end

function Syncest:pullFileProgress(file, notify)
    logger.info("Syncest pullFileProgress: file=" .. tostring(file))
    if WebDavAuth:needsSetup(self.settings) then return false end
    local file_ui = open_file_annotation_ui(file)
    if not file_ui then return false end
    local book_hash = ensure_file_book_hash(file_ui, file)
    if not book_hash then return false end
    return self:_backgroundPullProgress(book_hash, notify, true, file)
end

function Syncest:_fileAnnotationPayload(file, deleted_item)
    local file_ui = open_file_annotation_ui(file)
    if not file_ui then
        logger.warn("Syncest file annotations: could not open settings for "
            .. tostring(file))
        return nil
    end
    local book_hash = ensure_file_book_hash(file_ui, file)
    if not book_hash then return nil end
    local notes = SyncAnnotations:getAnnotations(
        file_ui, self.settings, book_hash, true)
    local doc_sync = file_ui.doc_settings:readSetting("webdav_sync") or {}
    local seen = {}
    for _, note in ipairs(notes) do
        if note.id then seen[note.id .. ":" .. tostring(note.deletedAt or "")] = true end
    end
    for _, tombstone in ipairs(doc_sync.deleted_notes or {}) do
        tombstone.bookHash = book_hash
        local key = tombstone.id
            and (tombstone.id .. ":" .. tostring(tombstone.deletedAt or ""))
        if not key or not seen[key] then
            notes[#notes + 1] = tombstone
            if key then seen[key] = true end
        end
    end
    if deleted_item then
        local deleted_items = deleted_item[1] and deleted_item or { deleted_item }
        for _, item in ipairs(deleted_items) do
            local tombstone = SyncAnnotations:buildNoteDescriptor(item, book_hash)
            if tombstone then
                tombstone.deletedAt = os.time() * 1000
                local key = tombstone.id .. ":" .. tostring(tombstone.deletedAt)
                if not seen[key] then
                    notes[#notes + 1] = tombstone
                    seen[key] = true
                end
            end
        end
    end
    local meta = SyncConfig:getMetadataHashInfo(file_ui)
    for _, note in ipairs(notes) do note.bookMetadata = meta end
    return {
        books = {}, notes = notes, configs = {}, bookHash = book_hash,
    }, file_ui
end

function Syncest:pushFileAnnotations(file, notify, deleted_item)
    logger.info("Syncest pushFileAnnotations: file=" .. tostring(file)
        .. " deleted=" .. tostring(deleted_item ~= nil))
    if WebDavAuth:needsSetup(self.settings) then return false end
    local payload = self:_fileAnnotationPayload(file, deleted_item)
    if not payload then return false end
    if #payload.notes == 0 then
        logger.info("Syncest pushFileAnnotations: no annotations to push")
        if notify then
            UIManager:show(InfoMessage:new{
                text = _("No annotations found for this book."), timeout = 2,
            })
        end
        return false
    end
    logger.info("Syncest pushFileAnnotations: pushing "
        .. tostring(#payload.notes) .. " annotation(s)")
    return self:_backgroundPushAnnotations(payload, notify, file)
end

function Syncest:_applyFileAnnotations(file, book_hash, notes, notify_fn)
    local file_ui = open_file_annotation_ui(file)
    if not file_ui then return false end
    local applied = SyncAnnotations:applyPulledNotes(
        file_ui, self.settings, notes, book_hash, nil, notify_fn)
    if applied then
        file_ui.doc_settings:saveSetting(
            "annotations", file_ui.annotation.annotations)
        file_ui.doc_settings:flush()
    end
    return applied
end

function Syncest:pullFileAnnotations(file, notify)
    logger.info("Syncest pullFileAnnotations: file=" .. tostring(file))
    if WebDavAuth:needsSetup(self.settings) then return false end
    local file_ui = open_file_annotation_ui(file)
    if not file_ui then return false end
    local book_hash = ensure_file_book_hash(file_ui, file)
    if not book_hash then return false end
    return self:_backgroundPullAnnotations(book_hash, true, notify, file)
end

local function annotation_history_files()
    local ReadHistory = require("readhistory")
    local lfs = require("libs/libkoreader-lfs")
    local files, seen = {}, {}
    for _, entry in ipairs(ReadHistory.hist or {}) do
        local file = entry.file
        if file and not seen[file] and lfs.attributes(file, "mode") == "file" then
            seen[file] = true
            files[#files + 1] = file
        end
    end
    return files
end

function Syncest:pushAllFileAnnotations(notify)
    if WebDavAuth:needsSetup(self.settings) then return false end
    local jobs = {}
    for _, file in ipairs(annotation_history_files()) do
        local payload = self:_fileAnnotationPayload(file)
        if payload and #payload.notes > 0 then
            jobs[#jobs + 1] = { file = file, payload = payload }
        end
    end
    if #jobs == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found."), timeout = 2,
        })
        return false
    end
    local server = self.settings.sync_server
    return self:_runBackgroundJSON(
        "background all annotations push", "syncest_all_annotations_push",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local pushed = 0
            for _, job in ipairs(jobs) do
                local success = false
                client:pushChanges(job.payload, function(ok) success = ok == true end)
                if not success then
                    return { success = false,
                        message = "annotation push failed for " .. tostring(job.file) }
                end
                pushed = pushed + 1
            end
            return { success = true, pushed = pushed,
                last_notes_sync_at = os.time() * 1000 }
        end,
        function(result)
            self.settings.last_notes_sync_at = result.last_notes_sync_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            for _, job in ipairs(jobs) do
                local file_ui = open_file_annotation_ui(job.file)
                if file_ui then
                    local sync = file_ui.doc_settings:readSetting("webdav_sync") or {}
                    sync.deleted_notes = nil
                    sync.last_pushed_at_notes = os.time()
                    file_ui.doc_settings:saveSetting("webdav_sync", sync)
                    file_ui.doc_settings:flush()
                end
            end
            if notify then self:_autoNotify("annotations", "pushed") end
        end,
        notify and function() self:_autoFailureNotify("annotations") end or nil,
        BOOKS_SYNC_MAX_POLLS)
end

function Syncest:pullAllFileAnnotations(notify)
    if WebDavAuth:needsSetup(self.settings) then return false end
    local jobs = {}
    for _, file in ipairs(annotation_history_files()) do
        local file_ui = open_file_annotation_ui(file)
        if file_ui then
            local hash = ensure_file_book_hash(file_ui, file)
            if hash then jobs[#jobs + 1] = { file = file, book_hash = hash } end
        end
    end
    local server = self.settings.sync_server
    return self:_runBackgroundJSON(
        "background all annotations pull", "syncest_all_annotations_pull",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local pulled = {}
            for _, job in ipairs(jobs) do
                local success, notes = false, nil
                client:pullChanges({ since = 0, type = "notes", book = job.book_hash },
                    function(ok, response)
                        success = ok == true
                        notes = response and response.notes or {}
                    end)
                if not success then
                    return { success = false,
                        message = "annotation pull failed for " .. tostring(job.file) }
                end
                pulled[#pulled + 1] = {
                    file = job.file, book_hash = job.book_hash, notes = notes,
                }
            end
            return { success = true, books = pulled }
        end,
        function(result)
            local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
            for _, book in ipairs(result.books or {}) do
                self:_applyFileAnnotations(
                    book.file, book.book_hash, book.notes, notify_fn)
            end
        end,
        notify and function() self:_autoFailureNotify("annotations") end or nil,
        BOOKS_SYNC_MAX_POLLS)
end

function Syncest:addToLibrary(file)
    local lfs  = require("libs/libkoreader-lfs")
    local util = require("util")

    if WebDavAuth:needsSetup(self.settings) then
        UIManager:show(InfoMessage:new{
            text = _("Configure WebDAV sync first."), timeout = 3,
        })
        return
    end
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then
        UIManager:show(InfoMessage:new{ text = _("File not found."), timeout = 3 })
        return
    end
    local ext = file:match("%.([^./\\]+)$")
    local format = readest_format_for_ext(ext)
    if not format then
        UIManager:show(InfoMessage:new{ text = _("Unsupported book format."), timeout = 3 })
        return
    end

    local progress = InfoMessage:new{ text = _("Hashing book…") }
    UIManager:show(progress)
    UIManager:nextTick(function()
        local hash = util.partialMD5(file)
        UIManager:close(progress)
        if not hash then
            UIManager:show(InfoMessage:new{ text = _("Could not read file."), timeout = 3 })
            return
        end
        self:_addLocalRow(file, hash, format, attr.size)
    end)
end

function Syncest:_addLocalRow(file, hash, format, _size)
    local store = self:getLibraryStore()
    if not store then
        UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first."), timeout = 3 })
        return
    end
    local basename = file:match("([^/]+)$") or file
    local title = basename:gsub("%.[^.]+$", "")
    local now = math.floor(os.time() * 1000)

    local existing = store:_getRowRaw(hash)
    if existing and existing.deleted_at == nil then
        store:upsertBook({ hash = hash, title = existing.title or title,
            format = existing.format or format, file_path = file,
            local_present = 1, updated_at = now })
        local LibraryWidget = require("syncest_lib.librarywidget")
        if LibraryWidget._menu then LibraryWidget.refresh() end
        self:_pushSingleLibraryBook(store:_getRowRaw(hash))
        return
    end

    store:upsertBook({ hash = hash, title = title, format = format,
        file_path = file, local_present = 1, created_at = now,
        updated_at = now, _clear_fields = { "deleted_at" } })
    local LibraryWidget = require("syncest_lib.librarywidget")
    if LibraryWidget._menu then LibraryWidget.refresh() end
    self:_pushSingleLibraryBook(store:_getRowRaw(hash))
end

function Syncest:_pushSingleLibraryBook(row)
    if not row then return end

    local syncbooks = require("syncest_lib.syncbooks")
    local DataStorage = require("datastorage")
    local progress = InfoMessage:new{
        text = _("Uploading to Syncest Library…") .. " " .. (row.title or ""),
    }
    UIManager:show(progress)

    syncbooks.uploadBook(row, {
        settings = self.settings,
        covers_dir = DataStorage:getSettingsDir() .. "/syncest_covers",
    }, function(uploaded, upload_error, upload_status)
        if not uploaded then
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = _("Book upload failed: ")
                    .. tostring(upload_error or upload_status or _("unknown error")),
                timeout = 5,
            })
            return
        end

        local now = math.floor(os.time() * 1000)
        local store = self:getLibraryStore()
        if store then
            store:upsertBook({
                hash = row.hash,
                title = row.title,
                cloud_present = 1,
                uploaded_at = now,
                updated_at = now,
                _clear_fields = { "deleted_at" },
            })
        end
        row.cloud_present = 1
        row.uploaded_at = now
        row.updated_at = now
        row.deleted_at = nil

        syncbooks.pushBook(row, {
            client = WebDavAuth:getClient(self.settings),
            settings = self.settings,
        }, function(pushed, push_error)
            UIManager:close(progress)
            local LibraryWidget = require("syncest_lib.librarywidget")
            if LibraryWidget._menu then LibraryWidget.refresh() end
            if pushed then
                UIManager:show(InfoMessage:new{
                    text = _("Uploaded to Syncest Library: ") .. (row.title or ""),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Book uploaded, but library update failed: ")
                        .. tostring(push_error or _("unknown error")),
                    timeout = 5,
                })
            end
        end)
    end)
end

function Syncest:onAddToSyncestLibrary(file)
    self:addToLibrary(file)
end

-- ── Update checker ─────────────────────────────────────────────────

local function syncest_updater()
    return require("syncest_updater")
end

function Syncest:checkForUpdates()
    syncest_updater().check()
end

function Syncest:backgroundUpdateCheck()
    if self.settings.check_updates == false then return end
    syncest_updater().checkBackground(function(ver)
        UIManager:show(Notification:new{
            text = _("Syncest update available: v") .. ver,
            timeout = 2,
        })
    end)
end

function Syncest:_finishResumeProgressPull(cycle)
    if self._resume_progress_cycle ~= cycle then return end
    self._resume_progress_task = nil
    self:backgroundUpdateCheck()
end

function Syncest:_cancelResumeProgressPull()
    self._resume_progress_cycle = (self._resume_progress_cycle or 0) + 1
    if self._resume_progress_task then
        UIManager:unschedule(self._resume_progress_task)
        self._resume_progress_task = nil
    end
end

function Syncest:_pullProgressOnResume()
    if not self.settings.auto_sync
            or self.settings.auto_pull_progress_resume ~= true
            or WebDavAuth:needsSetup(self.settings)
            or not (self.ui and self.ui.document) then
        return false
    end
    local now = os.time()
    if self._last_resume_progress_pull_at
            and now - self._last_resume_progress_pull_at < RESUME_PROGRESS_PULL_DEBOUNCE then
        return true
    end
    self._last_resume_progress_pull_at = now
    self:_cancelResumeProgressPull()
    local cycle = self._resume_progress_cycle
    local attempt = 1
    local run_attempt
    local schedule_attempt

    schedule_attempt = function(delay)
        if self._resume_progress_cycle ~= cycle then return end
        self._resume_progress_task = function()
            self._resume_progress_task = nil
            run_attempt()
        end
        UIManager:scheduleIn(delay, self._resume_progress_task)
    end

    run_attempt = function()
        if self._resume_progress_cycle ~= cycle
                or not (self.ui and self.ui.document) then
            return
        end
        if NetworkMgr:willRerunWhenOnline(function()
                if self._resume_progress_cycle == cycle then
                    schedule_attempt(0.1)
                end
            end) then
            return
        end

        local book_hash = self:getBookIdentifiers()
        if not book_hash then
            self:_finishResumeProgressPull(cycle)
            return
        end
        self._suppress_auto_push_config_until =
            os.time() + AUTO_PUSH_SUPPRESS_AFTER_PULL
        local attempt_number = attempt
        logger.info("Syncest resume progress pull: attempt "
            .. tostring(attempt_number))
        local launched = self:_backgroundPullProgress(
            book_hash, true, false, nil, {
                retries = 0,
                suppress_failure_notify = true,
                on_success = function()
                    self:_finishResumeProgressPull(cycle)
                end,
                on_failure = function()
                    if self._resume_progress_cycle ~= cycle then return end
                    local delay = RESUME_PROGRESS_RETRY_DELAYS[attempt_number]
                    if delay then
                        attempt = attempt_number + 1
                        logger.info("Syncest resume progress pull: retrying in "
                            .. tostring(delay) .. " seconds")
                        schedule_attempt(delay)
                    else
                        self:_autoFailureNotify("progress")
                        self:_finishResumeProgressPull(cycle)
                    end
                end,
            })
        if not launched then
            schedule_attempt(0.5)
        end
    end

    schedule_attempt(RESUME_PROGRESS_INITIAL_DELAY)
    return true
end

function Syncest:onResume()
    if not self:_pullProgressOnResume() then
        self:backgroundUpdateCheck()
    end
end

function Syncest:onLeaveStandby()
    if not self:_pullProgressOnResume() then
        self:backgroundUpdateCheck()
    end
end

function Syncest:updateMenuItems()
    local Updater = syncest_updater()
    return {
        {
            text = _("Check for updates on wake"),
            checked_func = function()
                return self.settings.check_updates ~= false
            end,
            callback = function()
                self.settings.check_updates = self.settings.check_updates == false
                G_reader_settings:saveSetting("webdav_sync", self.settings)
            end,
        },
        {
            text_func = function()
                local current = Updater.getInstalledVersion()
                local available = Updater.getAvailableUpdate()
                if available then
                    return _("Update available") .. ": v" .. current .. " -> v" .. available
                end
                return _("Installed version") .. ": v" .. current
            end,
            keep_menu_open = true,
            callback = function()
                self:checkForUpdates()
            end,
        },
    }
end

-- ── Menu ───────────────────────────────────────────────────────────

function Syncest:addToMainMenu(menu_items)
    local function syncest_menu_items()
        local configured = not WebDavAuth:needsSetup(self.settings)
        local in_book = self.ui.document ~= nil
        local items = {
            {
                text_func = function()
                    local status
                    if WebDavAuth:needsSetup(self.settings) then
                        status = _("Not configured")
                    elseif self._syncest_connection_state == true then
                        status = _("Connected")
                    elseif self._syncest_connection_state == false then
                        status = _("Disconnected")
                    else
                        status = _("Idle")
                    end
                    return _("Syncest") .. ": " .. status
                end,
                sub_item_table_func = function()
                    return {
                        {
                            text = _("Configure WebDAV"),
                            callback_func = function()
                                return function(menu)
                                    WebDavAuth:setup(self.settings, menu)
                                end
                            end,
                        },
                    }
                end,
            },
            {
                text = _("Auto sync"),
                checked_func = function() return self.settings.auto_sync end,
                callback = function() self:onSyncestToggleAutoSync() end,
            },
            {
                text = _("Sync settings"),
                sub_item_table = {
                    {
                        text = _("Mirror progress to KOSync"),
                        checked_func = function() return self.settings.mirror_to_kosync end,
                        callback = function()
                            self.settings.mirror_to_kosync = not self.settings.mirror_to_kosync
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                        separator = true,
                    },
                    {
                        text = _("Auto Sync Settings"),
                        enabled_func = function() return false end,
                    },
                    {
                        text = _("Progress"),
                        enabled_func = function() return false end,
                    },
                    {
                        text_func = function()
                            local n = self.settings.push_page_interval or 1
                            if n == 1 then
                                return T(_("Push every %1 page turn (hold to change)"), n)
                            end
                            return T(_("Push every %1 page turns (hold to change)"), n)
                        end,
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.push_every_x_pages == true
                        end,
                        callback = function()
                            self.settings.push_every_x_pages =
                                not self.settings.push_every_x_pages
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                        hold_callback = function(menu_widget)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                title_text = _("Push every X page turns"),
                                value = self.settings.push_page_interval or 1,
                                value_min = 1,
                                value_max = 500,
                                value_step = 1,
                                ok_always_enabled = true,
                                callback = function(spin)
                                    self.settings.push_page_interval = spin.value
                                    G_reader_settings:saveSetting("webdav_sync", self.settings)
                                    if menu_widget then
                                        UIManager:scheduleIn(0.1, function()
                                            menu_widget:updateItems()
                                            UIManager:forceRePaint()
                                        end)
                                    end
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Push reading progress on chapter finish"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_progress_chapter == true
                        end,
                        callback = function()
                            self.settings.auto_push_progress_chapter =
                                self.settings.auto_push_progress_chapter ~= true
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Push reading progress on book close"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_progress_close ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_progress_close =
                                self.settings.auto_push_progress_close == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull reading progress on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_progress ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_progress =
                                self.settings.auto_pull_progress == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull reading progress on app resume"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_progress_resume == true
                        end,
                        callback = function()
                            self.settings.auto_pull_progress_resume =
                                self.settings.auto_pull_progress_resume ~= true
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Annotations"),
                        enabled_func = function() return false end,
                        separator = true,
                    },
                    {
                        text = _("Push annotations on change"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_annotations ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_annotations =
                                self.settings.auto_push_annotations == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Push annotations on book close"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            if self.settings.auto_push_annotations_close == nil then
                                return self.settings.auto_push_annotations ~= false
                            end
                            return self.settings.auto_push_annotations_close ~= false
                        end,
                        callback = function()
                            if self.settings.auto_push_annotations_close == nil then
                                self.settings.auto_push_annotations_close =
                                    self.settings.auto_push_annotations == false
                            else
                                self.settings.auto_push_annotations_close =
                                    self.settings.auto_push_annotations_close == false
                            end
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull annotations on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_annotations ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_annotations =
                                self.settings.auto_pull_annotations == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Stats"),
                        enabled_func = function() return false end,
                        separator = true,
                    },
                    {
                        text = _("Push stats on book close"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_stats ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_stats =
                                self.settings.auto_push_stats == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull stats on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_stats_book_open == true
                        end,
                        callback = function()
                            self.settings.auto_pull_stats_book_open =
                                self.settings.auto_pull_stats_book_open ~= true
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull stats on app open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_stats ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_stats =
                                self.settings.auto_pull_stats == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Vocab"),
                        enabled_func = function() return false end,
                        separator = true,
                    },
                    {
                        text = _("Push vocab on word lookup"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_vocab ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_vocab =
                                self.settings.auto_push_vocab == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull vocab on app open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_vocab ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_vocab =
                                self.settings.auto_pull_vocab == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                },
            },
            {
                text = _("Notifications"),
                sub_item_table_func = function()
                    local definitions = {
                        { _("Progress"), "progress_notifications" },
                        { _("Annotations"), "annotation_notifications" },
                        { _("Stats"), "stats_notifications" },
                        { _("Vocabulary"), "vocab_notifications" },
                        { _("Books and library"), "books_notifications" },
                        { _("Connection"), "connection_notifications" },
                    }
                    local notification_items = {}
                    for _, definition in ipairs(definitions) do
                        local label, key = definition[1], definition[2]
                        notification_items[#notification_items + 1] = {
                            text = label,
                            checked_func = function()
                                return self.settings[key] ~= false
                            end,
                            callback = function()
                                self.settings[key] = self.settings[key] == false
                                G_reader_settings:saveSetting(
                                    "webdav_sync", self.settings)
                            end,
                        }
                    end
                    return notification_items
                end,
            },
            {
                text = _("Updates"),
                sub_item_table_func = function()
                    return self:updateMenuItems()
                end,
                separator = true,
            },
            -- ── Library & Books ─────────────────────────────────────
            {
                text = _("Syncest Library"),
                enabled_func = function() return configured end,
                callback = function() self:openLibrary() end,
            },
            {
                text = _("Push books now"),
                enabled_func = function() return configured end,
                callback = function() self:syncBooksLibrary("push", true) end,
            },
            {
                text = _("Pull books now"),
                enabled_func = function() return configured end,
                callback = function() self:syncBooksLibrary("pull", true) end,
                separator = true,
                syncest_page_break_after = true,
            },
            -- ── Stats & Vocab ───────────────────────────────────────
            {
                text = _("Push stats now"),
                enabled_func = function() return configured end,
                callback = function() self:pushBookStats(false, true, true) end,
            },
            {
                text = _("Pull stats now"),
                enabled_func = function() return configured end,
                callback = function() self:pullBookStats(false, true, true) end,
            },
            {
                text = _("Push vocab now"),
                enabled_func = function() return configured end,
                callback = function() self:pushVocab(false, true) end,
            },
            {
                text = _("Pull vocab now"),
                enabled_func = function() return configured end,
                callback = function() self:pullVocab(false, true) end,
                separator = true,
            },
            -- ── Push/Pull All ───────────────────────────────────────
            {
                text = _("Push all now"),
                enabled_func = function() return configured end,
                callback = function() self:pushAll(true) end,
            },
            {
                text = _("Pull all now"),
                enabled_func = function() return configured end,
                callback = function() self:pullAll(true) end,
            },
        }

        if in_book then
            local book_items = {
                {
                    text = _("Progress history"),
                    enabled_func = function() return configured end,
                    callback = function() self:showProgressHistory() end,
                },
                {
                    text = _("Push reading progress now"),
                    enabled_func = function() return configured end,
                    callback = function()
                        self:pushBookConfigAsync(true, "manual", "manual")
                    end,
                },
                {
                    text = _("Pull reading progress now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pullBookConfigAsync(true, true) end,
                },
                {
                    text = _("Push annotations now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pushBookNotes(true, true, true) end,
                },
                {
                    text = _("Pull annotations now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pullBookNotes(true, false, true) end,
                    separator = true,
                },
            }
            -- Insert after the 5 settings items (Connection, Auto sync,
            -- Sync settings, Notifications, Updates).
            for i = #book_items, 1, -1 do
                table.insert(items, 6, book_items[i])
            end
            -- Sync info always at the very bottom
            items[#items].separator = true
            items[#items + 1] = {
                text = _("Sync info"),
                callback = function() self:showSyncInfo() end,
            }
        else
            local annotation_items = {
                {
                    text = _("Push all annotations now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pushAllFileAnnotations(true) end,
                },
                {
                    text = _("Pull all annotations now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pullAllFileAnnotations(true) end,
                    separator = true,
                },
            }
            for i = #annotation_items, 1, -1 do
                table.insert(items, 6, annotation_items[i])
            end
        end

        -- TouchMenu paginates submenus by a fixed item count rather than
        -- supporting explicit page-break entries. Use the final position of
        -- Pull books now (after reader/file-manager items are inserted) as
        -- this submenu's page size, keeping Stats and everything after it on
        -- page two.
        for i, item in ipairs(items) do
            if item.syncest_page_break_after then
                items.max_per_page = i
                break
            end
        end

        return items
    end

    menu_items.syncest = {
        text = _("Syncest"),
        sub_item_table_func = syncest_menu_items,
    }
end

-- ── Client helper ──────────────────────────────────────────────────

function Syncest:ensureClient(interactive)
    if WebDavAuth:needsSetup(self.settings) then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Configure WebDAV sync first"), timeout = 2,
            })
        end
        return nil
    end
    local server = self.settings.sync_server or {}
    local key = table.concat({
        tostring(server.address or ""),
        tostring(server.url or ""),
        tostring(server.username or ""),
    }, "|")
    if not self._sync_client or self._sync_client_key ~= key then
        self._sync_client = WebDavAuth:getClient(self.settings)
        self._sync_client_key = key
    end
    return self._sync_client
end

function Syncest:getBookIdentifiers()
    return SyncConfig:getDocumentIdentifier(self.ui)
end

local function progress_history_location_text(config)
    if type(config) ~= "table" then return _("Unknown location") end
    local current = tonumber(config.currentPage)
        or (type(config.progress) == "table" and tonumber(config.progress[1]))
    local total = tonumber(config.pageCount)
        or (type(config.progress) == "table" and tonumber(config.progress[2]))
    if current and total and total > 0 then
        return T(_("Page %1 of %2"), tostring(current), tostring(total))
    end
    local percent = tonumber(config.progressPercent)
    if percent then
        return string.format(_("%.1f%%"), percent * 100)
    end
    return _("Saved location")
end

local function progress_history_entry_text(entry)
    entry = type(entry) == "table" and entry or {}
    local parts = {}
    if type(entry.chapterTitle) == "string" and entry.chapterTitle ~= "" then
        parts[#parts + 1] = entry.chapterTitle
    end
    parts[#parts + 1] = progress_history_location_text(entry.config)
    if type(entry.excerpt) == "string" and entry.excerpt ~= "" then
        parts[#parts + 1] = "“" .. entry.excerpt .. "”"
    end
    return table.concat(parts, " · ")
end

function Syncest:_showProgressHistorySettings(history_menu, entries)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function refresh_history()
        UIManager:close(dialog)
        UIManager:close(history_menu)
        self:_showProgressHistoryEntries(entries)
    end
    dialog = ButtonDialog:new{
        title = _("Progress history settings"),
        buttons = {
            {
                {
                    text = T(_("History entries per type: %1"),
                        tostring(self.settings.progress_history_count or 25)),
                    callback = function()
                        local count_dialog
                        count_dialog = ButtonDialog:new{
                            title = _("History entries per type"),
                            buttons = {
                                {
                                    {
                                        text = "10",
                                        callback = function()
                                            self.settings.progress_history_count = 10
                                            G_reader_settings:saveSetting(
                                                "webdav_sync", self.settings)
                                            UIManager:close(count_dialog)
                                            refresh_history()
                                        end,
                                    },
                                    {
                                        text = "25",
                                        callback = function()
                                            self.settings.progress_history_count = 25
                                            G_reader_settings:saveSetting(
                                                "webdav_sync", self.settings)
                                            UIManager:close(count_dialog)
                                            refresh_history()
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(count_dialog)
                    end,
                },
            },
            {
                {
                    text = T(_("Device name: %1"),
                        progress_history_device_name(self.settings)),
                    callback = function()
                        local InputDialog = require("ui/widget/inputdialog")
                        local input
                        local function save_name(value)
                            value = type(value) == "string"
                                and value:match("^%s*(.-)%s*$") or ""
                            self.settings.progress_history_device_name =
                                value ~= "" and value or nil
                            G_reader_settings:saveSetting(
                                "webdav_sync", self.settings)
                            local device_id =
                                progress_history_device_id(self.settings)
                            local device_name =
                                progress_history_device_name(self.settings)
                            for _, entry in ipairs(entries or {}) do
                                if tostring(entry.deviceId or "") ==
                                        tostring(device_id) then
                                    entry.deviceName = device_name
                                end
                            end
                            local book_hash = self:getBookIdentifiers()
                            local server = self.settings.sync_server
                            if book_hash and type(server) == "table" then
                                self:_runBackgroundJSON(
                                    "background progress history device rename",
                                    "syncest_progress_history_device_rename",
                                    function()
                                        local Client = require("webdav_syncclient")
                                        local client = Client:new{ server = server }
                                        return {
                                            success = client:
                                                updateProgressHistoryDeviceName(
                                                    book_hash, device_id,
                                                    device_name),
                                        }
                                    end,
                                    function() end,
                                    function()
                                        logger.warn(
                                            "Syncest progress history device rename failed")
                                    end)
                            end
                            UIManager:close(input)
                            refresh_history()
                        end
                        input = InputDialog:new{
                            title = _("Device name"),
                            input = self.settings.progress_history_device_name
                                or progress_history_device_name(self.settings),
                            input_hint = _("For example: Palma or Pixel Fold"),
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
                                        text = _("Use default"),
                                        callback = function() save_name("") end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            save_name(input:getInputText())
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
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Syncest:_showProgressHistoryEntries(entries)
    local filter = self.settings.progress_history_filter or "both"
    local count = math.max(1, tonumber(self.settings.progress_history_count) or 25)
    local metadata = SyncConfig:getMetadataHashInfo(self.ui)
    local book_title = metadata.title ~= "" and metadata.title or _("Unknown title")
    local book_author = #metadata.authors > 0
        and table.concat(metadata.authors, ", ") or _("Unknown author")
    local current_config = SyncConfig:getCurrentBookConfig(self.ui)
    local current_context = progress_history_context(self.ui, current_config)
    local current_location = progress_history_entry_text({
        config = current_config,
        chapterTitle = current_context.chapterTitle,
        excerpt = current_context.excerpt,
    })
    local labels = {
        both = _("Automatic and manual"),
        auto = _("Automatic only"),
        manual = _("Manual only"),
    }
    local item_table = {{
        text = _("Show") .. ": " .. (labels[filter] or labels.both),
        _history_filter = true,
    }}
    local shown = 0
    local shown_by_source = { manual = 0, auto = 0 }
    for history_index, entry in ipairs(entries or {}) do
        local entry_source = entry.source == "manual" and "manual" or "auto"
        local source_matches = filter == "both" or entry_source == filter
        local source_has_room = shown_by_source[entry_source] < count
        if source_matches and source_has_room then
            shown = shown + 1
            shown_by_source[entry_source] = shown_by_source[entry_source] + 1
            local timestamp = tonumber(entry.timestamp) or 0
            if timestamp > 100000000000 then timestamp = math.floor(timestamp / 1000) end
            local source = entry_source == "manual" and _("Manual") or _("Automatic")
            local device = entry.deviceName or entry.deviceId or _("Unknown device")
            if tostring(entry.deviceId or "") == tostring(
                    progress_history_device_id(self.settings)) then
                device = progress_history_device_name(self.settings)
            end
            item_table[#item_table + 1] = {
                text = progress_history_entry_text(entry)
                    .. " · " .. os.date("%Y-%m-%d %H:%M", timestamp)
                    .. " · " .. source
                    .. " · " .. tostring(device),
                _history_entry = entry,
            }
        end
        if filter == "both"
                and shown_by_source.manual >= count
                and shown_by_source.auto >= count then
            break
        elseif filter ~= "both" and shown_by_source[filter] >= count then
            break
        end
    end
    if shown == 0 then
        item_table[#item_table + 1] = {
            text = _("No matching progress history"),
            dim = true,
        }
    end

    local menu
    menu = Menu:new{
        title = _("Progress history") .. "\n" .. book_title,
        subtitle = book_author .. "\n"
            .. _("Current") .. ": " .. current_location,
        title_multilines = true,
        title_shrink_font_to_fit = true,
        title_bar_left_icon = "appbar.settings",
        onLeftButtonTap = function()
            self:_showProgressHistorySettings(menu, entries)
            return true
        end,
        is_borderless = true,
        is_popout = false,
        item_table = item_table,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        onMenuSelect = function(_menu, item)
            if item._history_filter then
                local next_filter = filter == "both" and "auto"
                    or (filter == "auto" and "manual" or "both")
                self.settings.progress_history_filter = next_filter
                G_reader_settings:saveSetting("webdav_sync", self.settings)
                UIManager:close(menu)
                self:_showProgressHistoryEntries(entries)
                return
            end
            local entry = item._history_entry
            if not entry or type(entry.config) ~= "table" then return end
            UIManager:show(ConfirmBox:new{
                text = _("Go to this saved reading position?")
                    .. "\n\n" .. progress_history_entry_text(entry),
                ok_text = _("Go"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    if self.ui and self.ui.document then
                        SyncConfig:applyBookConfig(self.ui, entry.config, true)
                        UIManager:close(menu)
                    end
                end,
            })
        end,
    }
    UIManager:show(menu)
end

function Syncest:showProgressHistory()
    local book_hash = self:getBookIdentifiers()
    local server = self.settings and self.settings.sync_server
    if not book_hash or type(server) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Open a book and configure WebDAV first."), timeout = 2,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Loading progress history…"), timeout = 1,
    })
    self:_runBackgroundJSON(
        "background progress history pull",
        "syncest_progress_history",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local entries = client:pullProgressHistory(book_hash)
            if entries == nil then
                return {success = false, message = "history read failed"}
            end
            return {success = true, entries = entries}
        end,
        function(result)
            if self:getBookIdentifiers() == book_hash then
                self:_showProgressHistoryEntries(result.entries or {})
            end
        end,
        function()
            UIManager:show(InfoMessage:new{
                text = _("Could not load progress history."), timeout = 3,
            })
        end)
end

function Syncest:showSyncInfo()
    if not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("No book is open"), timeout = 2 })
        return
    end
    local info = SyncConfig:getMetadataHashInfo(self.ui)
    local book_hash = SyncConfig:getDocumentIdentifier(self.ui)
    local doc_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
    local gs = G_reader_settings:readSetting("webdav_sync") or {}
    local placeholder = _("(none)")
    local never = _("Never")
    local function fmt(ts)
        return (ts and ts > 0) and os.date("%Y-%m-%d %H:%M", ts) or never
    end
    local function max_ts(...)
        local m = 0
        for _, v in ipairs({...}) do
            local n = tonumber(v) or 0
            if n > m then m = n end
        end
        return m > 0 and m or nil
    end
    local kv_pairs = {
        { _("Book Hash"),  book_hash or placeholder },
        { _("Title"),  info.title ~= "" and info.title or placeholder },
        { _("Author"), #info.authors > 0 and table.concat(info.authors, ", ") or placeholder },
        { _("Progress pushed"),    fmt(max_ts(doc_sync.last_pushed_at_config)) },
        { _("Progress pulled"),    fmt(max_ts(doc_sync.last_synced_at_config)) },
        { _("Annotations pushed"), fmt(max_ts(doc_sync.last_pushed_at_notes)) },
        { _("Annotations pulled"), fmt(max_ts(doc_sync.last_synced_at_notes)) },
        { _("Stats pushed"),       fmt(gs.stats_last_pushed_at) },
    }
    UIManager:show(KeyValuePage:new{ title = _("Sync Info"), kv_pairs = kv_pairs })
end

-- ── Config sync ────────────────────────────────────────────────────

function Syncest:pushBookConfig(interactive, notify)
    logger.info("Syncest pushBookConfig: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    local now = os.time()
    if not interactive and self._suppress_auto_push_config_until
            and now < self._suppress_auto_push_config_until then
        logger.info("Syncest pushBookConfig: suppressed after pull until "
            .. tostring(self._suppress_auto_push_config_until))
        return
    end
    if not interactive and now - self.last_sync_timestamp <= API_CALL_DEBOUNCE_DELAY then
        return
    end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookConfig(interactive) end) then
        return
    end
    if not interactive then
        self:pushBookConfigAsync(notify,
            interactive and "manual" or "auto",
            interactive and "manual" or nil)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    local book_hash = self:getBookIdentifiers()
    self.last_sync_timestamp = SyncConfig:push(
        self.ui, self.settings, client, interactive, self.last_sync_timestamp,
        notify_fn, self:_readProgressReadingStatus(book_hash))
    self:_mirrorProgressToKOSync()
end

function Syncest:pullBookConfig(interactive, notify, force_apply)
    logger.info("Syncest pullBookConfig: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify)
        .. " force_apply=" .. tostring(force_apply))
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookConfig(interactive, notify, force_apply) end) then
        return
    end
    if not interactive then
        self:pullBookConfigAsync(notify, force_apply == true)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncConfig:pull(self.ui, self.settings, client, book_hash,
        interactive, function() end, notify_fn,
        function(response) self:_applyProgressReadingStatus(book_hash, response) end)
end

-- ── Stats sync ─────────────────────────────────────────────────────

function Syncest:pushBookStats(interactive, notify, manual)
    logger.info("Syncest pushBookStats: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookStats(interactive, notify, manual) end) then
        return
    end
    if not interactive then
        self:_backgroundPushStats(notify, manual == true)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncStats:push(self.settings, client, interactive, notify_fn)
end

function Syncest:pullBookStats(interactive, notify, manual)
    logger.info("Syncest pullBookStats: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookStats(interactive, notify, manual) end) then
        return
    end
    if not interactive then
        self:_backgroundPullStats(notify, manual == true)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncStats:pull(self.settings, client, interactive, function() end, notify_fn)
end

-- ── Vocab sync ─────────────────────────────────────────────────────

function Syncest:pushVocab(interactive, notify)
    logger.info("Syncest pushVocab: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushVocab(interactive) end) then
        return
    end
    if not interactive then
        self:_backgroundPushVocab(notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncVocab:push(self.settings, client, interactive, notify_fn)
end

function Syncest:pullVocab(interactive, notify)
    logger.info("Syncest pullVocab: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullVocab(interactive, notify) end) then
        return
    end
    if not interactive then
        self:_backgroundPullVocab(notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncVocab:pull(self.settings, client, interactive, notify_fn)
end

-- ── Annotation sync ────────────────────────────────────────────────

function Syncest:pushBookNotes(interactive, full_sync, notify)
    logger.info("Syncest pushBookNotes: interactive=" .. tostring(interactive)
        .. " full_sync=" .. tostring(full_sync) .. " notify=" .. tostring(notify))
    if interactive and NetworkMgr:willRerunWhenOnline(
            function() self:pushBookNotes(interactive, full_sync) end) then
        return
    end
    if interactive and not self:ensureClient(interactive) then
        return
    end
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    local meta = SyncConfig:getMetadataHashInfo(self.ui)
    local annotations =
        SyncAnnotations:getAnnotations(self.ui, self.settings, book_hash, full_sync)
    local doc_readest_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
    local current_bookmark_ids
    if doc_readest_sync.last_synced_at_notes then
        current_bookmark_ids =
            SyncAnnotations:getCurrentBookmarkIds(self.ui, book_hash)
        if not next(current_bookmark_ids) then
            current_bookmark_ids = nil
        end
    end
    for _, t in ipairs(doc_readest_sync.deleted_notes or {}) do
        t.bookHash = book_hash
        annotations[#annotations + 1] = t
    end
    annotations = SyncAnnotations:addCurrentBookmarks(
        annotations, self.ui, book_hash)
    if #annotations == 0 and not current_bookmark_ids then
        return
    end
    for _, t in ipairs(annotations) do
        t.bookMetadata = meta
    end
    self:_backgroundPushAnnotations({
        books = {},
        notes = annotations,
        configs = {},
        bookHash = book_hash,
        currentBookmarkIds = current_bookmark_ids,
    }, notify)
end

function Syncest:pullBookNotes(interactive, full_sync, notify)
    logger.info("Syncest pullBookNotes: interactive=" .. tostring(interactive)
        .. " full_sync=" .. tostring(full_sync) .. " notify=" .. tostring(notify))
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookNotes(interactive, full_sync, notify) end) then
        return
    end
    if self.ui and self.ui.document and self.ui.document.info
            and self.ui.document.info.has_pages then
        logger.warn("Syncest pullBookNotes: pull skipped for paged document")
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Annotation sync is not supported for PDF/CBZ documents."),
                timeout = 3,
            })
        end
        return
    end
    if interactive and not self:ensureClient(interactive) then
        return
    end
    self:_backgroundPullAnnotations(book_hash, full_sync, notify)
end

function Syncest:pushAll(interactive)
    self:_runSafely("push all", function()
        self:_beginAutoNotifyBatch(20, true, "pushed")
        local in_book = self.ui and self.ui.document
        if in_book then
            self:pushBookConfigAsync(
                true, interactive and "manual" or "auto", "push_all")
            self:pushBookNotes(false, true, true)
        end
        self:pushBookStats(false, true, interactive == true)
        self:pushVocab(false, true)
    end, interactive)
end

function Syncest:pullAll(interactive)
    self:_runSafely("pull all", function()
        self:_beginAutoNotifyBatch(20, true, "pulled")
        local in_book = self.ui and self.ui.document
        if in_book then
            self:pullBookConfigAsync(true, true)
            self:pullBookNotes(false, false, true)
        end
        self:pullBookStats(false, true, interactive == true)
        self:pullVocab(false, true)
    end, interactive)
end

function Syncest:fullSyncBookNotes()
    self:pushBookNotes(true, true, true)
    self:pullBookNotes(true, true, true)
end

-- ── Library ────────────────────────────────────────────────────────

function Syncest:openLibrary()
    if WebDavAuth:needsSetup(self.settings) then
        UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first"), timeout = 2 })
        return
    end
    local client = WebDavAuth:getClient(self.settings)
    local LibraryWidget = require("syncest_lib.librarywidget")
    LibraryWidget.open({
        settings = self.settings,
        client   = client,
    })
end

-- Standard external-launch entry point. Zen UI's custom plugin tabs look for
-- open/show/launch methods, so exposing this keeps the integration in Syncest
-- and lets a tab open the cloud library directly instead of the Syncest menu.
function Syncest:open()
    return self:openLibrary()
end

function Syncest:getLibraryStore()
    if not self.settings or not self.settings.user_id
            or self.settings.user_id == "" then return nil end
    local LibraryWidget = require("syncest_lib.librarywidget")
    if LibraryWidget._store and LibraryWidget._current_user == self.settings.user_id then
        return LibraryWidget._store
    end
    if self.library_store and self.library_store.user_id == self.settings.user_id then
        return self.library_store
    end
    if self.library_store then self.library_store:close() end
    local LibraryStore = require("syncest_lib.librarystore")
    local DataStorage  = require("datastorage")
    self.library_store = LibraryStore.new({
        user_id = self.settings.user_id,
        db_path = DataStorage:getSettingsDir() .. "/syncest_library.sqlite3",
    })
    return self.library_store
end

function Syncest:_readProgressReadingStatus(book_hash)
    if not book_hash or book_hash == "" then return nil end
    local store = self:getLibraryStore()
    local row
    if store then
        row = store:_getRowRaw(book_hash)
        if row and row.reading_status ~= nil then
            local ts = row.reading_status_updated_at or os.time() * 1000
            if not row.reading_status_updated_at then
                store:touchBook(book_hash, {
                    reading_status = row.reading_status,
                    reading_status_updated_at = ts,
                })
            end
            return {
                readingStatus = row.reading_status,
                readingStatusUpdatedAt = ts,
            }
        end
    end

    if not self.ui or not self.ui.doc_settings then return nil end
    local summary = self.ui.doc_settings:readSetting("summary") or {}
    local readingstatus = require("syncest_lib.readingstatus")
    local status = readingstatus.ko_to_readest(summary.status)
    if not status then return nil end
    local ts = readingstatus.parse_modified_ms(summary.modified)
        or os.time() * 1000
    if store and row then
        store:touchBook(book_hash, {
            reading_status = status,
            reading_status_updated_at = ts,
        })
    end
    return {
        readingStatus = status,
        readingStatusUpdatedAt = ts,
    }
end

function Syncest:_addProgressReadingStatus(payload, book_hash)
    if type(payload) ~= "table" then return payload end
    book_hash = book_hash
        or (payload.configs and payload.configs[1] and payload.configs[1].bookHash)
    local status = self:_readProgressReadingStatus(book_hash)
    if status and status.readingStatus ~= nil then
        payload.readingStatus = status.readingStatus
        payload.readingStatusUpdatedAt = status.readingStatusUpdatedAt
    end
    return payload
end

function Syncest:_writeCurrentKOReadingStatus(ko_status)
    if not self.ui or not self.ui.doc_settings then return end
    local summary = self.ui.doc_settings:readSetting("summary") or {}
    summary.status = ko_status
    summary.modified = os.date("%Y-%m-%d", os.time())
    self.ui.doc_settings:saveSetting("summary", summary)
    self.ui.doc_settings:flush()
end

function Syncest:_applyProgressReadingStatus(book_hash, progress_data)
    if not book_hash or type(progress_data) ~= "table" then return end
    local status = progress_data.readingStatus or progress_data.reading_status
    local ts = tonumber(progress_data.readingStatusUpdatedAt
        or progress_data.reading_status_updated_at)
    if status == nil or not ts then return end

    local store = self:getLibraryStore()
    local row = store and store:_getRowRaw(book_hash)
    local local_ts = row and tonumber(row.reading_status_updated_at) or nil
    local remote_is_current = not local_ts or ts >= local_ts
    if row and remote_is_current then
        store:touchBook(book_hash, {
            reading_status = status,
            reading_status_updated_at = ts,
        })
    end

    if not remote_is_current or not self.ui or not self.ui.doc_settings then
        return
    end
    local readingstatus = require("syncest_lib.readingstatus")
    if not readingstatus.readest_decisive(status) then return end
    local summary = self.ui.doc_settings:readSetting("summary") or {}
    local r = readingstatus.reconcile(
        { reading_status = status, reading_status_updated_at = ts },
        {
            status = summary.status,
            ts = readingstatus.parse_modified_ms(summary.modified)
                or os.time() * 1000,
        },
        os.time() * 1000)
    if r.write_ko then
        self:_writeCurrentKOReadingStatus(r.ko_status)
    end
    if r.write_store and store and row then
        store:touchBook(book_hash, {
            reading_status = r.readest_status,
            reading_status_updated_at = r.ts,
        })
    end
end

function Syncest:touchOpenBook()
    if not self.ui or not self.ui.doc_settings then return nil end
    local hash = self.ui.doc_settings:readSetting("partial_md5_checksum")
    if not hash or hash == "" then return nil end
    local store = self:getLibraryStore()
    if not store then return nil end
    local progress_lib
    if self.ui.document and self.ui.document.getPageCount and self.ui.getCurrentPage then
        local cur   = self.ui:getCurrentPage()
        local total = self.ui.document:getPageCount()
        if cur and total then
            progress_lib = require("json").encode({ cur, total })
        end
    end
    local touched = store:touchBook(hash, { progress_lib = progress_lib })
    if not touched then
        logger.dbg("Syncest touchOpenBook: no row for " .. hash)
    end
    return touched
end

function Syncest:_backgroundSyncBooksLibrary(
        mode, interactive, archive_dir, library_dir,
        eligible_hashes, archived_hashes, archived_paths,
        pull_files, download_dir)
    local settings = copy_settings(self.settings)
    settings.syncest_archive_dir = archive_dir
    settings.syncest_library_dir = library_dir
    settings.syncest_eligible_hashes = eligible_hashes
    settings.syncest_archived_hashes = archived_hashes
    settings.syncest_archived_paths = archived_paths
    local server = settings and settings.sync_server
    if type(server) ~= "table" or not settings.user_id or settings.user_id == "" then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first"), timeout = 2 })
        end
        return false
    end

    local DataStorage = require("datastorage")
    local db_path = DataStorage:getSettingsDir() .. "/syncest_library.sqlite3"
    local result_prefix = "syncest_books_" .. tostring(mode or "both")
    local progress_file = DataStorage:getSettingsDir()
        .. "/" .. result_prefix .. "_progress_" .. tostring(os.time()) .. ".json"
    local last_progress_key
    os.remove(progress_file)
    local launched = self:_runBackgroundJSON(
        "background books " .. tostring(mode or "both"),
        result_prefix,
        function()
            local WebDavAuthChild = require("webdav_auth")
            local LibraryStore = require("syncest_lib.librarystore")
            local syncbooks = require("syncest_lib.syncbooks")
            local store = LibraryStore.new({
                user_id = settings.user_id,
                db_path = db_path,
            })
            if mode == "push" or mode == "both" then
                syncbooks.enrichLocalMetadata(store)
            end
            local client = WebDavAuthChild:getClient(settings)
            local done_success, done_msg, done_status
            syncbooks.syncBooks({
                client = client,
                settings = settings,
                store = store,
                full_push = mode == "push" and interactive,
                on_inventory_progress = function(progress)
                    write_background_json_result(progress_file, progress)
                end,
                on_upload_progress = function(progress)
                    write_background_json_result(progress_file, progress)
                end,
            }, mode, function(success, msg, status)
                done_success = success == true
                done_msg = msg
                done_status = status
            end)
            local download_summary
            if done_success and pull_files then
                local downloads_ok, summary, downloads_err =
                    syncbooks.downloadMissingBooks({
                        client = client,
                        settings = settings,
                        store = store,
                        download_dir = download_dir,
                        on_download_progress = function(progress)
                            write_background_json_result(progress_file, progress)
                        end,
                    })
                done_success = downloads_ok
                done_msg = downloads_err or done_msg
                download_summary = summary
            end
            store:close()
            if not done_success then
                return {
                    success = false,
                    message = done_msg or "books sync failed",
                    status = done_status,
                    download_summary = download_summary,
                }
            end
            local result = {
                success = true,
                message = done_msg,
                status = done_status,
                download_summary = download_summary,
            }
            if mode == "push" or mode == "both" then
                result.catalog_last_pushed_at = os.time()
            end
            return result
        end,
        function(result)
            if result.catalog_last_pushed_at then
                self.settings.catalog_last_pushed_at = result.catalog_last_pushed_at
                G_reader_settings:saveSetting("webdav_sync", self.settings)
            end
            if interactive then
                local text
                if result.download_summary then
                    local summary = result.download_summary
                    local failed = tonumber(summary.failed) or 0
                    if failed > 0 then
                        text = string.format(
                            _("Books download finished: %d downloaded, %d already local, %d failed"),
                            tonumber(summary.downloaded) or 0,
                            tonumber(summary.already_local) or 0,
                            failed)
                    else
                        text = string.format(
                            _("Books download finished: %d downloaded, %d already local"),
                            tonumber(summary.downloaded) or 0,
                            tonumber(summary.already_local) or 0)
                    end
                else
                    text = (mode == "push" or mode == "both")
                        and _("Books upload finished")
                        or _("Books sync finished")
                end
                self:_showBooksSyncNotification(text, 8)
            end
            local LibraryWidget = require("syncest_lib.librarywidget")
            if result.download_summary then
                LibraryWidget.refreshAfterDownload()
            elseif LibraryWidget._menu then
                LibraryWidget.refresh()
            end
            os.remove(progress_file)
        end,
        function(message)
            if interactive then
                self:_showBooksSyncNotification(
                    "Books sync failed: " .. tostring(message),
                    8
                )
            end
            os.remove(progress_file)
        end,
        BOOKS_SYNC_MAX_POLLS,
        function()
            if not interactive then return end
            local progress = peek_background_json_result(progress_file)
            if not progress or not progress.total or progress.total <= 0 then return end
            local done = tonumber(progress.done) or 0
            local total = tonumber(progress.total) or 0
            local failed = tonumber(progress.failed) or 0
            local key = tostring(done) .. "/" .. tostring(total) .. "/" .. tostring(failed)
            if key == last_progress_key then return end
            last_progress_key = key
            local verb = progress.phase == "download" and "downloading"
                or progress.phase == "verify" and "verifying"
                or "uploading"
            local text = failed > 0
                and string.format("Books %s %d/%d (%d failed)", verb, done, total, failed)
                or string.format("Books %s %d/%d", verb, done, total)
            self:_showBooksSyncNotification(text, 60)
        end
    )

    if launched and interactive then
        self:_showBooksSyncNotification(
            pull_files
                and _("Books download started")
                or (mode == "push" or mode == "both")
                and _("Books upload started")
                or _("Books sync started"),
            60
        )
    end
    return launched
end

function Syncest:syncBooksLibrary(mode, interactive, confirmed)
    if WebDavAuth:needsSetup(self.settings) then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first"), timeout = 2 })
        end
        return
    end
    local store = self:getLibraryStore()
    if not store then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Library not initialized"), timeout = 2 })
        end
        return
    end
    local localscanner = require("syncest_lib.localscanner")
    local home_dir = G_reader_settings:readSetting("home_dir") or "/sdcard/Books"
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local archive_settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/move_to_archive_settings.lua")
    local archive_dir = archive_settings:readSetting("archive_dir")
        or archive_settings:readSetting("archive_dir_path")
    local archive_original_dirs =
        archive_settings:readSetting("library_archive_original_dirs") or {}

    -- Scan all books before a bulk transfer. Pull computes hashes for unopened
    -- local files too, so a matching cloud book is skipped instead of being
    -- downloaded under a collision filename.
    if mode == "push" or mode == "both" or mode == "pull" then
        -- Reconcile the index with the filesystem first. In particular, this
        -- force-clears local_present for rows whose files were removed, so a
        -- full push cannot resurrect stale catalog entries.
        pcall(localscanner.lightScan, {
            store = store,
            ui = self.ui,
        })
        local archived_hashes = archive_dir
            and localscanner.bookHashesInDir(archive_dir) or nil
        local eligible_hashes = localscanner.bookHashesInDir(home_dir)
        for hash in pairs(archived_hashes or {}) do
            eligible_hashes[hash] = nil
        end
        -- KOReader records archived-file -> original-directory. Include both
        -- paths because our SQLite row may still contain the pre-move path.
        local archived_paths = {}
        for archived_path, original_dir in pairs(archive_original_dirs) do
            archived_paths[archived_path:gsub("/+$", "")] = true
            local filename = archived_path:match("([^/]+)$")
            if filename and type(original_dir) == "string" then
                archived_paths[original_dir:gsub("/+$", "")
                    .. "/" .. filename] = true
            end
        end
        pcall(localscanner.dirScan, {
            store = store,
            dir = home_dir,
            excluded_dirs = (mode == "push" or mode == "both")
                and archive_dir and { archive_dir } or nil,
            -- A bulk push means every supported file currently in the home
            -- tree, including books KOReader has not opened yet.
            compute_hashes = true,
        })
        if mode == "pull" and archive_dir and archive_dir ~= home_dir
                and not localscanner.path_is_excluded(archive_dir, { home_dir }) then
            pcall(localscanner.dirScan, {
                store = store,
                dir = archive_dir,
                compute_hashes = true,
            })
        end
        if mode == "pull" then
            local download_dir = self.settings.library_download_dir
                or G_reader_settings:readSetting("download_dir")
                or G_reader_settings:readSetting("home_dir")
                or DataStorage:getDataDir()
            if interactive and not confirmed then
                local syncbooks = require("syncest_lib.syncbooks")
                local missing, total = syncbooks.countMissingBooks(store)
                UIManager:show(ConfirmBox:new{
                    text = string.format(
                        _("The current cloud catalog has %d of %d books missing locally.\n\nPull the latest catalog and download every missing book to:\n%s"),
                        missing, total, download_dir),
                    ok_text = _("Download books"),
                    ok_callback = function()
                        self:syncBooksLibrary(mode, interactive, true)
                    end,
                })
                return
            end
            self:_backgroundSyncBooksLibrary(
                mode, interactive, archive_dir, home_dir,
                eligible_hashes, archived_hashes, archived_paths,
                true, download_dir)
            return
        end
        self:touchOpenBook()
        self:_backgroundSyncBooksLibrary(
            mode, interactive, archive_dir, home_dir,
            eligible_hashes, archived_hashes, archived_paths)
        return
    end
    self:_backgroundSyncBooksLibrary(mode, interactive)
end

-- ── Event handlers ─────────────────────────────────────────────────

function Syncest:onSyncestToggleAutoSync(toggle)
    if toggle == self.settings.auto_sync then return true end
    self.settings.auto_sync = not self.settings.auto_sync
    G_reader_settings:saveSetting("webdav_sync", self.settings)
    if self.settings.auto_sync and self.ui.document then
        self:pullBookConfig(false, true, false)
    end
end

function Syncest:onSyncestOpenProgressHistory()
    self:_runSafely("open progress history", function()
        self:showProgressHistory()
    end, true)
end

function Syncest:onSyncestPushProgress()
    self:_runSafely("manual push progress", function()
        self:pushBookConfigAsync(true, "manual", "manual")
    end, true)
end
function Syncest:onSyncestPullProgress()
    self:_runSafely("manual pull progress", function() self:pullBookConfigAsync(true, true) end, true)
end
function Syncest:onSyncestPushAnnotations()
    self:_runSafely("manual push annotations", function() self:pushBookNotes(true, true, true) end, true)
end
function Syncest:onSyncestPullAnnotations()
    self:_runSafely("manual pull annotations", function() self:pullBookNotes(true, false, true) end, true)
end
function Syncest:onSyncestOpenLibrary()
    self:_runSafely("open library", function() self:openLibrary() end, true)
end
function Syncest:onSyncestPushBooks()
    self:_runSafely("manual push books", function() self:syncBooksLibrary("push", true) end, true)
end
function Syncest:onSyncestPullBooks()
    self:_runSafely("manual pull books", function() self:syncBooksLibrary("pull", true) end, true)
end
function Syncest:onSyncestPushStats()
    self:_runSafely("manual push stats", function() self:pushBookStats(false, true, true) end, true)
end
function Syncest:onSyncestPullStats()
    self:_runSafely("manual pull stats", function() self:pullBookStats(false, true, true) end, true)
end
function Syncest:onSyncestPushVocab()
    self:_runSafely("manual push vocab", function() self:pushVocab(false, true) end, true)
end
function Syncest:onSyncestPullVocab()
    self:_runSafely("manual pull vocab", function() self:pullVocab(false, true) end, true)
end
function Syncest:onSyncestPushAllAnnotations()
    self:_runSafely("manual push all annotations", function() self:pushAllFileAnnotations(true) end, true)
end
function Syncest:onSyncestPullAllAnnotations()
    self:_runSafely("manual pull all annotations", function() self:pullAllFileAnnotations(true) end, true)
end
function Syncest:onSyncestPushAll()
    self:pushAll(true)
end
function Syncest:onSyncestPullAll()
    self:pullAll(true)
end

function Syncest:_pushAutoSyncBundle(reason, options)
    options = options or {}
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        if not AUTO_PUSH_WEBDAV_ENABLED then
            logger.warn("Syncest " .. tostring(reason)
                .. ": auto-push WebDAV sync skipped")
            return
        end
        pcall(function()
            self:_cancelAutoPullTasks()
            self:_beginAutoNotifyBatch(20, true, "pushed")
            if options.progress then
                self:pushBookConfigAsync(true, "auto", tostring(reason))
            end
            if options.stats then
                self:pushBookStats(false, true)
            end
            if options.vocab and self._vocab_dirty then
                self._vocab_dirty = false
                self:pushVocab(false, true)
            end
            if options.annotations then
                self:pushBookNotes(false, false, true)
            end
            self:_scheduleAutoSyncBundleNotifyFlush()
        end)
    end
end

function Syncest:onCloseDocument()
    if self.x_page_push_task then
        UIManager:unschedule(self.x_page_push_task)
        self.x_page_push_task = nil
    end
    self.x_page_push_notify = nil
    local push_annotations = self.settings.auto_push_annotations_close
    if push_annotations == nil then
        push_annotations = self.settings.auto_push_annotations ~= false
    else
        push_annotations = push_annotations ~= false
    end
    self:_pushAutoSyncBundle("onCloseDocument", {
        progress = self.settings.auto_push_progress_close ~= false,
        stats = self.settings.auto_push_stats ~= false,
        vocab = self.settings.auto_push_vocab ~= false,
        annotations = push_annotations,
    })
end

function Syncest:onSuspend()
    self:_cancelResumeProgressPull()
end

function Syncest:onPause()
    self:_cancelResumeProgressPull()
end

-- Fires when a word is looked up (and potentially added to vocab builder).
-- Debounce so rapid lookups batch into one push.
function Syncest:onWordLookedUp()
    if not self.settings.auto_sync or WebDavAuth:needsSetup(self.settings) then return end
    if self.settings.auto_push_vocab == false then return end
    self._vocab_dirty = true
    if self._vocab_push_task then UIManager:unschedule(self._vocab_push_task) end
    self._vocab_push_task = function()
        self._vocab_push_task = nil
        self._vocab_dirty = false
        self:pushVocab(false, true)
    end
    UIManager:scheduleIn(2, self._vocab_push_task)
end

function Syncest:onPageUpdate(page)
    if not self.settings.auto_sync or WebDavAuth:needsSetup(self.settings) or not page then
        return
    end
    if not AUTO_PUSH_WEBDAV_ENABLED then
        logger.warn("Syncest onPageUpdate: auto progress push skipped")
        return
    end
    local should_push = false
    local notify_push = false
    if self.settings.auto_push_progress_chapter == true
            and self._last_observed_page
            and page == self._last_observed_page + 1
            and self.ui and self.ui.toc
            and self.ui.toc.isChapterStart
            and self.ui.toc:isChapterStart(page) then
        logger.info("Syncest onPageUpdate: chapter finished at page "
            .. tostring(self._last_observed_page))
        should_push = true
        notify_push = true
    end
    self._last_observed_page = page

    if self.settings.push_every_x_pages == true then
        local interval = self.settings.push_page_interval or 1
        if self._last_pushed_page == nil then
            -- ReaderReady's initial page notification establishes the
            -- baseline. It is not a page turn and must not push on book open.
            self._last_pushed_page = page
        elseif math.abs(page - self._last_pushed_page) >= interval then
            self._last_pushed_page = page
            should_push = true
        end
    end
    if should_push then
        self.x_page_push_notify = self.x_page_push_notify or notify_push
        if self.x_page_push_task then
            UIManager:unschedule(self.x_page_push_task)
        end
        self.x_page_push_task = function()
            if not self.settings.auto_sync then
                self.x_page_push_task = nil
                self.x_page_push_notify = nil
                return
            end
            if self.x_page_push_notify == true then
                local now = os.time()
                local wait_until = math.max(
                    self._suppress_auto_push_config_until or 0,
                    (self.last_sync_timestamp or 0) + API_CALL_DEBOUNCE_DELAY + 1)
                if now < wait_until then
                    logger.info("Syncest chapter progress push: delayed until "
                        .. tostring(wait_until))
                    UIManager:scheduleIn(wait_until - now, self.x_page_push_task)
                    return
                end
            end
            self.x_page_push_task = nil
            local notify = self.x_page_push_notify == true and "chapter" or false
            self.x_page_push_notify = nil
            if notify == "chapter" then
                -- Chapter changes are discrete events, so do not hold them behind
                -- the general page-turn API debounce. The background progress
                -- queue still serializes requests and keeps only the latest state.
                self:pushBookConfigAsync(notify, "auto", "chapter")
            else
                self:pushBookConfig(false, notify)
            end
        end
        UIManager:scheduleIn(
            notify_push and CHAPTER_PUSH_DELAY or PAGE_TURN_PUSH_DELAY,
            self.x_page_push_task)
    end
end

function Syncest:onAnnotationsModified(items)
    local external = items and items[1]
    logger.info("Syncest onAnnotationsModified: external="
        .. tostring(external and external.book_path or nil)
        .. " in_book=" .. tostring(self.ui.document ~= nil))
    if external and external.book_path and not self.ui.document then
        local stored_item = {
            id = external.id,
            drawer = external.drawer,
            pos0 = external.pos0,
            pos1 = external.pos1,
            text = external.highlighted_text or external.text or "",
            note = external.user_note or external.note,
            pageno = external.page,
            datetime = external.datetime,
        }
        local file_ui = open_file_annotation_ui(external.book_path)
        local still_present = false
        for _, item in ipairs(file_ui and file_ui.annotation.annotations or {}) do
            if (stored_item.pos0 and tostring(item.pos0) == tostring(stored_item.pos0))
                    or (item.datetime == stored_item.datetime
                        and item.text == stored_item.text) then
                still_present = true
                break
            end
        end
        if self.settings.auto_sync
                and self.settings.auto_push_annotations ~= false
                and not WebDavAuth:needsSetup(self.settings) then
            self._file_annotations_push_tasks =
                self._file_annotations_push_tasks or {}
            local old_task = self._file_annotations_push_tasks[external.book_path]
            if old_task then
                UIManager:unschedule(old_task)
            end
            local file = external.book_path
            local deleted_item = not still_present and stored_item or nil
            if deleted_item and file_ui and file_ui.doc_settings
                    and file_ui.doc_settings:readSetting("partial_md5_checksum") then
                -- Persist the tombstone so a failed first attempt can rebuild
                -- it during the later reconnect flush.
                SyncAnnotations:recordDeletion(file_ui.doc_settings, deleted_item)
                deleted_item = nil
            end
            local task
            task = function()
                self._file_annotations_push_tasks[file] = nil
                self:pushFileAnnotations(file, true, deleted_item)
            end
            self._file_annotations_push_tasks[file] = task
            UIManager:scheduleIn(1, task)
        end
        return
    end
    local external_reader_change = external and external.book_path
        and self.ui.document ~= nil
    if external_reader_change then
        local stored_item = {
            id = external.id,
            drawer = external.drawer,
            pos0 = external.pos0,
            pos1 = external.pos1,
            text = external.highlighted_text or external.text or "",
            note = external.user_note or external.note,
            pageno = external.page,
            datetime = external.datetime,
        }
        local still_present = false
        for _, item in ipairs(self.ui.annotation
                and self.ui.annotation.annotations or {}) do
            if (stored_item.pos0
                    and tostring(item.pos0) == tostring(stored_item.pos0))
                    or (item.datetime == stored_item.datetime
                        and item.text == stored_item.text) then
                still_present = true
                break
            end
        end
        if not still_present then
            SyncAnnotations:recordDeletion(self.ui.doc_settings, stored_item)
        end
    end
    if not WebDavAuth:needsSetup(self.settings) and items
            and items.index_modified and items.index_modified < 0 and items[1] then
        SyncAnnotations:recordDeletion(self.ui.doc_settings, items[1])
    end
    if self.settings.auto_sync and self.settings.auto_push_annotations ~= false
            and not WebDavAuth:needsSetup(self.settings) then
        if self._annotations_push_task then
            UIManager:unschedule(self._annotations_push_task)
        end
        self._annotations_push_task = function()
            self._annotations_push_task = nil
            self:pushBookNotes(false, external_reader_change == true, true)
        end
        UIManager:scheduleIn(1, self._annotations_push_task)
    end
end

function Syncest:onCloseWidget()
    self:_cancelAutoPullTasks()
    if self.delayed_push_task then
        UIManager:unschedule(self.delayed_push_task)
        self.delayed_push_task = nil
    end
    if self.x_page_push_task then
        UIManager:unschedule(self.x_page_push_task)
        self.x_page_push_task = nil
    end
    if self._vocab_push_task then
        UIManager:unschedule(self._vocab_push_task)
        self._vocab_push_task = nil
    end
    if self._annotations_push_task then
        UIManager:unschedule(self._annotations_push_task)
        self._annotations_push_task = nil
    end
    for _, task in pairs(self._file_annotations_push_tasks or {}) do
        UIManager:unschedule(task)
    end
    self._file_annotations_push_tasks = nil
    if self._failure_notify_task then
        UIManager:unschedule(self._failure_notify_task)
        self._failure_notify_task = nil
    end
end

function Syncest:deletePluginSettings()
    G_reader_settings:delSetting("webdav_sync")
    self.settings = self.default_settings
    return true
end

require("syncest_insert_menu")

return Syncest
