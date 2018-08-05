--luacheck: std lua51,module,read globals luup,ignore 542 611 612 614 111/_,no max line length
-- ----------------------------------------------------------------------------
--
-- L_Rachio1.lua
-- Rachio Plug-in for Vera implementation module
-- Copyright 2017,2018 Patrick H. Rigney, All Rights Reserved
-- For information, see http://www.toggledbits.com/rachio/
--
-- ----------------------------------------------------------------------------
--
-- TO-DO:
--   Flex schedules need separate D_.json file without skip/start (they can't do those).
--   Better icons? More state icons?
--   Set or clear a rain delay?
--   More watering stats? Weather? What's the API got?
--   Schedules... seasonal adjustment? enable/disable? What does skip do, anyway?
--   Handle non-ONLINE status for device, propagate to zones and schedules?
--
-- -----------------------------------------------------------------------------

module("L_Rachio1", package.seeall)

local _PLUGIN_ID = 8954
local _PLUGIN_NAME = "Rachio"
local _PLUGIN_VERSION = "1.stable-180805"
local _PLUGIN_URL = "http://www.toggledbits.com/rachio"
local _CONFIGVERSION = 00108

local debugMode = false

local SYSSID = "urn:toggledbits-com:serviceId:Rachio1"
local SYSTYPE = "urn:schemas-toggledbits-com:device:Rachio:1"

local DEVICESID = "urn:toggledbits-com:serviceId:RachioDevice1"
local DEVICETYPE = "urn:schemas-toggledbits-com:device:RachioDevice:1"

local ZONESID = "urn:toggledbits-com:serviceId:RachioZone1"
local ZONETYPE = "urn:schemas-toggledbits-com:device:RachioZone:1"

local SCHEDULESID = "urn:toggledbits-com:serviceId:RachioSchedule1"
local SCHEDULETYPE = "urn:schemas-toggledbits-com:device:RachioSchedule:1"

local SWITCHSID = "urn:upnp-org:serviceId:SwitchPower1"

local HTTPREQ_OK = 0
local HTTPREQ_AUTHFAIL = 1
local HTTPREQ_STATUSERROR = 2
local HTTPREQ_JSONERROR = 3
local HTTPREQ_RATELIMIT = 4
local HTTPREQ_GENERICERROR = 99

local API_BASE = "https://api.rach.io/1" -- Default URL; can be overridden by SYSSID/APIBase
local DEFAULT_INTERVAL = 120    -- Default interval between API polls; can be overriden by SYSSID/Interval
local MAX_CYCLEMULT = 256       -- Max multiplier for poll interval (doubles on each error up to this number)
local MAX_INTERVAL = 14400      -- Absolute max delay we'll allow

local runStamp = 0
local tickCount = 0
local lastTick = 0
local apilimit = 1700
local nthresh = 1360 -- threshold for API quota warnings
local nextUpdate = 0
local updatePending = false
local schedRunning = false
local firstRun = true
local messages = {}
local isALTUI = false
local isOpenLuup = false
local childrenByUID = {}
local serviceDevice = 0

local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require('dkjson')
if json == nil then json = require("json") end
-- Our total inability to find a json module is handled in start

local rateTab = nil     -- to track API rate limiting
local rateDiv = 5       -- granularity (seconds)
local rateMax = 15      -- max per-minute rate allowed

local hardFail

local function formatMinutes( m )
    local h
    h = math.floor( m / 60)
    m = m - 60 * h
    return string.format("%02d:%02d", h, m)
end

local function dump(t)
    if t == nil then return "nil" end
    local sep = ""
    local str = "{ "
    for k,v in pairs(t) do
        local val
        if type(v) == "table" then
            val = dump(v)
        elseif type(v) == "function" then
            val = "(function)"
        elseif type(v) == "string" then
            val = string.format("%q", v)
        else
            val = tostring(v)
        end
        str = str .. sep .. tostring(k) .. "=" .. val
        sep = ", "
    end
    str = str .. " }"
    return str
end

local function L(msg, ...)
    local str
    local level = 50
    if type(msg) == "table" then
        str = tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg)
        level = msg.level or level
    else
        str = _PLUGIN_NAME .. ": " .. tostring(msg)
    end
    str = string.gsub(str, "%%(%d+)", function( n )
            n = tonumber(n, 10)
            if n < 1 or n > #arg then return "nil" end
            local val = arg[n]
            if type(val) == "table" then
                return dump(val)
            elseif type(val) == "string" then
                return string.format("%q", val)
            end
            return tostring(val)
        end
    )
    luup.log(str, level)
end

local function D(msg, ...)
    if debugMode then
        L( { msg=msg,prefix=_PLUGIN_NAME .. "(debug)::" }, ... )
    end
end

local function A(st, msg, ...)
    if msg == nil then msg = "assertion failed" end
    if not st then
        L(msg, ...)
        hardFail(HTTPREQ_GENERICERROR, "Offline (" + msg + ")")
    end
end

local function choose( ix, dflt, ...)
    if ix < 1 or ix > #arg then return dflt end
    return arg[ix]
end

local function split( str, sep )
    if sep == nil then sep = "," end
    local arr = {}
    if #str == 0 then return arr, 0 end
    local rest = string.gsub( str or "", "([^" .. sep .. "]*)" .. sep, function( m ) table.insert( arr, m ) return "" end )
    table.insert( arr, rest )
    return arr, #arr
end

-- Map a true array to a table.
local function map( a, f, r )
    if r == nil then r = {} end
    for index,value in ipairs(a) do
        if f == nil then
            r[value] = true
        else
            local nk,nv = f( index, value )
            if nv == nil then
                r[value] = nk
            else
                r[nk] = nv
            end
        end
    end
    return r
end

-- Deep copy a table
-- See https://gist.github.com/MihailJP/3931841
local function clone( t )
    if type(t) ~= "table" then return t end
    local meta = getmetatable(t)
    local target = {}
    for k,v in pairs(t) do
        if type(v) == "table" then
            target[k] = clone(v)
        else
            target[k] = v
        end
    end
    setmetatable(target, meta)
    return target
end

-- Merge arrays
local function arraymerge( base, ... )
    if base == nil then return {} end
    local res = clone(base)
    if arg ~= nil and #arg > 0 then
        for _,a in ipairs(arg) do
            if type(a) ~= "table" then a = { a } end
            for _,v in ipairs(a) do
                if type(v) == "table" then
                    table.insert(res, clone(v))
                else
                    table.insert(res, v)
                end
            end
        end
    end
    return res
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( serviceid, name, dflt, dev )
    if dev == nil then dev = serviceDevice end
    local s = luup.variable_get(serviceid, name, dev)
    if (s == nil or s == "") then return dflt end
    s = tonumber(s, 10)
    if (s == nil) then return dflt end
    return s
end

-- Shortcut function to return state of SwitchPower1 Status variable
local function isServiceCheck()
    local s = getVarNumeric( SYSSID, "ServiceCheck", "", serviceDevice )
    if s == "" then return true end -- default is we really don't know, so say down
    return (s ~= "0")
end

-- Schedule next update. If it's sooner than current, start new timer thread
local function scheduleUpdate( delay, force )
    D("scheduleUpdate(%1,%2) nextUpdate=%3 (%4 from now)", delay, force, nextUpdate, nextUpdate-os.time())
    local nxt = os.time() + delay
    force = force or nextUpdate == 0 or nextUpdate <= os.time()
    if force or nxt < nextUpdate then
        runStamp = runStamp + 1
        nextUpdate = nxt
        luup.call_delay("rachio_plugin_tick", delay, runStamp)
        D("scheduleUpdate() scheduled next tick for %1 (%2), stamp %3", delay, nxt, runStamp)
    end
end

local function resolveDevice( dev )
    D("resolveDevice(%1) USE OF DEPRECATED FUNCTION", dev)
    if dev == nil then return dev end
    local ndev = tonumber(dev,10)
    if ndev ~= nil and ndev > 0 and luup.devices[ndev] ~= nil then
        return luup.devices[ndev],ndev
    end
    dev = dev:lower()
    if dev:sub(1,5) == "uuid:" then
        for k,v in pairs(luup.devices) do
            if v.udn == dev then return v,k end
        end
    end
    for k,v in pairs(luup.devices) do
        if v.id == dev then return v,k end
    end
    for k,v in pairs(luup.devices) do
        if v.description:lower() == dev then return v,k end
    end
    D("resolveDevice(%1) did not find device")
    return nil
end

local function showServiceStatus(msg, dev)
    dev = dev or serviceDevice
    luup.variable_set(SYSSID, "Message", msg, dev)
end

local function setMessage(s, sid, dev, pri)
    if sid == nil then sid = SYSSID end
    if dev == nil then dev = serviceDevice end
    if pri == nil then pri = 0 end
    local dk = tostring(dev)
    local l = messages[dk]
    if l ~= nil and pri < l.pri then
        return
    end
    if s == nil then L(debug.traceback()) end
    messages[dk] = { dev=dev, pri=pri, text=tostring(s), service=sid }
end

