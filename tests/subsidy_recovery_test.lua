-- Runs our simulation adapter around the installed game's real subsidy script.
-- Native command delivery/save serialization still require real-game UAT.
local tealDir = assert(os.getenv('TEAL_DIR'), 'Set TEAL_DIR')
local nativeDir = assert(os.getenv('TF3_SUBVENTIONS_DIR'), 'Set TF3_SUBVENTIONS_DIR to extracted game_mechanics/subventions')
package.path = tealDir .. '/?.lua;' .. package.path
local tl = require('teal.api.v2')
local function compiled(path, env)
    local file = assert(io.open(path)); local code, result = tl.gen(file:read('*a')); file:close()
    assert(code and #result.syntax_errors == 0)
    return assert(load(code, path, 't', env))()
end
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}; for k, child in pairs(v) do out[k] = copy(child) end; return out
end
local time, payments, transient, sent, subs = 100, 0, false, {}, {}
local kind = '::/game_mechanics/subventions/deliver_workers/deliver_workers.res'
local function offer(uid, name)
    return {id = name or kind, uid = uid, spawnTime = time - 50,
        data = {name = 'Original contract', expireDurationProposed = 100, expireDuration = 200,
            effectDuration = 300, target = 77, revision = 4, toDeliver = 25, delivered = 0,
            upfront = {{type = 'Money', params = {amount = 34567}}},
            complete = {{type = 'Money', params = {amount = 98765}}}}}
end
local function world(offers)
    return {proposedSubventions = offers or {}, activeSubventions = {}, completedSubventions = {}, failedSubventions = {},
        usedUids = {[kind] = {}}, version = 1, lastSpawnTime = 100, spawnIntervalModifier = 1}
