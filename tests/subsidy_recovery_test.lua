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
local spawnMode, spawnUid = false, 80
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
-- TF3 asserts `!m_betweenChanges` when a script subscribes outside the phases
-- shipped scripts use: update, or the initNewGame/handleLegacy setup events.
local phase
local function checkSubscriptionPhase()
    if phase == 'update' then return end
    if type(phase) == 'table' and phase[1] == '' and (phase[2] == 'initNewGame' or phase[2] == 'handleLegacy') then return end
    error('Assertion `!m_betweenChanges` failed: subscription during ' .. (type(phase) == 'table' and (phase[1] .. ':' .. phase[2]) or tostring(phase)))
end
local state = {
    get = function() return copy(data) end,
    set = function(_, value) data = copy(value) end,
    hasEventSubscriptions = function() return next(subs) ~= nil end,
    subscribeToEvent = function(_, event) checkSubscriptionPhase(); subs[event] = true end,
    subscribeToNoEvents = function() checkSubscriptionPhase(); subs = {} end,
}
local script, native, nativeUtil
local functions = {}
local api = {type = {ComponentType = {GAME_TIME = 1}}, engine = {
    util = {getWorld = function() return 1 end, getPlayer = function() return 1 end}, getComponent = function() return {gameTime = time} end,
    config = {getModParams = function() return {[''] = {isMapEditor = false}} end},
}, res = {
    getBaseConfig = function() return {advancedOptions = {subventionMode = 0}} end,
    genericRep = {getAllOfType = function() return spawnMode and {1} or {} end, getName = function() return kind end, find = function(id) return id == 'missing' and -1 or 1 end,
        get = function() return {data = {scriptFile = 'native-helper.script'}} end},
}, cmd = {makeScriptingSendEventCmd = function(...) return {...} end,
    sendCommand = function(command) sent[#sent + 1] = command end},
    util = {getDefaultMonthDuration = function() return 30 end},
}
local util = {useFn = function(path)
    if functions[path] then return functions[path] end
    if path == 'native-helper.script' then return {
        getRelevantEntities = function(record) return {record.data.target} end,
        getNotificationParams = function() return {} end,
    } end
    local method = path:match('native%-helper%.script%.(.+)$')
    if method == 'canSpawn' then return function() return true end end
    if method == 'onSpawn' then return function() return offer(spawnUid).data, spawnUid end end
    if method == 'spawnSpecific' then return function(param) return offer(param.uid).data, param.uid end end
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
local warnings = 0
local env = setmetatable({api = api, log = {warning = function() warnings = warnings + 1 end, verbose = function() end}, ug_require = function(path)
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
local recoverySource = os.getenv('TF3_RECOVERY_SOURCE') or 'mod/tf3_subsidy_manager_1/content/plugins/subsidy_manager/recovery.script.lua'
-- Each load is a fresh script Lua state, as after starting or loading a game.
local function loadAdapter()
    assert(loadfile(recoverySource, 't', env))()
    local raw = env.data()
    return {
        update = function(...)
            phase = 'update'; local result = raw.update(...); phase = nil; return result
        end,
        handleEvent = function(params, s, src, id, name, param)
            phase = {id, name}; local result = raw.handleEvent(params, s, src, id, name, param); phase = nil; return result
        end,
    }
end
script = loadAdapter()
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
-- Every start path: setup events reach a fresh script before its first update.
-- Map/mission/tutorial starts must not subscribe during the event, and our
-- subscription must not stop the native script initializing its own.
for _, setup in ipairs({'initNewGameFromMap', 'initMission', 'initTutorial', 'initNewGame', 'handleLegacy'}) do
    script, subs, data = loadAdapter(), {}, {}
    if setup == 'handleLegacy' then data = world() end
    event('', '', setup, nil)
    assert(not subs.tf3SubsidyManager, setup .. ' subscribed during the setup event')
    script.update(desc.updateScript.params, state, 0)
    assert(subs.onAccept and subs.onDecline, setup .. ' prevented native subsidy subscriptions')
    assert(subs.tf3SubsidyManager, setup .. ' left manager commands unsubscribed')
end
-- Loading a save clears all subscriptions; ours returns on the next update.
event('', '', 'handleLegacy', nil)
assert(subs.onDecline and not subs.tf3SubsidyManager)
script.update(desc.updateScript.params, state, 0)
assert(subs.tf3SubsidyManager, 'handleLegacy must not permanently remove manager subscriptions')
-- Ordinary events before the first update of a fresh script state never subscribe.
script, subs, data = loadAdapter(), {onDecline = true}, world({offer(5)})
event('', 'Subvention', 'onDecline', {uid = 5})
event('tf3_subsidy_manager', 'tf3SubsidyManager', 'tf3SubsidyManager', {action = 'review'})
assert(#data.proposedSubventions == 0 and not subs.tf3SubsidyManager)
script.update(desc.updateScript.params, state, 0)
assert(subs.tf3SubsidyManager)
data = world()
print('PASS: no subscriptions during map/mission/tutorial/free-game/load setup or ordinary events; native subscriptions initialize and manager commands resubscribe on update')
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
script = loadAdapter(); data = copy(saved)
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

-- Execute the installed notification collector's subsidy block against every
-- committed state, including the exact moment the native generator adds offers.
local function nativeTable(value)
    return {value = value, find = function(self, key)
        local child = self.value[key]
        return type(child) == 'table' and nativeTable(child) or child
    end, asTable = function(self) return copy(self.value) end}
end
local notifyPath = nativeDir .. '/../notifications/notifications.script.tl'
local file = assert(io.open(notifyPath)); local source = file:read('*a'); file:close()
local start = assert(source:find('local stateNative = gameScript.state_native', 1, true))
local finish = assert(source:find('notification_util.updatePersistentNotifications(notificationsState, historyByType, persistentNotifications)', start, true))
local collectorCode = 'return function(gameScript)\nlocal persistentNotifications = {entitiesAndParam = {}}\n' .. source:sub(start, finish - 1) .. '\nreturn persistentNotifications.entitiesAndParam\nend'
local collectorEnv = setmetatable({api = api, util = util, entity_util = {
    makeEntityAndRevision = function(entity) return {entity = entity, revision = {num = {4}}} end,
    makeEntityAndRevision0Array = function(entities) return entities end,
}, pairs_native_lua_table = function(value)
    local key
    return function()
        local child; key, child = next(value.value, key)
        if key then return key, type(child) == 'table' and nativeTable(child) or child end
    end
end}, {__index = _G})
local generated, result = tl.gen(collectorCode)
assert(generated and #result.syntax_errors == 0)
local collect = assert(load(generated, 'native-subsidy-notification-collector', 't', collectorEnv))()
local function notifiedUids()
    local uids = {}
    for _, notice in ipairs(collect({state_native = nativeTable(data)})) do uids[notice.param.uid] = true end
    return uids
end
local originalSet = state.set
local forbiddenUid, committed = nil, 0
state.set = function(self, value)
    originalSet(self, value); committed = committed + 1
    if forbiddenUid then assert(not notifiedUids()[forbiddenUid], 'Hidden offer escaped into native notification input') end
end
nativeUtil.getSpawnIntervalDuration = function() return spawnMode and 1 or -1 end
data = world({offer(70)}); data.lastSpawnTime = 0
local function config(enabled, review)
    event('tf3_subsidy_manager', 'tf3SubsidyManager', 'tf3SubsidyManager', {action = 'configure', enabled = enabled, review = review})
    return archive().response
end
assert(config(true, false).success and archive().automatic.enabled)
spawnMode, spawnUid, forbiddenUid = true, 80, 80
script.update(desc.updateScript.params, state, 1)
assert(#data.proposedSubventions == 1 and data.proposedSubventions[1].uid == 70)
assert(#archive().entries == 1 and archive().entries[1].record.uid == 80 and archive().entries[1].source == 'automatic')
assert(data.spawnIntervalModifier == 1, 'Hidden offers keep the native spawn interval instead of the decline speed-up')
assert(notifiedUids()[70] and not notifiedUids()[80])
-- Input-command spawns use the same buffered commit, not just ordinary updates.
forbiddenUid = 81
event('', 'Subvention', 'subventionSpawn', {name = kind, specific = {uid = 81}})
assert(#data.proposedSubventions == 1 and #archive().entries == 2 and not notifiedUids()[81])
-- Repeated enable/saved-choice synchronization must not reset the protection map.
assert(config(true, false).success)
spawnMode = false
script.update(desc.updateScript.params, state, 0)
assert(#data.proposedSubventions == 1 and data.proposedSubventions[1].uid == 70)
local review = config(false, true)
assert(review.count == 2 and review.enabled == false and not archive().automatic.enabled)
assert(archive().entries[1].revealed and archive().entries[2].revealed)
assert(archive().notice.count == 2 and #data.proposedSubventions == 1)
assert(review.newCount == 2, 'The first review announces newly hidden offers')
config(true, false)
local repeated = config(false, true)
assert(repeated.count == 2 and repeated.newCount == 0, 'Repeated toggles must keep old offers without announcing them again')
local noticeSequence = archive().notice.sequence
config(false, false)
assert(archive().notice.sequence == noticeSequence, 'Startup synchronization must not erase an unread resume notice')
-- Once off, new native offers are visible again; old hidden ones need Recover.
forbiddenUid = nil
spawnMode, spawnUid = true, 82
time = time + 2
script.update(desc.updateScript.params, state, 1)
assert(#data.proposedSubventions == 2 and notifiedUids()[82])
assert(#archive().entries == 2 and committed > 0)
print('PASS: atomic suppression of native update/event spawns before the shipped notification collector, existing-offer protection, persisted configuration, disable/review and unread notice preservation')

-- Revealed offers remain available after enabling again and across reload.
config(true, false)
assert(archive().entries[1].revealed and archive().entries[2].revealed)
data = copy(data)
script = loadAdapter()
assert(request('recover', '1').success)
spawnMode = false
script.update(desc.updateScript.params, state, 0)
assert(#data.proposedSubventions == 3 and notifiedUids()[80], 'Opening a revealed offer must protect it from being suppressed again')
assert(#archive().entries == 1 and archive().entries[1].record.uid == 81)
spawnMode, spawnUid, forbiddenUid = true, 83, 83
time = time + 2
script.update(desc.updateScript.params, state, 1)
assert(#data.proposedSubventions == 3 and #archive().entries == 2 and not notifiedUids()[83])
assert(archive().entries[1].revealed and not archive().entries[2].revealed)
assert(request('recover', archive().entries[2].key).reason == 'unavailable')
assert(#data.proposedSubventions == 3 and archive().entries[2].status == 'saved')
local paymentsBefore = payments
event('', 'Subvention', 'onAccept', {uid = 80})
assert(#data.activeSubventions == 1 and data.activeSubventions[1].uid == 80 and payments == paymentsBefore + 1)
local freshReview = config(false, true)
assert(freshReview.count == 2 and freshReview.newCount == 1, 'Only newly hidden offers join the next reminder, while all valid offers remain available')
assert(archive().entries[2].revealed)
-- Legacy offers already shown with mode off gain persistent flags on enabling.
archive().entries[1].revealed = nil
config(true, false)
assert(archive().entries[1].revealed)
forbiddenUid = nil
print('PASS: durable revealed offers, protected opening while enabled, future suppression isolation and legacy visible-offer migration')

-- A changed/failing callback must never create a saved duplicate of a live offer.
data = world(); config(true, false)
local declinePath = desc.updateScript.params.nativeEvent
local nativeDecline = functions[declinePath]
functions[declinePath] = function() end
spawnUid = 90; time = time + 2
script.update(desc.updateScript.params, state, 1)
assert(#data.proposedSubventions == 1 and data.proposedSubventions[1].uid == 90 and #archive().entries == 0)
functions[declinePath] = nativeDecline
spawnMode = false
script.update(desc.updateScript.params, state, 0)
assert(#data.proposedSubventions == 0 and #archive().entries == 1)
event('tf3_subsidy_manager', 'tf3SubsidyManager', 'tf3SubsidyManager', {action = 'configure', enabled = false, review = true, requestId = 'session:123'})
assert(archive().response.requestId == 'session:123')
table.insert(archive().entries, 1, 'malformed')
assert(request('recover', '1').success, 'Malformed unrelated archive entry must not block valid recovery')
print('PASS: failed/no-op native declines roll back saved copies, retries remain possible, request correlation and malformed-entry isolation')

-- Native decline matches only the UID. Another type's offer may share it, so
-- leave that new offer visible instead of rolling back a decline every update.
local cargo = '::/game_mechanics/subventions/deliver_cargo/deliver_cargo.res'
data = world({offer(95, cargo)}); data.lastSpawnTime = 0; config(true, false)
spawnMode, spawnUid, warnings = true, 95, 0; time = time + 2
script.update(desc.updateScript.params, state, 1)
spawnMode = false
script.update(desc.updateScript.params, state, 0)
assert(#data.proposedSubventions == 2 and data.proposedSubventions[1].id == cargo and data.proposedSubventions[2].id == kind)
assert(#archive().entries == 0 and warnings == 0, 'Shared native UIDs must not trigger failing decline attempts')
print('PASS: offers sharing a native UID stay visible without repeated rollback')

-- Saved contracts are capped per kind; the newest entries are kept.
data = world(); config(false, false)
for uid = 100, 124 do data.proposedSubventions[#data.proposedSubventions + 1] = offer(uid) end
for uid = 100, 124 do decline(uid, false) end
assert(#archive().entries == 20 and archive().entries[1].record.uid == 105 and archive().entries[20].record.uid == 124)
assert(data.spawnIntervalModifier == 0.5, 'Manual declines keep the native next-offer speed-up')
-- Older versions could save without limits: the startup sync trims them first.
local entries = {}
for index = 1, 55 do entries[index] = {key = 'a' .. index, record = offer(200 + index), remaining = 50, source = 'automatic', status = 'saved'} end
for index = 1, 25 do entries[#entries + 1] = {key = 'e' .. index, record = offer(300 + index), remaining = 0, source = 'automatic', status = 'expired', reason = 'timeout'} end
entries[#entries + 1] = 'malformed'
entries[#entries + 1] = {key = 'future', status = 'unknown'}
data = world(); data.tf3SubsidyManagerArchive = {version = 1, nextKey = 100, entries = entries, response = {sequence = 0}}
local trimmed = config(false, true)
assert(trimmed.count == 50, 'Review counts only retained offers')
local kinds = {}
for _, entry in ipairs(archive().entries) do
    local kind = type(entry) == 'table' and entry.status or 'malformed'
    kinds[kind] = (kinds[kind] or 0) + 1
end
assert(kinds.saved == 50 and kinds.expired == 20 and kinds.malformed == 1 and kinds.unknown == 1)
assert(archive().entries[1].key == 'a6', 'The oldest hidden offers are dropped first')
-- A newly hidden offer at the limit replaces the oldest one.
config(true, false)
spawnMode, spawnUid = true, 400; time = time + 2; data.lastSpawnTime = 0
script.update(desc.updateScript.params, state, 1)
spawnMode = false
local saved, newest = 0, nil
for _, entry in ipairs(archive().entries) do
    if type(entry) == 'table' and entry.status == 'saved' then saved = saved + 1; newest = entry end
    assert(type(entry) ~= 'table' or entry.key ~= 'a6')
end
assert(saved == 50 and newest.record.uid == 400 and #data.proposedSubventions == 0)
assert(data.spawnIntervalModifier == 1)
print('PASS: newest 50 hidden, 20 declined and 20 expired entries retained, legacy archives trimmed, unknown entries preserved, normal spawn interval while hiding')