local function postMessages()
    -- ??? Can/should we use luup.device_message? Present in releases after Feb 2017
    for _,node in pairs(messages) do
        -- D("postMessage() device #%1 service %2 message %3", node.dev, node.service, node.text)
        luup.variable_set( node.service, "Message", node.text or "", node.dev )
    end
    messages = {}
end

-- Find a child by Rachio's ID (UID)
local function findChildByUID( uid, parentId )
  if uid == nil then return nil end
  parentId = parentId or serviceDevice
  if childrenByUID[uid] ~= nil then return childrenByUID[uid], luup.devices[childrenByUID[uid]] end
  for k,v in pairs(luup.devices) do
    if v.device_num_parent == parentId and uid == v.id then
        childrenByUID[uid] = k
        return k,v
    end
  end
  return nil
end

-- Returns children matching type as (true) array of device numbers
local function findChildrenByType( typ, parentId )
    D("findChildrenByType(%1,%2)", typ, parentId)
    parentId = parentId or serviceDevice
    assert(type(parentId)=="number")
    local result = {}
    for k,v in pairs( luup.devices ) do
        if v.device_num_parent == parentId and v.device_type == typ then
            table.insert( result, k )
        end
    end
    return result
end

local function findZoneByNumber( nIro, zoneNumber )
    D("findZoneByNumber(%1,%2)", nIro, zoneNumber)
    local iro = luup.devices[nIro]
    if iro == nil then return nil end
    assert(iro.device_type == DEVICETYPE, "Device is not controller")
    D("findZoneByNumber() iro dev #%1 (%2) id is %3", nIro, iro.description, iro.id)

    local zoneDevices = findChildrenByType(ZONETYPE)
    zoneNumber = tonumber(zoneNumber,10)
    for _,devnum in ipairs(zoneDevices) do
        -- Is this zone part of the Iro we're looking for?
        local pd = getVarNumeric( DEVICESID, "ParentDevice", 0, devnum )
        if pd == nIro then
            local zn = getVarNumeric( ZONESID, "Number", 0, devnum)
            if zn == zoneNumber then return luup.devices[devnum], devnum end
        end
    end
    return nil
end

-- Hard fail the service.
-- ??? What happens if this is called in child-device context, such as during
--     an attempt to start or stop the watering schedule? We may not care, as
--     whatever error befalls the API call will crop up on a subsequent update
--     cycle if its not transient. But should be elegant, dontcha think?
hardFail = function (status, msg) -- forward declared
    D("hardFail(%1,%2)", status, msg)

    -- Set ServiceCheck variable and update status message
    if status == 0 or status == nil then status = 99 end
    if msg == nil then msg = "Offline" end
    luup.variable_set(SYSSID, "ServiceCheck", status, serviceDevice)
    showServiceStatus(msg, serviceDevice)

    -- Set status of devices and zones?
    local devices = findChildrenByType(DEVICETYPE)
    for _,devnum in ipairs(devices) do
        setMessage("NO SERVICE", DEVICESID, devnum, 99)
        luup.variable_set(DEVICESID, "Message", "NO SERVICE", devnum)
    end
    postMessages()
    
    L({level=1,msg=msg})

    -- Traceback
    L("hardFail() traceback: %1", debug.traceback())
    -- luup.set_failure(1, service)
    -- Setting runStamp to 0 will prevent any further tick loop executions
    runStamp = 0
    -- Outta here...
    error({pluginStatus=status})
end

-- Check for rate limit (used for query against API). Returns true if
-- running 60-second query rate exceeds rateMax.
local function rateLimit()
    local t = os.time()
    local id = math.floor(t / rateDiv)
    if rateTab == nil or rateTab.id ~= id then
        -- Create a new bucket and put it on the head of the list
        local newTab = { id=id, count=0, next=rateTab }
        rateTab = newTab
    end
    rateTab.count = rateTab.count + 1
    -- Get 60-second rate
    local n = rateTab
    local minid = math.floor((t-60) / rateDiv)
    local nb = 0
    t = 0
    while n do
        if n.id <= minid then
            n.next = nil -- truncate list here
        else
            t = t + n.count
            nb = nb + 1
        end
        n = n.next
    end
    D("rateLimit() rate is %1 from %2 buckets", t, nb)
    return t > rateMax
end

local function getJSON(path, method, body)
    local url = ( luup.variable_get( SYSSID, "APIBase", serviceDevice ) or API_BASE ) .. path
    if method == nil then method = "GET" end

    -- Check our query rate, fail if exceeded.
    if rateLimit() then return HTTPREQ_RATELIMIT, "API rate limit" end

    -- Get the API key
    local apiKey = luup.variable_get(SYSSID, "APIKey", serviceDevice)
    if ( apiKey == nil or apiKey == "" ) then
        return HTTPREQ_AUTHFAIL, "API key not set"
    end

    -- A few other knobs we can turn
    local timeout = getVarNumeric(SYSSID, "Timeout", 10) -- ???
    -- local maxlength = getVarNumeric(SYSSID, "MaxLength", 262144) -- ???

    local src
    local tHeaders = {}
    tHeaders["Authorization"] = "Bearer " .. tostring(apiKey)

    -- Build post/put data
    if type(body) == "table" then
        body = json.encode(body)
        tHeaders["Content-Type"] = "application/json"
        D("getJSON() preparing JSON body: %1", body)
    end
    if body ~= nil then
        tHeaders["Content-Length"] = string.len(body)
        src = ltn12.source.string(body)
        D("getJSON() prepared source for body, length %1", tHeaders["Content-Length"])
    else
        src = nil
        D("getJSON() no body for this request")
    end

    -- HTTP or HTTPS?
    local requestor
    if url:lower():find("https:") then
        requestor = https
    else
        requestor = http
    end
    
    -- Update call count.
    local ncall = getVarNumeric(SYSSID, "DailyCalls", 0, serviceDevice) + 1
    local ntime = getVarNumeric(SYSSID, "DailyStamp", 0, serviceDevice)
    local today = math.floor(os.time() / 86400)
    if ntime ~= today then
        D("getJSON() call counter day changed, was %1 now %2, resetting counter", ntime, today)
        L("Made %1 API calls in last 24 hours. Resetting counter now.", ncall)
        ncall = 1
        luup.variable_set(SYSSID, "DailyStamp", today, serviceDevice)
    end 
    luup.variable_set(SYSSID, "DailyCalls", ncall, serviceDevice)
    if ( ncall % 100 ) == 0 then
        L("Milestone: %1 API calls made so far today.", ncall)
    else
        D("getJSON() daily call counter now %1", ncall)
    end
    
    --[[
    if debugMode then
        local ff = io.open("/etc/cmh-ludl/RachioAPICalls.log", "a")
        if ff then
            ff:write(string.format("%d %d %d %s %s\n", os.time(), today, ncall, method, url))
            ff:close()
        end
    end
    --]]
    
    -- Make the request.
    local r = {}
    http.TIMEOUT = timeout -- N.B. http not https, regardless
    D("getJSON() #%1: %2 %3, headers=%4", ncall, method, url, tHeaders)
    local respBody, httpStatus, httpHeaders = requestor.request{
        url = url,
        source = src,
        sink = ltn12.sink.table(r),
        method = method,
        headers = tHeaders,
        redirect = false
    }

    -- Since we're using the table sink, concatenate chunks to single string.
    respBody = table.concat(r)
    r = nil -- free that table memory?
    
    --[[
    if debugMode then
        local ff = io.open("/etc/cmh-ludl/RachioAPICalls.log", "a")
        if ff then
            ff:write(string.format("%d %d %d RESP %s %s\n",    os.time(), today, ncall, httpStatus, json.encode(httpHeaders or {})))
            ff:write(string.format("%d %d %d RESPDATA %s\n", os.time(), today, ncall, respBody))
            ff:close()
        end
    end
    --]]

    -- See what happened.
    -- ??? Now that we're using a sink, respBody is always 1, so maybe revisit the tests below at some point (harmless now)
    D("getJSON() request returned httpStatus=%1, respBody=%2, headers=%3", httpStatus, respBody, httpHeaders)
    
    -- If Rachio passes back quota info in headers (it should), update our stats.
    if httpHeaders['x-ratelimit-limit'] then
        apilimit = tonumber( httpHeaders['x-ratelimit-limit'] ) or apilimit
        if httpHeaders['x-ratelimit-remaining'] then
            local rem = tonumber(httpHeaders['x-ratelimit-remaining'])
            if ( rem or 0 ) > 0 then
                local count = apilimit - rem
                local newthresh = math.floor( apilimit * 80 / 100 ) -- start warnings at 80% of quota
                if newthresh > nthresh then nthresh = newthresh end -- only if it moves up
                luup.variable_set( SYSSID, "DailyCalls", count, serviceDevice ) -- reset to what Rachio says
                D("getJSON() overriding daily call count to %1 on limit of %2, from response headers",
                    count, apilimit)
            end
        end
    end

    -- Shortcuts
    if httpStatus == 204 then
        -- Success response with no data, take shortcut.
        return HTTPREQ_OK, {}
    elseif respBody == nil or httpStatus ~= 200 then
        -- Error of some persuasion
        if httpStatus == 401 then
            return HTTPREQ_AUTHFAIL, httpStatus
        end
        return HTTPREQ_STATUSERROR, httpStatus
    end

    -- Fix booleans, which dkjson module doesn't seem to understand (gives nil)
    respBody = string.gsub( respBody, ": *true *,", ": 1," )
    respBody = string.gsub( respBody, ": *false *,", ": 0," )
    D("getJSON() response respBody is %1", respBody)

    -- Try to parse response as JSON
    local t, pos, err = json.decode(respBody)
    if err then
        L("getJSON() unable to decode response, " .. tostring(err))
        D("getJSON() response was %1, failed at %2", respBody, pos)
        return HTTPREQ_JSONERROR, err
    end

    -- Well, that worked. Return OK status and table of data.
    return HTTPREQ_OK, t