end
local data = world()
local state = {
    get = function() return copy(data) end,
    set = function(_, value) data = copy(value) end,
    hasEventSubscriptions = function() return next(subs) ~= nil end,
    subscribeToEvent = function(_, event) subs[event] = true end,
    subscribeToNoEvents = function() subs = {} end,
}
local script, native, nativeUtil
local functions = {}
local api = {type = {ComponentType = {GAME_TIME = 1}}, engine = {
    util = {getWorld = function() return 1 end, getPlayer = function() return 1 end}, getComponent = function() return {gameTime = time} end,
    config = {getModParams = function() return {[''] = {isMapEditor = false}} end},
}, res = {
    getBaseConfig = function() return {advancedOptions = {subventionMode = 0}} end,
    genericRep = {getAllOfType = function() return {} end, find = function(id) return id == 'missing' and -1 or 1 end,
        get = function() return {data = {scriptFile = 'native-helper.script'}} end},
}, cmd = {makeScriptingSendEventCmd = function(...) return {...} end,
    sendCommand = function(command) sent[#sent + 1] = command end},
    util = {getDefaultMonthDuration = function() return 30 end},
}
local util = {useFn = function(path)
    if functions[path] then return functions[path] end
    local method = path:match('native%-helper%.script%.(.+)$')
    if method == 'shouldDespawn' then return function(record, current)
        if transient then error('engine temporarily unavailable') end
        if record.data.target == -1 or record.data.revision ~= 4 then return 'InvalidEntity' end
        return nativeUtil.defaultTimeout(record, current)
    end end
    if method == 'isComplete' then return function(record) return record.data.alreadyComplete == true end end
    if method == 'onAccept' then return function(record)
        payments = payments + 1
        assert(record.data.upfront[1].params.amount == 34567)
    end end
    if method == 'onUpdate' or method == 'onDespawn' or method == 'handleEvent' then return function() end end
    if method == 'getRelevantEntities' then return function() return {} end end
    if method == 'getNotificationParams' then return function() return {} end end
    error('Unexpected helper: ' .. path)
end}
local env = setmetatable({api = api, log = {warning = function() end}, ug_require = function(path)
    if path:find('subvention_util.tl', 1, true) then return nativeUtil end
    if path:find('subvention_legacy_util', 1, true) then return {CurrentVersion = 1} end
    if path:find('company_progression_util', 1, true) then return {getCompanyProgressionState = function() return nil end} end
    if path:find('/scripts/util.tl', 1, true) then return util end
    return {}
end}, {__index = _G})
nativeUtil = compiled(nativeDir .. '/subvention_util.tl', env)
native = compiled(nativeDir .. '/subventions.script.tl', env)
functions['::/game_mechanics/subventions/subventions.script@update'] = native.update
functions['::/game_mechanics/subventions/subventions.script@handleEvent'] = native.handleEvent
local modifier
local setupEnv = setmetatable({addModifier = function(category, fn) assert(category == 'loadGameScript'); modifier = fn end}, {__index = _G})
assert(loadfile('mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/setup.script.lua', 't', setupEnv))()
setupEnv.data().runFn()
local desc = {updateScript = {fileName = 'subventions.script@update', params = {preserved = true}},
    handleEventScript = {fileName = 'subventions.script@handleEvent'}}
assert(modifier('other::/other.gs', desc) == desc and desc.updateScript.fileName == 'subventions.script@update')
modifier('::/game_mechanics/subventions/subventions.gs', desc)
assert(desc.updateScript.fileName == 'tf3_subsidy_manager::/plugins/subsidy_manager/recovery.script@update')
assert(desc.updateScript.params.originalParams.preserved)
assert(loadfile('mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/recovery.script.lua', 't', env))()
script = env.data()
local function event(src, id, name, param)
    return script.handleEvent(desc.handleEventScript.params, state, src, id, name, param)
end
local function request(action, key)
    event('tf3_subsidy_manager', 'tf3SubsidyManager', 'tf3SubsidyManager', {action = action, key = key})
    return data.tf3SubsidyManagerArchive.response
end
local function archive() return data.tf3SubsidyManagerArchive end
local function decline(uid, auto)
    event(auto and 'tf3_subsidy_manager:auto' or '', 'Subvention', 'onDecline', {uid = uid})
end
-- Early/unknown-format requests must not poison native initialization or throw.
data = {}
event('', 'tf3SubsidyManager', 'tf3SubsidyManager', {action = 'review'})
assert(next(data) == nil)
data = world(); data.tf3SubsidyManagerArchive = {version = 99}
event('', 'tf3SubsidyManager', 'tf3SubsidyManager', {action = 'review'})
assert(data.tf3SubsidyManagerArchive.version == 99)
data = world()
-- The original script handles real initialization and subscriptions unchanged.
script.update(desc.updateScript.params, state, 0)
assert(subs.tf3SubsidyManager and subs.onDecline)
-- Automatic/manual decline records full detached contracts, without payments.
data = world({offer(10), offer(11)}); local original = copy(data.proposedSubventions[1])
decline(10, true); decline(11, false)
assert(#data.proposedSubventions == 0 and #archive().entries == 2 and payments == 0)
assert(archive().entries[1].source == 'automatic' and archive().entries[2].source == 'manual')
assert(archive().entries[1].remaining == 50)
assert(archive().entries[1].record.data.complete[1].params.amount == 98765)
-- Time spent hidden is frozen; only automatic entries participate in the notice.
time = 10000
assert(request('review').count == 1 and #data.proposedSubventions == 0 and #sent == 0)
-- Recreate the adapter and serialize the state through detached copies, as on reload.
local saved = copy(data)
assert(loadfile('mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/recovery.script.lua', 't', env))()
script = env.data(); data = copy(saved)
assert(request('recover', '1').success and payments == 0 and #data.proposedSubventions == 1)
local restored = data.proposedSubventions[1]
assert(restored.uid == original.uid and restored.id == original.id and restored.spawnTime == 9950)
assert(restored.data.expireDurationProposed == original.data.expireDurationProposed)
assert(restored.data.expireDuration == original.data.expireDuration)
assert(restored.data.toDeliver == 25 and restored.data.delivered == 0)
assert(restored.data.complete[1].params.amount == 98765 and data.usedUids[kind]['10'] == true)
assert(not request('recover', '1').success and #data.proposedSubventions == 1)
-- Native acceptance, not recovery, starts the task and applies upfront effects once.
event('', 'Subvention', 'onAccept', {uid = 10})
assert(#data.activeSubventions == 1 and #data.proposedSubventions == 0 and payments == 1)
assert(data.activeSubventions[1].acceptedTime == time)
event('', 'Subvention', 'onAccept', {uid = 10}); assert(payments == 1)
-- Review/recovery failures are manager history, never native failed tasks or penalties.
for _, problem in ipairs({'invalid_destination', 'timeout', 'already_complete', 'unsupported', 'duplicate'}) do
    data = world({offer(20)})
    if problem == 'invalid_destination' then data.proposedSubventions[1].data.target = -1 end
    if problem == 'timeout' then data.proposedSubventions[1].spawnTime = time - 101 end
    if problem == 'already_complete' then data.proposedSubventions[1].data.alreadyComplete = true end
    if problem == 'unsupported' then data.proposedSubventions[1].id = 'third-party.res' end
    decline(20, true)
    if problem == 'duplicate' then data.activeSubventions[1] = offer(20) end
    local reply = request('recover', '1')
    assert(not reply.success and reply.reason == problem, problem)
    assert(archive().entries[1].status == 'expired' and #data.failedSubventions == 0 and payments == 1)
end
-- A temporarily failing helper retains the archive and allows a later retry.
data = world({offer(30)}); decline(30, true); transient = true
assert(request('review').count == 0 and archive().entries[1].status == 'saved')
assert(request('recover', '1').reason == 'unavailable' and archive().entries[1].status == 'saved')
transient = false; assert(request('recover', '1').success)
-- Unlimited offers remain unlimited. Recovery cannot inject user-supplied terms.
data = world({offer(40)}); data.proposedSubventions[1].data.expireDurationProposed = -1
decline(40, false); assert(archive().entries[1].remaining == -1)
assert(request('recover', '1').success and data.proposedSubventions[1].data.expireDurationProposed == -1)
local bad = {action = 'recover', key = 'missing', record = offer(999)}
event('', 'tf3SubsidyManager', 'tf3SubsidyManager', bad)
assert(#data.proposedSubventions == 1 and data.proposedSubventions[1].uid == 40)
-- Do not erase newer/corrupt archive formats or decline a record that could not be saved.
data = world({offer(50)}); data.tf3SubsidyManagerArchive = {version = 99, entries = {keep = true}}
decline(50, true)
assert(#data.proposedSubventions == 1 and archive().version == 99 and archive().entries.keep)
-- Campaigns may use fractional native UIDs. Preserve deliberate decline even
-- when that contract cannot enter this mod's integer-UID recovery archive.
data = world({offer(50.5)})
decline(50.5, false)
assert(#data.proposedSubventions == 0)
print('PASS: native subsidy callbacks, scoped modifier/original params, detached persistent archive, exact-term recovery/frozen timer, native acceptance/payments once, invalid/duplicate/unsupported/transient recovery and archive-format protection')

-- Also execute each shipped type's real validity/completion helpers, not just
-- the generic lifecycle above. Other world APIs remain modeled.
local boosted = false
local helperEnv = setmetatable({api = api, _ = function(text) return text end, ug_require = function(path)
    if path:find('subvention_util.tl', 1, true) then return nativeUtil end
    if path:find('entity_util.tl', 1, true) then return {entityChanged0 = function(ref)
        return not ref or ref.entity < 0 or ref.revision.num[1] ~= 4
    end} end
    if path:find('industry_util.tl', 1, true) then return {isPersonCapacityBoosted = function() return boosted end} end
    return {}
end}, {__index = _G})
for _, name in ipairs({'deliver_cargo', 'deliver_cargo_town', 'deliver_passengers', 'deliver_workers'}) do
    local helper = compiled(nativeDir .. '/' .. name .. '/' .. name .. '.script.tl', helperEnv)[name]
    local record = offer(60, '::/game_mechanics/subventions/' .. name .. '/' .. name .. '.res')
    local ref = {entity = 77, revision = {num = {4}}}
    record.data.to, record.data.from, record.data.townEntity, record.data.stockListEntity = ref, ref, ref, ref
    record.data.passengers = {}
    assert(not helper.shouldDespawn(record, time))
    ref.revision.num[1] = 5
    assert(helper.shouldDespawn(record, time) == 'InvalidEntity', name)
    ref.revision.num[1] = 4
    assert(helper.shouldDespawn(record, time + 101) == 'Timeout', name)
    assert(not helper.isComplete(record), name)
end
print('PASS: all four installed native subsidy types retain their real entity-revision and timeout checks')
