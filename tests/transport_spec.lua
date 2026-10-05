-- Run by runtime_regression.py in a fresh LuaJIT VM with mocked CSP APIs.
local core = require('modules.ngp_core')
local function frame(dt)
    core.endFrame()
    core.beginFrame(dt or 0.01)
end

-- False, zero, empty strings, missing keys and clearing a signal are distinct.
assert(core.safeLoadRaw('missing') == nil)
assert(core.safeLoad('missing', 42) == 42)
for key, value in pairs({ zero=0, flag=false, text='' }) do
    assert(core.safeStore(key, value))
    assert(core.safeLoadRaw(key) == value)
end
core.safeStore('cleared', 1)
core.safeStore('cleared', nil)
assert(core.safeLoadRaw('cleared') == nil)
assert(core.safeStore(nil, 1) == false)

-- Unknown/external inputs refresh each frame, including a previous miss.
frame()
local loads = calls.load
assert(core.safeLoadRaw('external') == nil)
assert(core.safeLoadRaw('external') == nil)
assert(calls.load == loads + 1)
store.external = 7
frame()
assert(core.safeLoadRaw('external') == 7)
-- A local write wins immediately even after a cached external lookup.
core.safeStore('external', 9)
assert(core.safeLoadRaw('external') == 9)

-- Live outside update; once per frame inside update; never cache a fallback.
local reads = 0
local backing = { value=2, flag=false }
local obj = setmetatable({}, { __index=function(_, key)
    reads=reads+1
    if backing[key] == nil then error('unsupported field') end
    return backing[key]
end })
frame()
assert(core.safeField(obj, 'value', 0) == 2)
assert(core.safeField(obj, 'value', 0) == 2)
assert(reads == 1)
assert(core.safeField(obj, 'absent', 11) == 11)
assert(core.safeField(obj, 'absent', 22) == 22)
assert(reads == 2)
assert(core.safeField(obj, 'flag', true) == false)
backing.value = 3
frame()
assert(core.safeField(obj, 'value', 0) == 3)
core.endFrame()
backing.value = 4
assert(core.safeField(obj, 'value', 0) == 4)
backing.value = 5
assert(core.safeField(obj, 'value', 0) == 5)
assert(core.safeField(nil, 'value', 23) == 23)
assert(core.safeField(obj, nil, 24) == 24)

-- Real FFI cdata (CSP uses strict structs), unsupported field and pointer.
local ffi = require('ffi')
ffi.cdef('typedef struct { double load; double slipRatio; } TestWheel;')
local wheel = ffi.new('TestWheel', { 3500, 0.15 })
frame()
assert(core.safeField(wheel, 'load', 0) == 3500)
assert(core.safeField(wheel, 'notInStruct', 12) == 12)
assert(core.safeField(wheel, 'notInStruct', 13) == 13)
wheel.load = 4200
frame()
assert(core.safeField(wheel, 'load', 0) == 4200)
core.endFrame()
assert(core.safeField(ffi.cast('TestWheel*', wheel), 'load', 0) == 4200)

-- Hard native-write budget and fair eventual export of all keys.
core.performance.exportBudget = 3
for i=1,20 do core.safeStore('budget_'..i, i) end
local writes = calls.store
core.flush()
assert(calls.store-writes <= 3)
for _=1,20 do frame(0.1); core.endFrame(); core.flush() end
for i=1,20 do assert(store['budget_'..i] == i) end
core.flush(true)
writes = calls.store
core.flush(true)
assert(calls.store == writes) -- stable values do not write again

-- Failure remains dirty; retry succeeds; counters expose failures.
local nativeStore = ac.store
ac.store = function() error('storage unavailable') end
core.safeStore('retry', 41)
core.flush(true)
assert(store.retry == nil)
assert(core.transport.exportErrors > 0)
assert(core.safeLoadRaw('retry') == 41) -- models remain connected
ac.store = nativeStore
core.flush(true)
assert(store.retry == 41)
local nativeLoad = ac.load
ac.load = function() error('load unavailable') end
frame()
assert(core.safeLoad('unavailable', 15) == 15)
core.endFrame()
ac.load = nativeLoad

-- Compatible mode preserves immediate native calls and external overrides.
core.performance.mode = 'compatible'
assert(core.safeStore('compat', 5))
assert(store.compat == 5)
store.compat = 8
assert(core.safeLoadRaw('compat') == 8)
assert(core.safeLoadRaw('flag') == false)
ac.store = function() error('native store failure') end
assert(core.safeStore('compat', 10) == false)
assert(core.safeLoadRaw('compat') == 8)
ac.store = nativeStore
core.flush(true)
assert(store.compat == 10)

-- A local tracing boundary must not disable the rest of the simulator's JIT.
assert(jit.status())
local nativeJit = jit
jit = { off=function() error('JIT control restricted by sandbox') end }
package.loaded['modules.ngp_core'] = nil
assert(require('modules.ngp_core').safeLoad('missing', 99) == 99)
jit = nil
package.loaded['modules.ngp_core'] = nil
assert(require('modules.ngp_core').safeLoad('missing', 98) == 98)
jit = nativeJit
print('PASS transport: defaults, FFI structs, cache lifetime, external inputs, budget, retry, compatibility, restricted JIT')