end

-- Handle schedule check. cd is device node, serviceDev is device number/id
local function doSchedCheck( cdn, cd, serviceDev )
    if cd == nil then cd = luup.devices[cdn] end
    D("doSchedCheck(%1,%2,%3)", cdn, cd.id, serviceDev)
    -- local status, schedule = getJSON("/public/device/" .. cd.id)
    local status, schedule = getJSON("/public/device/" .. cd.id .. "/current_schedule")
    if status == HTTPREQ_OK then
        -- Get our last known watering state (it may be changing)
        local watering = getVarNumeric(DEVICESID, "Watering", 0, cdn)
        -- check schedule type? particulars for type?
        if schedule.type ~= nil then
            -- ??? check zone ID, make sure it's zone we know
            -- ??? what does multiple zone schedule report?
            D("doSchedCheck() handling %1 schedule, watering=%2", schedule.type, watering)
            
            --[[ 2018-03-13: Rachio has a bug with startDate since their latest API upgrade.
                             It returns an outlandish date. For ex, if I start watering today
                             3/13, it will give me July 17 2017 as a start date for my acct/config.
                             Since we also get zone start date, use that in preference.
            --]]
            local lastStart
            if watering == 0 then
                -- Check for broken lastStart, possible zoneStartDate alternate.
                lastStart = math.floor( schedule.startDate / 1000 )
                D("doSchedStart() start of watering, schedule reports start %1", lastStart)
                if ( os.time() - lastStart ) > 10800 then
                    L({level=2,msg="API returned schedule start >3 hours (%1); using fallback zone start."}, lastStart)
                    lastStart = math.floor( schedule.zoneStartDate / 1000 )
                end
                luup.variable_set( DEVICESID, "LastStart", lastStart, cdn )
            else
                -- Schedule is still running; use our start marker 
                lastStart = getVarNumeric( DEVICESID, "LastStart", os.time(), cdn )
                D("doSchedStart() watering continues from lastStart=%1", lastStart)
            end

            schedRunning = true

            local schedMessage = tostring(schedule.status) .. " " .. tostring(schedule.type)
            schedMessage = schedMessage:sub(1,1):upper() .. schedMessage:sub(2):lower()

            -- Use schedule stats and apply to device
            D("doSchedCheck: sched startDate %1 duration %2", schedule.startDate, schedule.duration)
            local durMinutes = math.ceil( schedule.duration / 60 ) -- duration for entire schedule
            local runEnds = lastStart + schedule.duration
            local remaining = math.ceil( (runEnds - os.time()) / 60 )
            if remaining < 1 then remaining = 0 end
            D("doSchedCheck: sched start %1 dur %2 ends %3 rem %4", lastStart, durMinutes, runEnds, remaining)
            -- Now apply to schedule if known device (e.g. not a manual schedule, for which we would not have a device)
            local csn, cs = findChildByUID( schedule.scheduleRuleId )
            if csn ~= nil then
                D("doSchedCheck() setting schedule info for %1 (%2) remaining %3", schedule.scheduleId, cs.description, remaining)
                schedMessage = schedMessage .. " " .. cs.description
                luup.variable_set(SCHEDULESID, "LastStart", lastStart, csn)
                luup.variable_set(SCHEDULESID, "RunEnds", runEnds, csn)
                luup.variable_set(SCHEDULESID, "Duration", durMinutes, csn)
                luup.variable_set(SCHEDULESID, "Remaining", remaining, csn)
                luup.variable_set(SCHEDULESID, "Watering", 1, csn)
                luup.variable_set(SWITCHSID, "Status", 1, csn)
                luup.variable_set(DEVICESID, "LastSchedule", csn, cdn)
                luup.variable_set(DEVICESID, "LastScheduleName", schedule.type .. " " .. cs.description, cdn)
                if remaining > 0 then
                    setMessage(formatMinutes(remaining), SCHEDULESID, csn, 20)
                else
                    setMessage("Runtime indeterminate", SCHEDULESID, csn, 20)
                end
            else
                D("doSchedCheck() schedule %1 not a child--manual schedule?", schedule.scheduleId)
                luup.variable_set(DEVICESID, "LastSchedule", "", cdn)
                luup.variable_set(DEVICESID, "LastScheduleName", schedule.type, cdn)
            end
            luup.variable_set(DEVICESID, "RunEnds", runEnds, cdn)
            luup.variable_set(DEVICESID, "Duration", durMinutes, cdn)
            luup.variable_set(DEVICESID, "Remaining", remaining, cdn)
            luup.variable_set(DEVICESID, "Watering", 1, cdn)
            
            setMessage(schedMessage, DEVICESID, cdn, 20)

            -- Reset stats for (all) zones
            local zones = findChildrenByType(ZONETYPE)
            for _,czn in ipairs(zones) do
                local zoneDev = getVarNumeric( DEVICESID, "ParentDevice", 0, czn)
                if zoneDev == cdn then -- belong to this controller?
                    if luup.devices[czn].id == schedule.zoneId then
                        -- This is the running zone
                        lastStart = math.floor( schedule.zoneStartDate / 1000 )
                        durMinutes = math.ceil( schedule.zoneDuration / 60 )
                        runEnds = lastStart + schedule.zoneDuration
                        remaining = math.ceil( (runEnds - os.time()) / 60 )
                        if remaining < 1 then remaining = 1 end
                        D("doSchedCheck() setting zone dev #%4 info for %1 (zone %2) remaining %3", schedule.zoneId, schedule.zoneNumber, remaining, czn)
                        luup.variable_set(ZONESID, "LastStart", lastStart, czn)
                        luup.variable_set(ZONESID, "RunEnds", runEnds, czn)
                        luup.variable_set(ZONESID, "Duration", durMinutes, czn)
                        luup.variable_set(ZONESID, "Remaining", remaining, czn)
                        luup.variable_set(ZONESID, "Watering", 1, czn)
                        luup.variable_set(SWITCHSID, "Status", 1, czn)
                        if cs ~= nil then
                            luup.variable_set(ZONESID, "LastSchedule", csn, czn)
                            luup.variable_set(ZONESID, "LastScheduleName", schedule.type .. " " .. cs.description, czn)
                        else
                            luup.variable_set(ZONESID, "LastSchedule", "", czn)
                            luup.variable_set(ZONESID, "LastScheduleName", schedule.type, czn)
                        end
                        setMessage(formatMinutes(remaining), ZONESID, czn, 20)
                    else
                        luup.variable_set(ZONESID, "Remaining", 0, czn)
                        luup.variable_set(ZONESID, "Watering", 0, czn)
                        luup.variable_set(SWITCHSID, "Target", 0, czn)
                        luup.variable_set(SWITCHSID, "Status", 0, czn)
                    end
                end
            end
        else
            local standby = getVarNumeric( DEVICESID, "On", 0, cdn ) == 0
            local paused = getVarNumeric( DEVICESID, "Paused", 0, cdn ) ~= 0
            setMessage( standby and "Standby" or ( paused and "Paused" or "Enabled" ), DEVICESID, cdn, 20 )

            -- We were previously watering, so handle stop
            if watering ~= 0 then
                D("doSchedCheck() schedule ended")
                luup.variable_set(DEVICESID, "Remaining", 0, cdn)
                luup.variable_set(DEVICESID, "Watering", 0, cdn)
            end
                
            -- Mark zones idle
            local children = findChildrenByType(ZONETYPE)
            for _,czn in ipairs(children) do
                -- If zone belongs to this device...
                local zoneDev = getVarNumeric( DEVICESID, "ParentDevice", 0, czn) -- N.B. device SID here
                if zoneDev == cdn then -- this Zone belongs to this Device?
                    if watering ~= 0 then
                        D("doSchedCheck() setting idle zone info for #%1 (%2) %3", czn, luup.devices[czn].description, luup.devices[czn].id)
                        luup.variable_set(ZONESID, "Remaining", 0, czn)
                        luup.variable_set(ZONESID, "Watering", 0, czn)
                        luup.variable_set(SWITCHSID, "Target", 0, czn)
                        luup.variable_set(SWITCHSID, "Status", 0, czn)
                    end
                    local msg = ( standby or paused ) and "Standby" or ( ( getVarNumeric( ZONESID, "Enabled", 1, czn ) ~= 0 ) and "Enabled" or "Disabled" )
                    setMessage( msg, ZONESID, czn, 0 )
                end
            end
            
            -- Do same for schedules
            children = findChildrenByType(SCHEDULETYPE)
            for _,czn in ipairs(children) do
                -- If zone belongs to this device...
                local schedDev = getVarNumeric( DEVICESID, "ParentDevice", 0, czn) -- N.B. device SID here
                if schedDev == cdn then -- this Sched belongs to this Device?
                    if watering ~= 0 then
                        D("doSchedCheck() setting idle schedule info for #%1 (%2) %3", czn, luup.devices[czn].description, luup.devices[czn].id)
                        luup.variable_set(SCHEDULESID, "Remaining", 0, czn)
                        luup.variable_set(SCHEDULESID, "Watering", 0, czn)
                        luup.variable_set(SWITCHSID, "Target", 0, czn)
                        luup.variable_set(SWITCHSID, "Status", 0, czn)
                    end
                    local msg = ( standby or paused ) and "Standby" or ( ( getVarNumeric( SCHEDULESID, "Enabled", 1, czn ) ~= 0 ) and "Enabled" or "Disabled" )
                    setMessage( msg, SCHEDULESID, czn, 0 )
                end
            end
        end
    else
        -- Error. Log this, but don't treat as hard error unless it's an auth problem.
        L("doSchedCheck() request for current schedule for device %1 returned status %2 with %3", cd.id, status, schedule)
        if status == HTTPREQ_AUTHFAIL then
            hardFail(status, "Invalid API key")
        end
        return false
    end

    return true
