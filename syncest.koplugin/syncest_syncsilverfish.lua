--[[--
Silverfish (silverfish.koplugin, plugin name "traca") pet sync.

The pet is one evolving state, so it is not merged field by field: the
"most-fed" copy wins (see SyncSilverfish.better). The state travels as
KOReader's own Lua serialization (dump) inside silverfish.json, so its
nested tables round-trip exactly.

Everything here is a no-op when Silverfish is not installed or is disabled.
]]

local DataStorage = require("datastorage")
local dump = require("dump")
local logger = require("logger")

local SyncSilverfish = {}

SyncSilverfish.FILE = "silverfish.json"
SyncSilverfish.FORMAT = 1

local PLUGIN_NAME = "traca"

-- ── Discovery ──────────────────────────────────────────────────────

--- The running Silverfish plugin instance (reader if a book is open, else file manager), or nil.
function SyncSilverfish.instance()
    for _, mod in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local ok, App = pcall(require, mod)
        local ui = ok and App and App.instance
        local traca = ui and ui[PLUGIN_NAME]
        if type(traca) == "table" and type(traca.estado) == "table" then return traca end
    end
end

--- Silverfish is installed and enabled.
function SyncSilverfish.installed()
    local disabled = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled[PLUGIN_NAME] then return false end
    if SyncSilverfish.instance() then return true end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return false end
    return lfs.attributes(DataStorage:getDataDir() .. "/plugins/silverfish.koplugin", "mode") == "directory"
end

-- ── Snapshot ───────────────────────────────────────────────────────

local function summary(estado)
    return {
        geracao    = tonumber(estado.geracao) or 1,
        letras     = tonumber(estado.letras) or 0,
        nascimento = tonumber(estado.nascimento) or 0,
        atualizado = tonumber(estado.atualizado) or 0,
    }
end

local function load_lua(s)
    if type(s) ~= "string" or s == "" then return nil end
    local fn = loadstring("return " .. s)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, v = pcall(fn)
    if ok and type(v) == "table" then return v end
end

--- The local pet, ready to push: { summary, estado, ninhada, ... }.
-- Taken from the running plugin (freshest), else from settings/traca.lua.
-- nil when there is nothing to sync or Silverfish is in its demo simulation.
function SyncSilverfish.snapshot()
    local estado, ninhada
    local traca = SyncSilverfish.instance()
    if traca then
        if type(traca.emSimulacao) == "function" and traca:emSimulacao() then return nil end
        estado, ninhada = traca.estado, traca.ninhada
    else
        local ok, db = pcall(function()
            return require("luasettings"):open(DataStorage:getSettingsDir() .. "/traca.lua")
        end)
        if not ok or not db or db:readSetting("estado_real") ~= nil then return nil end
        estado, ninhada = db:readSetting("estado"), db:readSetting("ninhada")
    end
    if type(estado) ~= "table" or estado.dev_simulacao then return nil end
    local Device = require("device")
    return {
        format    = SyncSilverfish.FORMAT,
        summary   = summary(estado),
        estado    = dump(estado),
        ninhada   = type(ninhada) == "table" and dump(ninhada) or nil,
        device    = Device.model or "?",
        pushed_at = os.time(),
    }
end

-- ── Most-fed wins ──────────────────────────────────────────────────

--- true when pet summary `a` should replace `b`: later generation, then more letters eaten.
-- Same pet and same letters: the more recently updated copy. Different pets tied: the older pet,
-- so a fresh egg on a new device never replaces an existing one.
function SyncSilverfish.better(a, b)
    if type(a) ~= "table" then return false end
    if type(b) ~= "table" then return true end
    local ag, bg = tonumber(a.geracao) or 1, tonumber(b.geracao) or 1
    if ag ~= bg then return ag > bg end
    local al, bl = tonumber(a.letras) or 0, tonumber(b.letras) or 0
    if al ~= bl then return al > bl end
    local an, bn = tonumber(a.nascimento) or 0, tonumber(b.nascimento) or 0
    if an == bn then return (tonumber(a.atualizado) or 0) > (tonumber(b.atualizado) or 0) end
    return an < bn
end

--- Remote copy beats the local pet? (false when there is no local Silverfish state to compare.)
function SyncSilverfish.remoteWins(remote)
    if type(remote) ~= "table" or remote.format ~= SyncSilverfish.FORMAT then return false end
    local mine = SyncSilverfish.snapshot()
    if not mine then return false end
    -- same pet, same progress: nothing to do (only time has passed on one side)
    local r, m = remote.summary or {}, mine.summary
    if r.nascimento == m.nascimento and r.geracao == m.geracao and r.letras == m.letras then return false end
    return SyncSilverfish.better(r, m)
end

--- Replace the local pet with `remote`. Returns true when applied.
function SyncSilverfish.apply(remote)
    local estado = load_lua(remote and remote.estado)
    if not estado then
        logger.warn("Syncest Silverfish: remote state unreadable")
        return false
    end
    local ninhada = load_lua(remote.ninhada)
    local agora = os.time()
    local okE, Estado = pcall(require, "traca_estado")
    local okB, Brood = pcall(require, "traca_brood")
    local traca = SyncSilverfish.instance()
    if traca and okE and okB then
        estado = Estado.normalizar(estado, agora)
        Estado.passarTempo(estado, agora)
        traca.estado = estado
        traca.ninhada = Brood.normalize(ninhada, agora)
        traca:salvar(true)
    else
        -- no running Silverfish (should not happen when installed): write its file directly
        local db = require("luasettings"):open(DataStorage:getSettingsDir() .. "/traca.lua")
        db:saveSetting("estado", estado)
        if ninhada then db:saveSetting("ninhada", ninhada) else db:delSetting("ninhada") end
        db:flush()
    end
    logger.info("Syncest Silverfish: adopted pet from", tostring(remote.device),
        "letters", tostring(remote.summary and remote.summary.letras))
    return true
end

return SyncSilverfish
