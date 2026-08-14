local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage  = require("ui/widget/infomessage")
local UIManager    = require("ui/uimanager")
local T            = require("ffi/util").template
local _            = require("gettext")

local WebDavAuth = {}

function WebDavAuth:needsSetup(settings)
    return not settings.sync_server
end

function WebDavAuth:getUserId(settings)
    if not settings.sync_server then return nil end
    local s = settings.sync_server
    return (s.username or "") .. "@" .. (s.address or "")
end

function WebDavAuth:getClient(settings)
    if self:needsSetup(settings) then return nil end
    local WebDavSyncClient = require("webdav_syncclient")
    return WebDavSyncClient:new{ server = settings.sync_server }
end

function WebDavAuth:setup(settings, touchmenu_instance, ui)
    local server = settings.sync_server

    -- KOReader 2026.07 replaced SyncService with the Cloud storage plugin.
    -- Prefer its public picker API, but retain compatibility with older builds.
    local cloud_storage = ui and ui.cloudstorage
    local SyncService
    if not cloud_storage then
        local ok, service = pcall(require, "apps/cloudstorage/syncservice")
        if ok then
            SyncService = service
        end
    end

    local function save_server(sv)
        settings.sync_server = sv
        settings.user_id   = self:getUserId(settings)
        settings.user_name = sv.name or sv.username
        G_reader_settings:saveSetting("webdav_sync", settings)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(InfoMessage:new{
            text = _("Syncest configured: ") .. (sv.name or sv.address),
            timeout = 2,
        })
    end

    local function open_picker()
        if cloud_storage then
            cloud_storage:onShowCloudStorageList(save_server)
            return
        end
        if not SyncService then
            UIManager:show(InfoMessage:new{
                text = _("Cloud storage is unavailable. Enable the Cloud storage plugin and restart KOReader."),
            })
            return
        end
        local sync_settings = SyncService:new{}
        sync_settings.onClose = function(this)
            UIManager:close(this)
        end
        sync_settings.onConfirm = function(sv)
            save_server(sv)
        end
        UIManager:show(sync_settings)
    end

    if not server then
        open_picker()
        return
    end

    -- Already configured — show info + edit/delete options (same as highlightsync)
    local server_type = server.type == "dropbox" and " (Dropbox)" or " (WebDAV)"
    local dialogue
    dialogue = ButtonDialog:new{
        title = T(_("Cloud storage:\n%1\n\nFolder path:\n%2"),
            (server.name or "") .. server_type,
            cloud_storage and cloud_storage.getReadablePath(server)
                or SyncService and SyncService.getReadablePath(server)
                or server.url or server.address or ""),
        buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialogue)
                        settings.sync_server = nil
                        settings.user_id     = nil
                        settings.user_name   = nil
                        G_reader_settings:saveSetting("webdav_sync", settings)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialogue)
                        open_picker()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialogue)
                    end,
                },
            },
        },
    }
    UIManager:show(dialogue)
end

function WebDavAuth:disconnect(settings, touchmenu_instance)
    settings.sync_server = nil
    settings.user_id     = nil
    settings.user_name   = nil
    G_reader_settings:saveSetting("webdav_sync", settings)
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

return WebDavAuth