end

local function doDeviceUpdate( data, serviceDev )
    D("doDeviceUpdate(data,%1)", serviceDev)
    local lastUpdate = os.time()

    showServiceStatus("Online (updating)", serviceDev)

    -- Save the service/person UID
    D("doDeviceUpdate(): person %1 (%2) user %3", data.fullName, data.email, data.username)
    luup.variable_set(SYSSID, "Fullname", data.fullName, serviceDev)
    luup.variable_set(SYSSID, "Email", data.email, serviceDev)
    luup.variable_set(SYSSID, "Username", data.username, serviceDev)
    
    -- Loop over devices
    for _,v in pairs(data.devices) do
        -- Find this device
        local cdn = findChildByUID( v.id )
        if cdn ~= nil then
            if v.status == nil or v.status:lower() ~= "online" then
                setMessage("*" .. tostring(v.status), DEVICESID, cdn, 99)
            elseif v.on == 0 then
                setMessage("Standby", DEVICESID, cdn, 10)
            elseif v.paused ~= nil and v.paused ~= 0 then -- from older version (pre-march 2018)
                setMessage("Paused", DEVICESID, cdn, 10)
            else
                setMessage("Enabled", DEVICESID, cdn, 0) -- default message
            end

            luup.variable_set(DEVICESID, "Status", v.status, cdn)
            luup.variable_set(DEVICESID, "On", v.on, cdn)
            luup.variable_set(DEVICESID, "Model", v.model or "", cdn)
            luup.variable_set(DEVICESID, "Serial", v.serialNumber or "", cdn)
            luup.variable_set(DEVICESID, "Paused", v.paused or "0", cdn)

            local rainEnd = luup.variable_get(DEVICESID, "RainDelayTime", cdn)
            if v.rainDelayStartDate then
                D("doDeviceUpdate() rain delay start %1 end %2", v.rainDelayStartDate, v.rainDelayExpirationDate)
                local rainStart = math.floor(v.rainDelayStartDate / 1000)
                rainEnd = math.floor(v.rainDelayExpirationDate / 1000)
                if rainStart <= os.time() and rainEnd > os.time() then
                    setMessage("Rain delay to " .. os.date("%c", rainEnd), DEVICESID, cdn, 0)
                    rainEnd = math.ceil((rainEnd - rainStart) / 60)
                else
                    rainEnd = 0
                end
                luup.variable_set(DEVICESID, "RainDelayTime", rainEnd, cdn) -- save as minutes remaining
                luup.variable_set(DEVICESID, "RainDelay", 1, cdn) -- save as minutes remaining
            elseif rainEnd ~= 0 then
                luup.variable_set(DEVICESID, "RainDelayTime", 0, cdn)
                luup.variable_set(DEVICESID, "RainDelay", 0, cdn)
            end

            -- Now go through device's zones, setting data
            local hide = getVarNumeric(SYSSID, "HideZones", 0, serviceDev)
            local hideDisabled = getVarNumeric(SYSSID, "HideDisabledZones", 0, serviceDev)
            for _,z in pairs(v.zones) do
                local czn = findChildByUID( z.id )
                if czn ~= nil then
                    local localHide = hide
                    if hideDisabled ~=0 and z.enabled == 0 then localHide = 1 end
                    setMessage(choose(z.enabled, "Disabled", "Enabled"), ZONESID, czn, 0) -- default message for zone
                    luup.variable_set(ZONESID, "Enabled", z.enabled, czn)
                    luup.variable_set(ZONESID, "Number", z.zoneNumber or "", czn)
                    luup.variable_set(ZONESID, "Name", z.name or "", czn)
                    luup.variable_set(DEVICESID, "ParentDevice", cdn, czn) -- yes, DEVICESID, really
                    luup.attr_set("invisible", tostring(localHide), czn)
                else
                    -- Zone not found. Rachio's config may have changed behind our back.
                    -- Don't reset the device automatically, though, because user may
                    -- scenes and Lua that could be broken by the renumbering.
                    L("doDeviceUpdate() child for zone %1 not found--skipping", z.id)
                end
            end

            -- And over schedules...
            hide = getVarNumeric(SYSSID, "HideSchedules", 0, serviceDev)
            hideDisabled = getVarNumeric(SYSSID, "HideDisabledSchedules", 0, serviceDev)
            for _,z in pairs( arraymerge(v.scheduleRules, v.flexScheduleRules) ) do
                -- Find this device
                local csn = findChildByUID( z.id )
                if csn ~= nil then
                    if v.on == 0 or ( v.paused ~= nil and v.paused ~= 0 ) then
                        -- Iro is off, so we there won't be automatic watering.
                        setMessage("Suspended", SCHEDULESID, csn, 0)
                    else
                        setMessage(choose(z.enabled, "Disabled", "Enabled"), SCHEDULESID, csn, 0)
                    end

                    local zn = {}
                    for _,l in pairs(z.zones) do
                        table.insert(zn, (l.zoneId or "") .. "=" .. (l.duration or ""))
                    end
                    local localHide = hide
                    if hideDisabled ~= 0 and z.enabled == 0 then localHide = 1 end
                    luup.variable_set(SCHEDULESID, "Zones", table.concat(zn, ","), csn)
                    luup.variable_set(SCHEDULESID, "Enabled", z.enabled or "", csn)
                    luup.variable_set(SCHEDULESID, "Name", z.name or z.id, csn)
                    luup.variable_set(SCHEDULESID, "Summary", z.summary or "", csn)
                    luup.variable_set(SCHEDULESID, "RainDelay", z.rainDelay or "0", csn)
                    luup.variable_set(SCHEDULESID, "Type", z.type or "FIXED", csn)
                    luup.variable_set(SCHEDULESID, "Duration", z.totalDuration or "", csn)
                    luup.variable_set(DEVICESID, "ParentDevice", cdn, csn) -- yes, DEVICESID, really
                    luup.attr_set("invisible", tostring(localHide), csn)
                else
                    -- Rachio data pointed us to a device we can't find. Forcing a reset
                    -- of the child devices might be unfriendly, as it renumbers (and
                    -- possibly renames) the children, which could break scenes and Lua
                    -- the user has configured. So log, but do nothing.
                    L("doDeviceUpdate() child for schedule %1 not found--skipping", z.id)
                end
            end
        else
            -- Rachio data pointed us to a device we can't find. Forcing a reset
            -- of the child devices might be unfriendly, as it renumbers (and
            -- possibly renames) the children, which could break scenes and Lua
            -- the user has configured. So log, but do nothing.
            L("doDeviceUpdate() child for device %1 not found--skipping", v.id)
        end
    end

    -- Successful update.
    return true
end

