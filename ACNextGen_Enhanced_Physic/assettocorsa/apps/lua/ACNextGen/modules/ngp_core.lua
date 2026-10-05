-- ngp_core.lua
-- Shared helpers for ACNextGen V1.1

local M = {}

M.version = "1.1.7-lightweight-core"

local lastStore = {}

-- The models communicate in-process, not through CSP's persistent store.
-- Only presentation/export is decimated; model rates and equations are unchanged.
-- Set mode = "compatible" if an external script consumes/writes ngp_* keys
-- at simulation frequency, or if comparing native store behavior with the original.
M.performance = {
    mode = "balanced",
    exportInterval = 0.10,
    exportBudget = 256,
}

M.signals = {}
local owned, records, keys = {}, {}, {}
local externalValues, externalEpoch = {}, {}
local fieldCache = setmetatable({}, { __mode = "k" })
local epoch, simulationTime, cursor = 0, 0.0, 1
local inFrame = false
local NIL = {}
M.transport = { nativeLoads = 0, nativeStores = 0, exportErrors = 0 }

local function readField(object, field)
    return object[field]
end

-- Shared reader: no closure per access, and only one protected read per
-- object/field/update. Unsupported strict CSP struct fields remain safe.
-- Cache lifetime is one update, never one vehicle/session; UI reads stay live.
function M.safeField(object, field, fallback)
    if not object or field == nil then return fallback end
    local row, stamp
    if inFrame then
        row = fieldCache[object]
        if not row then
            row = { values = {}, stamps = {} }
            fieldCache[object] = row
        end
        stamp = row.stamps[field]
        if stamp == epoch then
            local value = row.values[field]
            if value == NIL then return fallback end
            return value
        end
    end
    local ok, value = pcall(readField, object, field)
    if not ok or value == nil then value = NIL end
    if row then
        row.values[field] = value
        row.stamps[field] = epoch
    end
    if value == NIL then return fallback end
    return value
end

function M.beginFrame(dt)
    epoch = epoch + 1
    simulationTime = simulationTime + dt
    inFrame = true
end

function M.endFrame()
    inFrame = false
end

function M.safeLoadRaw(key)
    if key == nil then return nil end
    if M.performance.mode ~= "compatible" then
        if owned[key] then return M.signals[key] end
        if inFrame and externalEpoch[key] == epoch then
            local value = externalValues[key]
            if value == NIL then return nil end
            return value
        end
    end
    if not ac or not ac.load then return nil end
    M.transport.nativeLoads = M.transport.nativeLoads + 1
    local ok, value = pcall(ac.load, key)
    if not ok then return nil end
    if inFrame and M.performance.mode ~= "compatible" then
        externalEpoch[key] = epoch
        externalValues[key] = value == nil and NIL or value
    end
    return value
end

local function exportValue(key, value)
    if not ac or not ac.store then return false end
    M.transport.nativeStores = M.transport.nativeStores + 1
    local ok = pcall(ac.store, key, value)
    if not ok then M.transport.exportErrors = M.transport.exportErrors + 1 end
    return ok
end

-- Flush in round-robin order with a hard API-call cap: no 2000-key export
-- spike on a single frame, no catch-up burst after pause, no repeated stable
-- values. Failed native writes remain dirty and retry on a later pass.
function M.flush(force)
    local count = #keys
    if count == 0 then return end
    local budget = force and count or M.performance.exportBudget
    local written, scanned = 0, 0
    while scanned < count and written < budget do
        if cursor > count then cursor = 1 end
        local key = keys[cursor]
        local record = records[key]
        cursor = cursor + 1
        scanned = scanned + 1
        if record.dirty and (force or simulationTime - record.lastExport >= M.performance.exportInterval) then
            written = written + 1
            if exportValue(key, M.signals[key]) then
                record.dirty = false
                record.lastExport = simulationTime
            end
        end
    end
end


function M.num(v, fallback)
    local n = tonumber(v)
    if n == nil then return fallback or 0 end
    if n ~= n then return fallback or 0 end
    return n
end

function M.bool01(v)
    return v and 1 or 0
end

function M.clamp(v, a, b)
    v = M.num(v, a)
    if v < a then return a end
    if v > b then return b end
    return v
end

function M.abs(v)
    v = M.num(v, 0)
    if v < 0 then return -v end
    return v
end

