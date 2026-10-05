#!/usr/bin/env python3
"""Deterministic LuaJIT model regression and synthetic API-call benchmark.

Run: PYTHONPATH=.tools python3 tests/runtime_regression.py
Install test dependency: python3 -m pip install --target .tools lupa==2.8
No Assetto Corsa/CSP runtime or real-game FPS is simulated here.
"""
import argparse
import math
from pathlib import Path
import statistics
import subprocess

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
APP = Path('ACNextGen_Enhanced_Physic/assettocorsa/apps/lua/ACNextGen')
BASELINE = '539f916'

FIXTURE = r'''
store = {}
calls = {load=0, store=0, field=0}
logs = {}
local strict = STRICT
local function object(values)
    if not strict then return values end
    return setmetatable({}, {__index=function(_, key)
        calls.field = calls.field + 1
        if values[key] == nil then error('unsupported CSP field: ' .. tostring(key)) end
        return values[key]
    end, __newindex=function(_, key, value) values[key] = value end})
end
function vector(x, y, z)
    return object({x=x, y=y, z=z, length=function(v)
        return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
    end})
end
wheels = {}
for i=0,3 do
    wheels[i] = object({load=3500, loadK=3.5, slipRatio=0, slipAngle=0,
        angularSpeed=50, suspensionTravel=0.04, tyreRadius=0.33,
        tyreCoreTemperature=80, tyreTemperature=85, brakeTemperature=150,
        camber=-0.02, toe=0.001, isInContact=true,
        contactPoint=vector((i%2)*1.5-0.75, 0, i<2 and 1.3 or -1.3)})
end
car = object({wheels=wheels, speedKmh=60, rpm=3500, gear=3, gas=0.4,
    brake=0, clutch=1, handbrake=0, steer=0, mass=1400,
    localVelocity=vector(0,0,16.7), velocity=vector(0,0,16.7),
    localAngularVelocity=vector(0,0,0), acceleration=vector(0,0,0),
    localAcceleration=vector(0,0,0), gForces=vector(0,1,0),
    position=vector(0,0,0), look=vector(0,0,1), side=vector(1,0,0),
    up=vector(0,1,0), damage={0,0,0,0,0}, fuel=30, turboBoost=0,
    engineLifeLeft=1000})
carAvailable = true
ac = {
    load=function(key) calls.load=calls.load+1; return store[key] end,
    store=function(key, value) calls.store=calls.store+1; store[key]=value end,
    log=function(value) logs[#logs+1]=value end,
    getCar=function() return carAvailable and car or nil end,
    getCarID=function() return 'regression_fixture' end,
    getCarConfig=function() return nil end,
    getSim=function() return {ambientTemperature=25, roadTemperature=30} end
}
ui = {text=function() end, separator=function() end}
function scenario(frame, dt)
    local t = frame * dt
    local speed = 85 + 60*math.sin(t*0.31)
    car.speedKmh = speed
    car.rpm = 3500 + 1700*math.sin(t*0.7)
    car.gear = 2 + math.floor(frame/150)%4
    car.gas = math.max(0, 0.6*math.sin(t*0.6)+0.3)
    car.brake = math.max(0, -math.sin(t*0.6))*0.8
    car.steer = 0.5*math.sin(t*1.1)
    car.handbrake = frame%500>480 and 0.6 or 0
    car.clutch = frame%150<8 and 0.2 or 1
    car.localVelocity.z = speed/3.6
    car.localVelocity.x = math.sin(t)*1.2
    car.velocity.z = speed/3.6
    car.localAngularVelocity.y = 0.4*math.sin(t*1.1)
    car.gForces.x = 0.8*math.sin(t*1.1)
    car.gForces.z = 0.5*math.sin(t*0.6)
    for i=0,3 do
        local w = wheels[i]
        w.load = 3500+1400*math.sin(t*1.1+i)+400*math.sin(t*21+i)
        w.suspensionTravel = 0.04+0.02*math.sin(t*7+i)
        w.slipAngle = 0.13*math.sin(t*2+i*0.2)
        w.slipRatio = 0.25*math.sin(t*1.3+i*0.3)
        w.angularSpeed = speed/3.6/0.33*(1+w.slipRatio)
        w.brakeTemperature = 150+400*car.brake
        w.tyreCoreTemperature = 75+15*math.sin(t*0.15)
        w.isInContact = frame%280<265
        if not w.isInContact then w.load=0 end
    end
    -- Missing car, partial wheels, a session stall and recovery.
    carAvailable = not (frame>=420 and frame<440)
    if frame>=700 and frame<705 then car.wheels=nil else car.wheels=wheels end
end
local function append(out, prefix, value, seen)
    local kind = type(value)
    if kind == 'number' or kind == 'boolean' or kind == 'string' then
        out[prefix] = value
    elseif kind == 'table' and not seen[value] then
        seen[value] = true
        for k,v in pairs(value) do append(out, prefix .. '.' .. tostring(k), v, seen) end
        seen[value] = nil
    end
end
function snapshot()
    local out = {}
    local core = package.loaded['modules.ngp_core']
    local values = core and core.signals or store
    for k,v in pairs(values) do
        if not k:match('^ngp_prof_') and not k:match('^ngp_runtime_') then out['signal.'..k] = v end
    end
    for name, m in pairs(package.loaded) do
        if type(m)=='table' and name:match('^modules%.') then
            append(out, name..'.state', m.state, {})
            if m.debug ~= m.state then append(out, name..'.debug', m.debug, {}) end
            append(out, name..'.force', m.lastForce, {})
        end
    end
    for i=1,100 do
        local name, value = debug.getupvalue(update, i)
        if name == nil then break end
        if name == 'runtime' then
            out['runtime.loadedCount'] = value.loadedCount
            out['runtime.enabledCount'] = value.enabledCount
            out['runtime.activeErrorCount'] = value.activeErrorCount
            out['runtime.totalErrorCount'] = value.totalErrorCount
            append(out, 'runtime.moduleStatus', value.moduleStatus, {})
            break
        end
    end
    return out
end
function drive(frames, dt, withUI)
    local t0 = os.clock()
    for f=1,frames do
        scenario(f,dt)
        update(f%997==0 and 0.3 or dt)
        if withUI then windowMain() end
    end
    return (os.clock()-t0)*1000/frames
end
'''