local function setUpDevices(data, serviceDev)
    D("setUpDevices(data,%1)", serviceDev)
    if serviceDev == nil then serviceDev = serviceDevice end

    showServiceStatus("Online (configuring)", serviceDev)

    -- Save the service/person UID
    -- D("setUpDevices(): person %1 (%2) user %3", data.fullName, data.email, data.username)
    L("Taking inventory")
    luup.variable_set(SYSSID, "RachioID", data.id, serviceDev)
    luup.variable_set(SYSSID, "Username", data.username, serviceDev)
    luup.variable_set(SYSSID, "Fullname", data.fullName, serviceDev)
    luup.variable_set(SYSSID, "Email", data.email, serviceDev)

    -- Sync our child devices with Rachio's devices and zones.
    local changes = 0
    local ptr = luup.chdev.start(serviceDev)

    -- Now pass through the devices again and enumerate all the zones for each.
    local knownDevices = map(findChildrenByType(DEVICETYPE), function( index, value ) return luup.devices[value].id, true end)
    for _,v in pairs(data.devices) do
        D("setUpDevices(): device " .. tostring(v.id) .. " model " .. tostring(v.model))
        local cdn = findChildByUID( v.id )
        if cdn == nil then
            -- New device
            changes = changes + 1
            D("setUpDevices() adding child for device " .. tostring(v.id))
        else
            luup.attr_set( "category_num", 1, cdn )
            luup.attr_set( "subcategory_num", 0, cdn )
        end

        -- Always append child (embedded) device. Pass UID as id (string 3), and also initialize UID service variable.
        luup.chdev.append( serviceDev, ptr, v.id, v.name, "", "D_RachioDevice1.xml", "", SYSSID .. ",RachioID=" .. v.id, true )

        -- Child exists or was created, remove from known list
        knownDevices[v.id] = nil

        -- Now go through zones for this device...
        local knownZones = map(findChildrenByType(ZONETYPE), function( index, value ) return luup.devices[value].id, true end)
        for _,z in pairs(v.zones) do
            D("setUpDevices():     zone " .. tostring(z.zoneNumber) .. " " .. tostring(z.name))
            local czn = findChildByUID( z.id )
            if czn == nil then
                -- New zone
                changes = changes + 1
                D("setUpDevices() adding child device for zone " .. z.id .. " number " .. z.zoneNumber .. " " .. z.name)
            else
                luup.attr_set( "category_num", 3, czn )
                luup.attr_set( "subcategory_num", 7, czn )
            end

            -- Always append child device. Pass UID as id (string 3), and also initialize UID service variable.
            luup.chdev.append( serviceDev, ptr, z.id, z.name, "", "D_RachioZone1.xml", "", SYSSID..",RachioID=" .. z.id, true )

            -- Remove from known list
            knownZones[z.id] = nil
        end
        for _ in pairs(knownZones) do changes = changes + 1 break end

        -- And schedules
        local knownSchedules = map(findChildrenByType(SCHEDULETYPE), function( index, value ) return luup.devices[value].id, true end)
        for _,z in pairs( arraymerge(v.scheduleRules, v.flexScheduleRules) ) do
            D("setUpDevices():     schedule %1 name %2", z.id, z.name)
            local csn = findChildByUID( z.id )
            if csn == nil then
                -- New schedule
                changes = changes + 1
                D("setUpDevices() adding child for schedule %1", z.id)
            else
                luup.attr_set( "category_num", 3, csn )
                luup.attr_set( "subcategory_num", 7, csn )
            end

            luup.chdev.append( serviceDev, ptr, z.id, z.name, "", "D_RachioSchedule1.xml", "", SYSSID .. ",RachioID=" .. z.id, true )

            knownSchedules[z.id] = nil
        end
        for _ in pairs(knownSchedules) do changes = changes + 1 break end
    end
    for _ in pairs(knownDevices) do changes = changes + 1 break end

    -- Finished enumerating zones for this device. If we changed any, sync() will reload Luup now.
    L("Inventory completed, %1 changes to configuration.", changes)
    luup.chdev.sync( serviceDev, ptr )
    return changes == 0
end

-- -----------------------------------------------------------------------------
--
-- G E N E R I C   P L U G I N   F U N C T I O N S
--
-- -----------------------------------------------------------------------------

local function checkFirmware(dev)
    if dev == nil then dev = serviceDevice end
    D("checkFirmware(%1) version=%1, in parts %2.%3.%4", luup.version,
        luup.version_branch, luup.version_major, luup.version_minor)

    -- Look for UI7 or better. We don't support openLuup at the moment because it does
    -- not support UDNs.
    if isOpenLuup then return true end
    if luup.version_branch ~= 1 or luup.version_major < 7 then
        return false
    end

    -- Bug in Vera UI parameter handling prevents correct passing of parameters
    -- from UI to action.
    -- See http://forum.micasaverde.com/index.php/topic,49752.msg326598.html#msg326598
    if luup.version_minor == 947
            or luup.version_minor == 2931
            or luup.version_minor == 2935
            or luup.version_minor == 2937 then
        return false
    end

    -- We're good.
    local check = luup.variable_get(SYSSID, "UI7Check", dev)
    if check ~= "true" then
        luup.variable_set(SYSSID, "UI7Check", "true", dev)
    end
    return true
end

-- runOnce() for one-time initialization; compares _CONFIGVERSION constant to
-- Version state var, does something if they're different.
local function runOnce(pdev)
    local s = getVarNumeric(SYSSID, "Version", 0, pdev)
    D("runOnce(%1) _CONFIGVERSION=%2, device version=%3", pdev, _CONFIGVERSION, s)
    if s == 0 then
        -- First-ever run
        L("runOnce() creating config")
        luup.variable_set(SYSSID, "APIKey", "", pdev)
        luup.variable_set(SYSSID, "Enabled", "1", pdev)
        luup.variable_set(SYSSID, "PID", "", pdev)
        luup.variable_set(SYSSID, "ServiceCheck", HTTPREQ_AUTHFAIL, pdev)
        luup.variable_set(SYSSID, "HideZones", "0", pdev)
        luup.variable_set(SYSSID, "HideDisabledZones", "0", pdev)
        luup.variable_set(SYSSID, "HideSchedules", "0", pdev)
        luup.variable_set(SYSSID, "HideDisabledSchedules", "0", pdev)
        luup.variable_set(SYSSID, "CycleMult", "1", pdev)
        luup.variable_set(SYSSID, "LastUpdate", "0", pdev)
        luup.variable_set(SYSSID, "DailyCalls", "0", pdev)
        luup.variable_set(SYSSID, "DailyStamp", "0", pdev)
        luup.variable_set(SYSSID, "Version", _CONFIGVERSION, pdev)
        return
    end

    -- No per-version changes yet. e.g. if s < 00103 then ...
    if s < 00106 then 
        L("Upgrading configuration to 00106...")
        luup.variable_set(SYSSID, "PID", "", pdev)
        luup.variable_set(SYSSID, "DailyCalls", "0", pdev)
        luup.variable_set(SYSSID, "DailyStamp", "0", pdev)
    end        
    if s < 00107 then
        L("Upgrading configuration to 00107...")
        -- Convert linking variables from UDNs to device numbers
        local l = findChildrenByType(ZONETYPE)
        for _,d in ipairs(l) do
            local p = luup.variable_get( DEVICESID, "ParentDevice", d ) or ""
            if p ~= "" and p:sub(0,5) == "uuid:" then
                local dd,nn = resolveDevice( p )
                if dd ~= nil then
                    luup.variable_set( DEVICESID, "ParentDevice", nn, d )
                end
            end
        end
        l = findChildrenByType(SCHEDULETYPE)
        for _,d in ipairs(l) do
            local p = luup.variable_get( DEVICESID, "ParentDevice", d ) or ""
            if p ~= "" and p:sub(0,5) == "uuid:" then
                local dd,nn = resolveDevice( p )
                if dd ~= nil then
                    luup.variable_set( DEVICESID, "ParentDevice", nn, d )
                end
            end
        end
    end
    if s < 00108 then
        L("Upgrading configuration to 00108...")
        luup.variable_set(SYSSID, "Enabled", "1", pdev)
    end

    -- Update version state var.
    if (s ~= _CONFIGVERSION) then
        luup.variable_set(SYSSID, "Version", _CONFIGVERSION, pdev)
    end
end

-- Return the plugin version string
function getVersion()
    return _PLUGIN_VERSION, _CONFIGVERSION
end

local function init(pdev)
    D("init(%1)", pdev)

    showServiceStatus("Initializing...", pdev)

    -- Pre-flight check...
    A(json ~= nil, "Missing JSON module (dkjson or json)")
    A(http ~= nil, "Missing socket.http")
    A(https ~= nil, "Missing ssl.http")
    A(ltn12 ~= nil, "Missing ltn12")

    -- Clear runStamp and arm for initial set-up query
    runStamp = 0
    tickCount = 0
    lastTick = 0
    updatePending = false
    nextUpdate = 0
    firstRun = true
    messages = {}

    -- Clear cycleMult
    luup.variable_set(SYSSID, "CycleMult", "1", pdev)

    return true
end

-- Get things moving...
local function run(pdev)
    D("run(%1)", pdev)

    scheduleUpdate( 5, true )
    D("run(): scheduled first step, done")

    luup.set_failure(0, pdev)

    return true, true -- signal success and separate thread running
end