function M.sign(v)
    v = M.num(v, 0)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

function M.lerp(a, b, t)
    t = M.clamp(t, 0, 1)
    return a + (b - a) * t
end

function M.invLerp(a, b, v)
    if a == b then return 0 end
    return M.clamp((v - a) / (b - a), 0, 1)
end

function M.lowPass(current, target, dt, tau)
    current = M.num(current, 0)
    target = M.num(target, 0)
    dt = M.num(dt, 0)
    tau = math.max(M.num(tau, 0.05), 0.0001)

    local a = dt / (tau + dt)
    return current + (target - current) * M.clamp(a, 0, 1)
end

function M.approach(current, target, step)
    current = M.num(current, 0)
    target = M.num(target, 0)
    step = math.max(M.num(step, 0), 0)

    if current < target then
        return math.min(current + step, target)
    elseif current > target then
        return math.max(current - step, target)
    end

    return target
end

function M.safeStore(key, value)
    if key == nil or not ac or not ac.store then return false end
    M.signals[key] = value
    if not owned[key] then
        owned[key] = true
        keys[#keys + 1] = key
        records[key] = { dirty = true, lastExport = -math.huge, lastValue = NIL }
    end
    local record = records[key]
    local comparable = value == nil and NIL or value
    if record.lastValue ~= comparable then
        record.lastValue = comparable
        record.dirty = true
    end
    if M.performance.mode == "compatible" then
        local ok = exportValue(key, value)
        if ok then
            record.dirty = false
            record.lastExport = simulationTime
        end
        return ok
    end
    return true
end

function M.safeLoad(key, fallback)
    local value = M.safeLoadRaw(key)
    if value == nil then return fallback end
    return value
end

function M.storeInterval(key, value, interval)
    interval = interval or 0.10

    local now = 0
    pcall(function()
        now = os.clock()
    end)

    if now <= 0 then
        M.safeStore(key, value)
        return true
    end

    local last = lastStore[key] or 0
    if now - last >= interval then
        lastStore[key] = now
        M.safeStore(key, value)
        return true
    end

    return false
end

function M.getCar()
    local ok, car = pcall(function()
        return ac.getCar(0)
    end)

    if ok and car then
        return car
    end

    return nil
end

function M.getWheel(car, i)
    if not car then return nil end
    if not car.wheels then return nil end

    local ok, w = pcall(function()
        return car.wheels[i]
    end)

    if ok then return w end
    return nil
end

function M.wheelValue(car, i, key, fallback)
    local w = M.getWheel(car, i)
    if not w then return fallback or 0 end

    local ok, v = pcall(function()
        return w[key]
    end)

    if ok and v ~= nil then
        return M.num(v, fallback or 0)
    end

    return fallback or 0
end

function M.carValue(car, key, fallback)
    if not car then return fallback or 0 end

    local ok, v = pcall(function()
        return car[key]
    end)

    if ok and v ~= nil then
        return M.num(v, fallback or 0)
    end

    return fallback or 0
end

function M.speedKmh(car)
    if not car then return 0 end

    local ok, v = pcall(function()
        return car.speedKmh
    end)

    if ok and v ~= nil then
        return M.num(v, 0)
    end

    local vel = car.velocity
    if vel and vel.length then
        return M.num(vel:length(), 0) * 3.6
    end

    return 0
end

function M.setModuleStatus(name, ok, err)
    if not name then return end

    local prefix = "ngp_mod_" .. name

    M.safeStore(prefix .. "_ok", ok and 1 or 0)

    if err then
        M.safeStore(prefix .. "_err", tostring(err))
    elseif ok then
        M.safeStore(prefix .. "_err", "")
    end
end

function M.moduleAlive(name)
    if not name then return end
    M.safeStore("ngp_mod_" .. name .. "_alive", 1)
end

-- Boundaries keep the small model traces from repeatedly inlining the same
-- highly polymorphic signal/struct helpers. Without these, LuaJIT can spend
-- more time recording/aborting traces than running the models. This affects
-- only these four transport helpers, never the engine/global JIT settings.
if jit and jit.off then
    -- Some sandbox configurations restrict JIT control; remain functional.
    pcall(jit.off, M.safeStore)
    pcall(jit.off, M.safeLoadRaw)
    pcall(jit.off, M.safeField)
    pcall(jit.off, M.flush)
end

return M