def sources(revision=None):
    if revision:
        names = subprocess.check_output(
            ['git', 'ls-tree', '-r', '--name-only', revision, str(APP)], cwd=ROOT, text=True
        ).splitlines()
        return {str(Path(n).relative_to(APP)): subprocess.check_output(
            ['git', 'show', f'{revision}:{n}'], cwd=ROOT, text=True
        ) for n in names if n.endswith('.lua')}
    return {str(p.relative_to(ROOT / APP)): p.read_text()
            for p in (ROOT / APP).rglob('*.lua')}


def runtime(src, strict=True):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().STRICT = strict
    lua.execute(FIXTURE)
    for name, source in src.items():
        if name == 'ACNextGen.lua':
            continue
        module = name.removesuffix('.lua').replace('/', '.')
        lua.execute('package.preload[...] = assert(loadstring(select(2, ...)))', module, source)
    lua.execute(src['ACNextGen.lua'])
    return lua


def regression(original, optimized, frames, stride=5):
    comparisons = 0
    cases = [('balanced', strict, hz) for strict in (False, True)
             for hz in (30, 70, 100, 160)] + [('compatible', True, 100)]
    for mode, strict, hz in cases:
        candidate = dict(optimized)
        if mode == 'compatible' and 'mode = "balanced"' in candidate['modules/ngp_core.lua']:
            candidate['modules/ngp_core.lua'] = candidate['modules/ngp_core.lua'].replace(
                'mode = "balanced"', 'mode = "compatible"', 1)
        a, b = runtime(original, strict), runtime(candidate, strict)
        for frame in range(1, frames + 1):
            dt = 1 / hz
            for vm in (a, b):
                vm.globals().scenario(frame, dt)
                vm.globals().update(0.3 if frame % 997 == 0 else dt)
                if frame % 17 == 0:
                    vm.globals().windowMain()
            # Every update runs; inspect all states/signals on the first 30
            # frames, at transitions, and at the configured sample stride.
            if (frame > 30 and frame % stride and frame != frames
                    and frame not in (419, 420, 439, 440, 699, 700, 704, 705, 996, 997, 998)):
                continue
            left = dict(a.globals().snapshot())
            right = dict(b.globals().snapshot())
            assert left.keys() == right.keys(), (strict, hz, frame,
                'missing', left.keys()-right.keys(), 'extra', right.keys()-left.keys())
            for key, value in left.items():
                other = right[key]
                if isinstance(value, (float, int)) and not isinstance(value, bool):
                    assert math.isfinite(value) and math.isfinite(other), (key, value, other)
                    assert math.isclose(value, other, rel_tol=1e-12, abs_tol=1e-12), (
                        strict, hz, frame, key, value, other)
                else:
                    assert value == other, (strict, hz, frame, key, value, other)
                comparisons += 1
        print(f'PASS regression mode={mode} strict={strict} render_hz={hz} frames={frames}', flush=True)
    print(f'PASS {comparisons:,} scalar comparisons (absolute/relative tolerance 1e-12)')


def benchmark(src, frames, repeat, strict=True):
    timings, counts = [], []
    for _ in range(repeat):
        vm = runtime(src, strict)
        vm.globals().drive(400, 1/100, True)
        vm.execute('calls.load=0; calls.store=0; calls.field=0; collectgarbage("collect")')
        timings.append(vm.globals().drive(frames, 1/100, True))
        counts.append(dict(vm.globals().calls))
    return statistics.median(timings), counts[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default=BASELINE)
    parser.add_argument('--frames', type=int, default=1100)
    parser.add_argument('--bench-frames', type=int, default=3000)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--snapshot-stride', type=int, default=5)
    parser.add_argument('--benchmark-only', action='store_true')
    args = parser.parse_args()
    original, optimized = sources(args.baseline), sources()
    for src in (original, optimized):
        vm = LuaRuntime()
        for name, source in src.items():
            vm.execute('assert(loadstring(...))', source)
    print('PASS Lua 5.1/LuaJIT syntax for all files', flush=True)
    if not args.benchmark_only:
        if 'signals' in optimized['modules/ngp_core.lua']:
            vm = LuaRuntime()
            vm.execute(FIXTURE)
            vm.execute('package.preload["modules.ngp_core"] = assert(loadstring(...))',
                       optimized['modules/ngp_core.lua'])
            vm.execute((ROOT / 'tests/transport_spec.lua').read_text())
        regression(original, optimized, args.frames, max(1, args.snapshot_stride))
    for strict in (False, True):
        for name, src in (('baseline', original), ('candidate', optimized)):
            ms, counts = benchmark(src, args.bench_frames, args.repeat, strict)
            print(f'{name} strict={strict}: median {ms:.4f} ms/frame; '
                  f'native mock API calls {counts}', flush=True)
    print('Synthetic CPU timing only; not CSP performance or game FPS.')


if __name__ == '__main__':
    main()