-- Initialize.
function start(pdev)
    L("starting plugin version %2 device %1", pdev, _PLUGIN_VERSION)
    pdev = tonumber(pdev or "" ,10)
    
    A( serviceDevice==0, "Another instance of the service is running!" )
    serviceDevice = pdev

    -- Check for ALTUI and OpenLuup
    for k,v in pairs(luup.devices) do
        if v.device_type == "urn:schemas-upnp-org:device:altui:1" then
            D("start() detected ALTUI at %1", k)
            isALTUI = true
            local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
                { newDeviceType=SYSTYPE, newScriptFile="J_Rachio1_ALTUI.js", newDeviceDrawFunc="Rachio1_ALTUI.ServiceDraw" },
                k )
            D("start() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
            local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
                { newDeviceType=DEVICETYPE, newScriptFile="J_Rachio1_ALTUI.js", newDeviceDrawFunc="Rachio1_ALTUI.DeviceDraw" },
                k )
            D("start() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
            local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
                { newDeviceType=SCHEDULETYPE, newScriptFile="J_Rachio1_ALTUI.js", newDeviceDrawFunc="Rachio1_ALTUI.ScheduleDraw" },
                k )
            D("start() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
            local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
                { newDeviceType=ZONETYPE, newScriptFile="J_Rachio1_ALTUI.js", newDeviceDrawFunc="Rachio1_ALTUI.ZoneDraw" },
                k )
            D("start() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
        elseif v.device_type == "openLuup" then
            D("start() detected openLuup")
            isOpenLuup = true
        end
    end

    -- Check UI version
    if not checkFirmware(pdev) then
        hardFail(HTTPREQ_GENERICERROR, "Offline (unsupported firmware)")
    end

    -- One-time stuff
    runOnce(pdev)

    -- Initialize
    firstRun = true
    
    if getVarNumeric( SYSSID, "Enabled", 1, pdev ) == 0 then
        hardFail(HTTPREQ_GENERICERROR, "Offline (disabled)")
    end
    
    if getVarNumeric( SYSSID, "DebugMode", 0, pdev ) ~= 0 then
        debugMode = true
        D("start() debug mode enabled by state variable")
    end
    
    local iv = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, pdev)
    if iv < DEFAULT_INTERVAL then
        L({level=2,msg="Warning: Interval is %1; values < %2 are likely to exceed Rachio's daily API request quota."}, iv, DEFAULT_INTERVAL)
    end
    
    if init(pdev) then
        -- Start
        run(pdev)
        return true, "OK", _PLUGIN_NAME
    else
        hardFail(HTTPREQ_GENERICERROR, "Offline (failed init)")
        return false, "Initialization failed", _PLUGIN_NAME
    end
end

function stop(pdev)
    D("stop(%1)", pdev)
    if pdev == nil then pdev = serviceDevice end
    pdev = tonumber(pdev,10)

    -- Setting runStamp to 0 effectively kills the child tick process on the
    -- next cycle
    runStamp = 0
    showServiceStatus("Offline (stopped)", pdev)
end

-- Do interval-based stuff. This is called using pcall(), so any error thrown
-- will result in a stop of the active scheduling process.
local function ptick(pdev, forced)
    D("ptick(%1,%2)", pdev, forced)
    
    local now = os.time()
    local cycleMult = getVarNumeric(SYSSID, "CycleMult", 1, pdev)
    
    -- Set schedRunning flag to false. Any controller running a schedule will set it.
    schedRunning = false

    -- Fetch person data. In Rachio API, the direct person query reports
    -- everything, so do as much with that report as we can.
    local person = luup.variable_get(SYSSID, "PID", pdev) or ""
    if person == "" then
        showServiceStatus("Identifying...", pdev)
        local status,data = getJSON("/public/person/info")
        luup.variable_set(SYSSID, "ServiceCheck", status, pdev)
        if status == HTTPREQ_AUTHFAIL then
            -- If API key isn't valid, exit without rescheduling. We can't work (at all).
            if data == 401 then
                -- API key set, but somehow not authorized
                hardFail(status, "Offline (invalid API key)")
            end
            hardFail(status, "Offline (API key not set)")
        end
        -- Check response for first-level problems
        if status ~= HTTPREQ_OK then
            if data == 429 then
                -- Rachio API says we've queried too much (limit 1700/day)
                -- Defer queries for at least an hour.
                local iv = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, pdev)
                cycleMult = math.ceil( 3600 / iv )
                L({level=2,msg="Rachio API reporting exceeded daily request quota. Delaying at least one hour before retrying."})
                showServiceStatus("Offline (quota exceeded--delaying)", pdev)
            else
                -- Soft fail of some kind. Double poll interval and wait to retry.
                L("Can't identify, invalid API response: %1", data)
                if (cycleMult < MAX_CYCLEMULT) then cycleMult = cycleMult * 2 end
                showServiceStatus("Offline (error--delaying)", pdev)
            end
        elseif data.id ~= nil and data.id ~= "" then
            -- Good!
            luup.variable_set(SYSSID, "PID", data.id, pdev)
            person = data.id
        else    
            hardFail(status, "Offline (no auth)")
        end
    end

    if person ~= "" then
        -- Now we know who, query for what...
        showServiceStatus("Online (updating)", pdev)
        local problem = false
        local lastUpdate = getVarNumeric( SYSSID, "LastUpdate", 0, pdev )
        if forced or firstRun or ( os.time() >= ( lastUpdate + getVarNumeric( SYSSID, "DeviceInterval", 3600, pdev ) ) ) then
            local status,data = getJSON("/public/person/" .. person)
            luup.variable_set(SYSSID, "ServiceCheck", status, pdev)
            if status ~= HTTPREQ_OK then
                problem = true
                if data == 429 then
                    -- Rachio API quota exceeded
                    local iv = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, pdev)
                    cycleMult = math.ceil( 3600 / iv )
                    L({level=2,msg="Rachio API reporting exceeded daily request quota. Delaying at least one hour before retrying."})
                    showServiceStatus("Offline (quota exceeded--delaying)", pdev)
                else
                    L({level=2,msg="Full query, invalid API response: %1"}, data)
                    if (cycleMult < MAX_CYCLEMULT) then cycleMult = cycleMult * 2 end
                    showServiceStatus("Offline (error--delaying)", pdev)
                end
            else
                -- Good response. Do our device update.
                if firstRun then
                    L("First run, set up devices")
                    setUpDevices( data, pdev )
                    firstRun = false -- don't do this again
                end

                -- Do device update (same data as set up if it was done)
                if doDeviceUpdate( data, pdev ) then
                    luup.variable_set( SYSSID, "ServiceCheck", 0, pdev )
                    luup.variable_set( SYSSID, "LastUpdate", now, pdev )
                end
            end
        end

        -- Each interval, we do a schedule check on each controller.
        -- N.B. Schedule check for each device is one query per...
        if not problem then
            -- Check schedule on each controller
            local devices = findChildrenByType(DEVICETYPE)
            for _,d in pairs(devices) do 
                D("ptick() doing schedule check on %1 (%2)", d, luup.devices[d].description)
                if not doSchedCheck( d, nil, pdev ) then 
                    problem = true
                    break 
                else
                    showServiceStatus( "Online", pdev )
                end
            end
        end
        
        -- Reset cycleMult if everything went smoothly.
        if not problem then
            cycleMult = 1
        end
    end
    postMessages()
    
    -- Check our call count...
    local ncall = getVarNumeric(SYSSID, "DailyCalls", 0)
    if ncall >= nthresh then
        local iv = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, pdev)
        L({level=2,msg="WARNING! Number of daily Rachio API calls high (%1 so far); consider increasing Interval (currently %2)"},
            ncall, iv)
        nthresh = nthresh + 50 -- warn every first calls after first hit
    end

    luup.variable_set(SYSSID, "CycleMult", cycleMult, pdev)
    return true
end

-- Run a clock interval. This is called periodically, and reschedules itself, or not.
-- It will not reschedule itself if there's a "permanent" error (e.g. no APIKey set).
function tick(stepStampCheck)
    D("tick(%1) serviceDevice=%2", stepStampCheck, serviceDevice)

    -- See if stamps match. If not, runStamp has changed and another thread is running, so quit.
    local stepStamp = tonumber(stepStampCheck,10)
    if stepStamp ~= runStamp then
        D("tick() stamp mismatch, expecting %1 got %2. Another thread running, bye!", runStamp, stepStampCheck)
        return
    end
    
    -- Flag no task scheduled now
    nextUpdate = 0
    
    -- If we've been disabled, stop this.
    if getVarNumeric(SYSSID, "Enabled", 1, serviceDevice) == 0 then
        hardFail(HTTPREQ_GENERICERROR, "Offline (disabled)")
    end

    -- Make sure we're working with our parent (plugin) device
    tickCount = tickCount + 1
    D("tick() running serviceDevice=%2, tickCount=%1", tickCount, serviceDevice)

    -- Check last tick time. If too soon, skip this
    local tooSoon = (lastTick + 5) > os.time()
    lastTick = os.time()

    -- Use pcall() to run the plugin's stuff. If it fails, we stay in control.
    local success, err
    if tooSoon then
        D("tick() too soon, skipping ptick")
        success = true -- fake it
    elseif updatePending then
        D("tick() update pending, skipping ptick")
        success = true -- fake it
    else
        updatePending = true -- don't allow other updates while we're working
        success,err = pcall( ptick, serviceDevice )
        updatePending = false
        D("tick() ptick returned %1,%2", success, err)
    end
    if success then
        -- No errors, schedule next event (unless stepStamp == -1, then it's a direct/special call)
        local cycleMult = getVarNumeric(SYSSID, "CycleMult", 1, serviceDevice)
        local nextCycleDelay = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, serviceDevice)
        if schedRunning then 
            nextCycleDelay = getVarNumeric(SYSSID, "ActiveInterval", 30, serviceDevice)
        end
        nextCycleDelay = nextCycleDelay * cycleMult
        if nextCycleDelay < 1 then nextCycleDelay = 60 
        elseif nextCycleDelay > MAX_INTERVAL then nextCycleDelay = MAX_INTERVAL end
        D("tick() cycle finished, next in " .. nextCycleDelay .. " seconds, cycleMult is " .. tostring(cycleMult))
        scheduleUpdate( nextCycleDelay )
        return
    end

    -- Hard stop. The plugin will set pluginStatus if it has already trapped the
    -- the error and set up all of its messages, etc., so only react here if
    -- pluginStatus isn't set.
    L("tick(): ptick() error: %1, aborting timer cycle.", err)
    if err == nil or err.pluginStatus == nil then
        -- We didn't stop because of a plugin problem, so issue our own
        -- plugin hardFail
        hardFail(HTTPREQ_GENERICERROR, "Offline (internal error)")
    end
end

local function startJob( devnum )
    if (luup.devices[devnum] or {}).device_type == DEVICETYPE then
        luup.variable_set(DEVICESID, "Message", "Operation pending... please wait", devnum) -- direct
    end
end

local function finishJob( devnum )
    scheduleUpdate( 10, true )
end

function rachioServiceHideZones( devnum, hideAll, hideDisabled )
    D("rachioServiceHideZones(%1,%2,%3)", devnum, hideAll, hideDisabled)
    if hideAll ~= nil then
        hideAll = tonumber(hideAll,10)
        if hideAll == nil then error("Invalid hideAll value") end
        luup.variable_set(SYSSID, "HideZones", hideAll, devnum)
    end
    if hideDisabled ~= nil then
        hideDisabled = tonumber(hideDisabled,10)
        if hideDisabled == nil then error("Invalid hideDisabled value") end
        luup.variable_set(SYSSID, "HideDisabledZones", hideDisabled, devnum)
    end

    hideAll = getVarNumeric(SYSSID, "HideZones", 0, devnum)
    hideDisabled = getVarNumeric(SYSSID, "HideDisabledZones", 0, devnum)
    local ch = findChildrenByType(ZONETYPE)
    for _,zoneDev in pairs(ch) do
        local hideThis = hideAll
        if hideDisabled ~= 0 then
            local enabled = getVarNumeric(ZONESID, "Enabled", 1, zoneDev)
            if enabled == 0 then hideThis = 1 end
        end
        luup.attr_set('invisible', tostring(hideThis), zoneDev)
    end
end

function rachioServiceHideSchedules( devnum, hideAll, hideDisabled )
    D("rachioServiceHideSchedules(%1,%2)", devnum, hideAll, hideDisabled)
    if hideAll ~= nil then
        hideAll = tonumber(hideAll,10)
        if hideAll == nil then error("Invalid hideAll value") end
        luup.variable_set(SYSSID, "HideSchedules", hideAll, devnum)
    end
    if hideDisabled ~= nil then
        hideDisabled = tonumber(hideDisabled,10)
        if hideDisabled == nil then error("Invalid hideDisabled value") end
        luup.variable_set(SYSSID, "HideDisabledSchedules", hideDisabled, devnum)
    end

    hideAll = getVarNumeric(SYSSID, "HideSchedules", 0, devnum)
    hideDisabled = getVarNumeric(SYSSID, "HideDisabledSchedules", 0, devnum)
    local ch = findChildrenByType(SCHEDULETYPE)
    for _,schedDev in pairs(ch) do
        local hideThis = hideAll
        if hideDisabled ~= 0 then
            local enabled = getVarNumeric(SCHEDULESID, "Enabled", 1, schedDev)
            if enabled == 0 then hideThis = 1 end
        end
        luup.attr_set('invisible', tostring(hideThis), schedDev)
    end
end

function rachioServiceReset( devnum )
    D("rachioServiceReset(%1)", devnum)
    L("Service reset requested!")
    showServiceStatus("Resetting...", devnum)
    luup.variable_set( SYSSID, "PID", "", devnum )
    local ptr = luup.chdev.start( devnum )
    luup.chdev.sync( devnum, ptr )
    -- luup restart will happen, should take care of the rest
end

-- Tell Rachio to stop all watering on device
function rachioDeviceStop( devnum )
    D("rachioDeviceStop(%1)", devnum)

    startJob(devnum)
    local d = luup.devices[ devnum ] or {}
    L("Stop watering request on %1 (%2)", devnum, d.description)
    local status,resp = getJSON("/public/device/stop_water", "PUT", { id=d.id })
    D("rachioDeviceStop() getJSON returned %1,%2", status,resp)
    finishJob(devnum)
    return status == HTTPREQ_OK
end

-- Tell Rachio to turn device features off
function rachioDeviceOff( devnum )
    D("rachioDeviceOff(%1)", devnum)

    -- Call API to turn off controller
    startJob(devnum)
    local d = luup.devices[ devnum ] or {}
    L("Request for controller standby %1 (%2)", devnum, d.description)
    local status,resp = getJSON("/public/device/off", "PUT", { id=d.id })
    D("rachioDeviceOff() getJSON returned %1,%2", status,resp)
    finishJob(devnum)
    return status == HTTPREQ_OK
end

-- Tell Rachio to turn device features on
function rachioDeviceOn( devnum )
    D("rachioDeviceOn(%1)", devnum)

    -- Call API to turn on controller
    startJob(devnum)
    local d = luup.devices[ devnum ] or {}
    L("Request for controller active %1 (%2)", devnum, d.description)
    local status,resp = getJSON("/public/device/on", "PUT", { id=d.id })
    D("rachioDeviceOn() getJSON returned %1,%2", status,resp)
    finishJob(devnum)
    return status == HTTPREQ_OK
end

function rachioStartMultiZone( devnum, zoneData )
    D("rachioStartMultiZone(%1,%2)", devnum, zoneData)

    startJob(devnum)
    local req = { zones={} }
    local z = split( zoneData, "," )
    local n = 0
    for _,t in ipairs(z) do
        local m = split( t, "=" ) -- ??? can do faster inline with a match?
        local zone = findZoneByNumber( devnum, m[1] )
        if zone ~= nil then
            local dur = tonumber(m[2],10)
            if dur < 0 then dur = 0 elseif dur > 180 then dur = 180 end
            n = n + 1
            req["zones"][n] = { id=zone.id, duration=dur*60, sortOrder=n }
        else
            -- ??? error?
        end
    end
    local rd = json.encode(req)
    D("rachioStartMultiZone() req data is %1", rd)
    if n > 0 then
        local status,resp = getJSON("/public/zone/start_multiple", "PUT", req)
        D("rachioStartMultiZone() getJSON returned %1,%2", status,resp)
        if status == HTTPREQ_OK then
            schedRunning = true
        end
    end
    finishJob(devnum)
    return true
end

-- Tell Rachio to start watering a zone
function rachioStartZone( devnum, durMinutes )
    D("rachioStartZone(%1,%2)", devnum, durMinutes)

    local controller = getVarNumeric( DEVICESID, "ParentDevice", 0, devnum )
    startJob(controller)
    if durMinutes == nil then durMinutes = 0 end
    durMinutes = tonumber(durMinutes,10)
    if durMinutes < 0 then durMinutes = 0 elseif durMinutes > 180 then durMinutes = 180 end

    local d = luup.devices[ devnum ]
    local zn = getVarNumeric( ZONESID, "Number", 0, devnum )
    L("Requesting manual zone start %1 (%2) for %3", zn, d.id, durMinutes)
    local status,resp = getJSON("/public/zone/start", "PUT", { id=d.id, duration=durMinutes*60 })
    D("rachioStartZone() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        luup.variable_set(SWITCHSID, "Target", 1, devnum)
        schedRunning = true
    end
    finishJob(controller)
    return status == HTTPREQ_OK
end

-- Tell Rachio to start a schedule
function rachioRunSchedule( devnum )
    D("rachioRunSchedule(%1)", devnum)

    local controller = getVarNumeric( DEVICESID, "ParentDevice", 0, devnum )
    startJob(controller)
    local d = luup.devices[ devnum ] or {}
    L("Requesting manual schedule start %1 (%2)", d.description, d.id)
    local status,resp = getJSON("/public/schedulerule/start", "PUT", { id=d.id })
    D("rachioRunSchedule() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        luup.variable_set(SWITCHSID, "Target", 1, devnum)
        schedRunning = true
    end
    finishJob(controller)
    return status == HTTPREQ_OK
end

-- Tell Rachio to skip a schedule
function rachioSkipSchedule( devnum )
    D("rachioSkipSchedule(%1)", devnum)

    local controller = getVarNumeric( DEVICESID, "ParentDevice", 0, devnum )
    startJob(controller)
    local d = luup.devices[ devnum ] or {}
    local status,resp = getJSON("/public/schedulerule/skip", "PUT", { id=d.id })
    D("rachioSkipSchedule() getJSON returned %1,%2", status,resp)
    finishJob(controller)
    return status == HTTPREQ_OK
end

-- Switch Status
function rachioSwitchSetTarget( devnum, newtarget )
    if luup.devices[devnum] == nil then return end
    newtarget = tonumber(newtarget) or 0
    if newtarget == 0 then
        local controller = getVarNumeric( DEVICESID, "ParentDevice", 0, devnum )
        return rachioDeviceStop( controller )
    elseif luup.devices[devnum].device_type == ZONETYPE then
        return rachioStartZone( devnum, 3 )
    elseif luup.devices[devnum].device_type == SCHEDULETYPE then
        return rachioRunSchedule( devnum )
    end
    return false
end

function rachioSetDebug( devnum, enable )
    D("rachioSetDebug(%1,%2)", devnum, enable)
    if enable == 1 or enable == "1" or enable == true or enable == "true" then
        debugMode = true
        D("rachioSetDebug() debug logging enabled")
    end
end

function testAction( devnum, settings )
    D("testAction(%1,%2)", devnum, settings)
    return true
end

local function issKeyVal( k, v, s )
    if s == nil then s = {} end
    s["key"] = tostring(k)
    s["value"] = tostring(v)
    return s
end

local function getDevice( dev, pdev, v )
    local dkjson = json or require("dkjson")
    if v == nil then v = luup.devices[dev] end
    local devinfo = { 
          devNum=dev
        , ['type']=v.device_type
        , description=v.description or ""
        , room=v.room_num or 0
        , udn=v.udn or ""
        , id=v.id
        , ['device_json'] = luup.attr_get( "device_json", dev )
        , ['impl_file'] = luup.attr_get( "impl_file", dev )
        , ['device_file'] = luup.attr_get( "device_file", dev )
        , manufacturer = luup.attr_get( "manufacturer", dev ) or ""
        , model = luup.attr_get( "model", dev ) or ""
    }
    local rc,t,httpStatus = luup.inet.wget("http://localhost/port_3480/data_request?id=status&DeviceNum=" .. dev .. "&output_format=json", 15)
    if httpStatus ~= 200 or rc ~= 0 then 
        devinfo['_comment'] = string.format( 'State info could not be retrieved, rc=%d, http=%d', rc, httpStatus )
        return devinfo
    end
    local d = dkjson.decode(t)
    local key = "Device_Num_" .. dev
    if d ~= nil and d[key] ~= nil and d[key].states ~= nil then d = d[key].states else d = nil end
    devinfo.states = d or {}
    return devinfo
end

function requestHandler(lul_request, lul_parameters, lul_outputformat)
    D("requestHandler(%1,%2,%3) serviceDevice=%4", lul_request, lul_parameters, lul_outputformat, serviceDevice)
    local action = lul_parameters['action'] or lul_parameters['command'] or ""
    local deviceNum = tonumber( lul_parameters['device'], 10 ) or serviceDevice
    if action == "debug" then
        debugMode = not DebugMode
        return "Debug is now " .. debugMode and "on" or "off", "text/plain"
    end

    if action:sub( 1, 3 ) == "ISS" then
        -- ImperiHome ISS Standard System API, see http://dev.evertygo.com/api/iss#types
        local dkjson = json or require('dkjson')
        local path = lul_parameters['path'] or action:sub( 4 ) -- Work even if I'home user forgets &path=
        if path == "/system" then
            return dkjson.encode( { id=_PLUGIN_NAME .. "-" .. luup.pk_accesspoint, apiversion=1 } ), "application/json"
        elseif path == "/rooms" then
            local roomlist = { { id=0, name="No Room" } }
            for rn,rr in pairs( luup.rooms ) do 
                table.insert( roomlist, { id=rn, name=rr } )
            end
            return dkjson.encode( { rooms=roomlist } ), "application/json"
        elseif path == "/devices" then
            local devices = {}
            for lnum,ldev in pairs( luup.devices ) do
                -- ??? Can we figure out DevRain?
                if ldev.device_type == ZONETYPE then
                    local issinfo = {}
                    local watering = getVarNumeric( ZONESID, "Watering", 0, lnum )
                    local icon = "ok"
                    if watering ~= 0 then icon = "watering" end
                    table.insert( issinfo, issKeyVal("Status", watering) )
                    table.insert( issinfo, issKeyVal("pulseable", "0") )
                    table.insert( issinfo, issKeyVal("defaultIcon", "https://www.toggledbits.com/assets/rachio/rachio-zone-" .. icon .. "-60x60.png" ) )
                    local dev = { id=tostring(lnum), 
                        name=ldev.description or ("#" .. lnum), 
                        ["type"]="DevSwitch", 
                        params=issinfo }
                    if ldev.room_num ~= nil and ldev.room_num ~= 0 then dev.room = tostring(ldev.room_num) end
                    table.insert( devices, dev )
                elseif ldev.device_type == SCHEDULETYPE then
                    local issinfo = {}
                    local watering = getVarNumeric( SCHEDULESID, "Watering", 0, lnum )
                    local icon = "ok"
                    if watering ~= 0 then icon = "running" end
                    table.insert( issinfo, issKeyVal("Status", watering) )
                    table.insert( issinfo, issKeyVal("pulseable", "0") )
                    table.insert( issinfo, issKeyVal("defaultIcon", "https://www.toggledbits.com/assets/rachio/rachio-schedule-" .. icon .. "-60x60.png" ) )
                    local dev = { id=tostring(lnum), 
                        name=ldev.description or ("#" .. lnum), 
                        ["type"]="DevSwitch", 
                        params=issinfo }
                    if ldev.room_num ~= nil and ldev.room_num ~= 0 then dev.room = tostring(ldev.room_num) end
                    table.insert( devices, dev )
                end
            end
            return dkjson.encode( { devices=devices } ), "application/json"
        else -- action
            local dev, act, p = string.match( path, "/devices/([^/]+)/action/([^/]+)/*(.*)$" )
            dev = tonumber( dev, 10 )
            if dev ~= nil and act ~= nil then
                act = string.upper( act )
                D("requestHandler() handling action path %1, dev %2, action %3, param %4", path, dev, act, p )
                if luup.devices[dev] == nil then
                    L("Invalid ISS request (device %1 not found): %2", dev, path)
                elseif act == "SETSTATUS" then
                    if luup.devices[dev].device_type == ZONETYPE then
                        local dur = 5
                        if p ~= "1" then dur = 0 end
                        luup.call_action( ZONESID, "StartZone", { durationMinutes=dur }, dev )
                    elseif luup.devices[dev].device_type == SCHEDULETYPE then
                        if p == "1" then
                            luup.call_action( SCHEDULESID, "RunSchedule", {}, dev )
                        else
                            -- To stop a schedule, we have to tell the controller (parent of schedule) to stop.
                            local controller = getVarNumeric( DEVICESID, "ParentDevice", 0, dev )
                            if luup.devices[controller] ~= nil then
                                -- No need to resolve; we can pass parent directly.
                                luup.call_action( DEVICESID, "DeviceStop", {}, controller )
                            else
                                L("ISS schedule stop could not be handled, parent device %1 for schedule %2 (%3) could not be located", controller, dev, luup.devices[dev].description)
                            end
                        end
                    end
                else
                    D("requestHandler(): ISS action %1 not handled, ignored", act)
                end
            else
                D("requestHandler(): ISS malformed action request %1", path)
            end
            return "{}", "application/json"
        end
    end
    
    if action == "status" then
        local dkjson = json or require("dkjson")
        if dkjson == nil then return "Missing dkjson library", "text/plain" end
        local st = {
            name=_PLUGIN_NAME,
            version=_PLUGIN_VERSION,
            configversion=_CONFIGVERSION,
            author="Patrick H. Rigney (rigpapa)",
            url=_PLUGIN_URL,
            ['type']=SYSTYPE,
            responder=serviceDevice,
            timestamp=os.time(),
            system = {
                version=luup.version,
                isOpenLuup=isOpenLuup,
                isALTUI=isALTUI,
                units=luup.attr_get( "TemperatureFormat", 0 ),
            },            
            devices={}
        }
        for k,v in pairs( luup.devices ) do
            if v.device_type == SYSTYPE or v.device_type == DEVICETYPE 
                or v.device_type == ZONETYPE or v.device_type == SCHEDULETYPE then
                local devinfo = getDevice( k, serviceDevice, v ) or {}
                table.insert( st.devices, devinfo )
            end
        end
        return dkjson.encode( st ), "application/json"
    end
    
    return "<html><head><title>" .. _PLUGIN_NAME .. " Request Handler"
        .. "</title></head><body bgcolor='white'>Request format: <tt>http://" .. (luup.attr_get( "ip", 0 ) or "...")
        .. "/port_3480/data_request?id=lr_" .. lul_request 
        .. "&action=...</tt><p>Actions: status | debug | ISS"
        .. "<p>Imperihome ISS URL: <tt>...&action=ISS&path=</tt><p>Documentation: <a href='"
        .. _PLUGIN_URL .. "' target='_blank'>" .. _PLUGIN_URL .. "</a></body></html>"
        , "text/html"
end
