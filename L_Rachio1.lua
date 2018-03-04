-- -----------------------------------------------------------------------------
--
-- L_Rachio1.lua
-- Rachio Plug-in for Vera implementation module
-- Copyright 2017 Patrick H. Rigney, All Rights Reserved
-- For information, see http://www.toggledbits.com/rachio/
--
-- $Id$
--
-- -----------------------------------------------------------------------------
--
-- TO-DO:
--   Flex schedules need separate D_.json file without skip/start (they can't do those).
--   What happens when Rachio has more than one account/shared... multiple person IDs? Different or same API keys?
--   Better icons? More state icons?
--   Set or clear a rain delay?
--   More watering stats? Weather? What's the API got?
--   What if a schedule ends early (RunEnds earlier, Duration shorter, than advertised)?
--   Schedules... seasonal adjustment? enable/disable? What does skip do, anyway?
--   Handle non-ONLINE status for device, propagate to zones and schedules?
--
-- -----------------------------------------------------------------------------

module("L_Rachio1", package.seeall)

local _PLUGIN_NAME = "Rachio"
local _PLUGIN_VERSION = "1.2"
local _PLUGIN_URL = "http://www.toggledbits.com/demii"
local _CONFIGVERSION = 00106

local debugMode = false

local API_BASE = "https://api.rach.io/1"

local SYSSID = "urn:toggledbits-com:serviceId:Rachio1"
local SYSTYPE = "urn:schemas-toggledbits-com:device:Rachio:1"

local DEVICESID = "urn:toggledbits-com:serviceId:RachioDevice1"
local DEVICETYPE = "urn:schemas-toggledbits-com:device:RachioDevice:1"

local ZONESID = "urn:toggledbits-com:serviceId:RachioZone1"
local ZONETYPE = "urn:schemas-toggledbits-com:device:RachioZone:1"

local SCHEDULESID = "urn:toggledbits-com:serviceId:RachioSchedule1"
local SCHEDULETYPE = "urn:schemas-toggledbits-com:device:RachioSchedule:1"

local HTTPREQ_OK = 0
local HTTPREQ_AUTHFAIL = 1
local HTTPREQ_STATUSERROR = 2
local HTTPREQ_JSONERROR = 3
local HTTPREQ_RATELIMIT = 4
local HTTPREQ_GENERICERROR = 99

local DEFAULT_INTERVAL = 180    -- Default interval between API polls; can be overriden by SYSSID/Interval
local MAX_CYCLEMULT = 256       -- Max multiplier for poll interval (doubles on each error up to this number)
local MAX_INTERVAL = 14400      -- Absolute max delay we'll allow

local runStamp = 0
local tickCount = 0
local lastTick = 0
local nthresh = 1360 -- threshold for API quota warnings
local updatePending = false
local firstRun = true
local messages = {}
local isALTUI = false
local isOpenLuup = false

local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require('dkjson')
if json == nil then json = require("json") end

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

-- Take a string and split it around sep, returning table (indexed) of substrings
-- For example abc,def,ghi becomes t[1]=abc, t[2]=def, t[3]=ghi
-- Returns: table of values, count of values (integer ge 0)
local function split(s, sep)
    local t = {}
    local n = 0
    if (#s == 0) then return t,n end -- empty string returns nothing
    local i,j
    local k = 1
    repeat
        i, j = string.find(s, sep or "%s*,%s*", k)
        if (i == nil) then
            table.insert(t, string.sub(s, k, -1))
            n = n + 1
            break
        else
            table.insert(t, string.sub(s, k, i-1))
            n = n + 1
            k = j + 1
        end
    until k > string.len(s)
    return t, n
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
    if dev == nil then dev = luup.device end
    local s = luup.variable_get(serviceid, name, dev)
    if (s == nil or s == "") then return dflt end
    s = tonumber(s, 10)
    if (s == nil) then return dflt end
    return s
end

-- Find the parent service device for the passed device
local function findServicePlugin( dev )
    if dev == nil then dev = luup.device end
    -- If we're the Service plugin, return immediately.
    if luup.device_supports_service(SYSSID, dev) then return dev end
    -- See if our hint to the service plugin is there, and use it if so.
    local d = luup.variable_get(SYSSID, "ParentService", dev)
    if d ~= nil then return d end
    -- Punt, just return whatever we got.
    return dev
end

-- Shortcut function to return state of SwitchPower1 Status variable
local function isServiceCheck()
    local p = findServicePlugin()
    local s = getVarNumeric( SYSSID, "ServiceCheck", "", p )
    if s == "" then return true end -- default is we really don't know, so say down
    return (s ~= "0")
end

function resolveDevice( dev )
    -- D("resolveDevice(%1)", dev)
    if dev == nil then return dev end
    local ndev = tonumber(dev,10)
    if ndev ~= nil and ndev > 0 and luup.devices[ndev] ~= nil then
        return luup.devices[ndev]
    end
    dev = dev:lower()
    if dev:sub(1,5) == "uuid:" then
        for _,v in pairs(luup.devices) do
            if v.udn == dev then return v end
        end
    end
    for _,v in pairs(luup.devices) do
        if v.id == dev then return v end
    end
    for _,v in pairs(luup.devices) do
        if v.description:lower() == dev then return v end
    end
    return nil
end

local function showServiceStatus(msg, dev)
    dev = findServicePlugin( dev )
    if dev == nil then dev = luup.devices end
    luup.variable_set(SYSSID, "Message", msg, dev)
end

local function setMessage(s, sid, dev, pri)
    if sid == nil then sid = SYSSID end
    if dev == nil then dev = luup.device end
    if pri == nil then pri = 0 end
    local d = resolveDevice(dev)
    local k = d.udn
    local l = messages[k]
    if l ~= nil and pri < l.pri then
        return
    end
    if s == nil then L(debug.traceback()) end
    messages[k] = { pri=pri, text=s, service=sid }
end

local function postMessages()
    -- ??? Can/should we use luup.device_message? Present in releases after Feb 2017
    for udn,node in pairs(messages) do
        -- D("postMessage() device %1 service %2 message %3", udn, node.service, node.text)
        luup.variable_set( node.service, "Message", node.text or "", udn )
    end
    messages = {}
end

local function findChildByUID( parentId, uid )
  if uid == nil then return nil end
  for _,v in pairs(luup.devices) do
    if v.device_num_parent == parentId and uid == v.id then
        return v
    end
  end
  return nil
end

local function findChildrenByType( parentId, typ )
    parentId = tonumber(parentId, 10)
    local result = {}
    local n = 0
    for _,v in pairs(luup.devices) do
        if v.device_num_parent == parentId and v.device_type == typ then
            result[v.id] = clone(v) -- ??? do we need to clone? doubtful...
            n = n + 1
        end
    end
    return result, n
end

local function findZoneByNumber( deviceId, zoneNumber )
    D("findZoneByNumber(%1,%2)", deviceId, zoneNumber)
    local parent = findServicePlugin(deviceId)
    local iro = resolveDevice(deviceId)
    if iro == nil then return nil end
    assert(iro.device_type == DEVICETYPE, "Device is not controller")
    D("findZoneByNumber() iro %2 udn is %1", iro.udn, iro.description)

    local zones = findChildrenByType(parent, ZONETYPE)
    zoneNumber = tonumber(zoneNumber,10)
    for _,v in pairs(zones) do
        -- Is this zone part of the Iro we're looking for?
        local pd = luup.variable_get(DEVICESID, "ParentDevice", v.udn)
        local zn = luup.variable_get(ZONESID, "Number", v.udn)
        D("findZoneByNumber() checking zone %1 number %2 for iro %3", v, zn, pd)
        if pd ~= nil and pd == iro.udn then
            if zn ~= nil and tonumber(zn,10) == zoneNumber then return v end
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
    local service = findServicePlugin( luup.device )
    if msg == nil then msg = "Offline" end
    luup.variable_set(SYSSID, "ServiceCheck", status, service)
    showServiceStatus(msg, service)

    -- Set status of devices and zones?
    local devices = findChildrenByType( service, DEVICETYPE )
    for _,devobj in pairs(devices) do
        setMessage("NO SERVICE", DEVICESID, devobj.id, 99)
        luup.variable_set(DEVICESID, "Message", "NO SERVICE", devobj.udn)
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
    local url = ( luup.variable_get( SYSSID, "APIBase", luup.device ) or API_BASE ) .. path
    if method == nil then method = "GET" end

    -- Check our query rate, fail if exceeded.
    if rateLimit() then return HTTPREQ_RATELIMIT, "API rate limit" end

    -- Get the API key
    local apiKey = luup.variable_get(SYSSID, "APIKey", luup.device)
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
    end
    if body ~= nil then
        tHeaders["Content-Length"] = string.len(body)
        src = ltn12.source.string(body)
    else
        src = nil
    end

    -- HTTP or HTTPS?
    local requestor
    if url:lower():find("https:") then
        requestor = https
    else
        requestor = http
    end
    
    -- Update call count.
    local parent = findServicePlugin(luup.device)
    local ncall = getVarNumeric(SYSSID, "DailyCalls", 0, parent) + 1
    local ntime = getVarNumeric(SYSSID, "DailyStamp", 0, parent)
    local today = math.floor(os.time() / 86400)
    if ntime ~= today then
        D("getJSON() call counter day changed, was %1 now %2, resetting counter", ntime, today)
        L("Made %1 API calls in last 24 hours. Resetting counter now.", ncall)
        ncall = 1
        luup.variable_set(SYSSID, "DailyStamp", today, parent)
    end 
    luup.variable_set(SYSSID, "DailyCalls", ncall, parent)
    if ( ncall % 100 ) == 0 then
        L("Milestone: %1 API calls made so far today.", ncall)
    else
        D("getJSON() daily call counter now %1", ncall)
    end

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

    -- See what happened.
    -- ??? Now that we're using a sink, respBody is always 1, so maybe revisit the tests below at some point (harmless now)
    D("getJSON() request returned httpStatus=%1, respBody=%2", httpStatus, respBody)
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

-- Handle schedule check. cd is device node, parentDevice is device number/id
local function doSchedCheck( cd, parentDevice )
    D("doSchedCheck(%1,%2)", cd.id, parentDevice)
    local status, schedule = getJSON("/public/device/" .. cd.id .. "/current_schedule")
    if status == HTTPREQ_OK then
        -- check schedule type? particulars for type?
        local watering = getVarNumeric(DEVICESID, "Watering", 0, cd.udn)
        if schedule.type ~= nil then
            -- ??? check zone ID, make sure it's zone we know
            -- ??? what does multiple zone schedule report?
            D("doSchedCheck() handling %1 schedule", schedule.type)
            local lastStart = math.floor( schedule.startDate / 1000 )

            local schedMessage = tostring(schedule.status) .. " " .. tostring(schedule.type)
            schedMessage = schedMessage:sub(1,1):upper() .. schedMessage:sub(2):lower()

            -- Use schedule stats and apply to device
            D("doSchedCheck: sched startDate %1 duration %2", schedule.startDate, schedule.duration)
            local durMinutes = math.ceil( schedule.duration / 60 ) -- duration for entire schedule
            local runEnds = lastStart + schedule.duration
            local remaining = math.ceil( (runEnds - os.time()) / 60 )
            if remaining < 1 then remaining = 1 end
            D("doSchedCheck: sched start %1 dur %2 ends %3 rem %4", lastStart, durMinutes, runEnds, remaining)
            luup.variable_set(DEVICESID, "LastStart", lastStart, cd.udn)
            luup.variable_set(DEVICESID, "RunEnds", runEnds, cd.udn)
            luup.variable_set(DEVICESID, "Duration", durMinutes, cd.udn)
            luup.variable_set(DEVICESID, "Remaining", remaining, cd.udn)
            luup.variable_set(DEVICESID, "Watering", 1, cd.udn)
            -- Now apply to schedule if known device (e.g. not a manual schedule, for which we would not have a device)
            local cs = findChildByUID( parentDevice, schedule.scheduleRuleId )
            if cs ~= nil then
                D("doSchedCheck() setting schedule info for %1 (%2) remaining %3", schedule.scheduleId, cs.description, remaining)
                schedMessage = schedMessage .. " " .. cs.description
                luup.variable_set(SCHEDULESID, "LastStart", lastStart, cs.udn)
                luup.variable_set(SCHEDULESID, "RunEnds", runEnds, cs.udn)
                luup.variable_set(SCHEDULESID, "Duration", durMinutes, cs.udn)
                luup.variable_set(SCHEDULESID, "Remaining", remaining, cs.udn)
                luup.variable_set(SCHEDULESID, "Watering", 1, cs.udn)
                luup.variable_set(DEVICESID, "LastSchedule", cs.udn, cd.udn)
                luup.variable_set(DEVICESID, "LastScheduleName", schedule.type .. " " .. cs.description, cd.udn)
                setMessage(formatMinutes(remaining), SCHEDULESID, cs.id, 20)
            else
                D("doSchedCheck() schedule %1 not a child--manual schedule?", schedule.scheduleId)
                luup.variable_set(DEVICESID, "LastSchedule", "", cd.udn)
                luup.variable_set(DEVICESID, "LastScheduleName", schedule.type, cd.udn)
            end
            setMessage(schedMessage, DEVICESID, cd.udn, 20)

            -- Reset stats for (all) zones
            local zones = findChildrenByType( parentDevice, ZONETYPE )
            for _,cz in pairs(zones) do
                local zoneDev = luup.variable_get(DEVICESID, "ParentDevice", cz.udn)
                if zoneDev == cd.udn then
                    if cz.id == schedule.zoneId then
                        -- This is the running zone
                        lastStart = math.floor( schedule.zoneStartDate / 1000 )
                        durMinutes = math.ceil( schedule.zoneDuration / 60 )
                        runEnds = lastStart + schedule.zoneDuration
                        remaining = math.ceil( (runEnds - os.time()) / 60 )
                        if remaining < 1 then remaining = 1 end
                        D("doSchedCheck() setting zone info for %1 (zone %2) remaining %3", schedule.zoneId, schedule.zoneNumber, remaining)
                        luup.variable_set(ZONESID, "LastStart", lastStart, cz.udn)
                        luup.variable_set(ZONESID, "RunEnds", runEnds, cz.udn)
                        luup.variable_set(ZONESID, "Duration", durMinutes, cz.udn)
                        luup.variable_set(ZONESID, "Remaining", remaining, cz.udn)
                        luup.variable_set(ZONESID, "Watering", 1, cz.udn)
                        if cs ~= nil then
                            luup.variable_set(ZONESID, "LastSchedule", cs.udn, cz.udn)
                            luup.variable_set(ZONESID, "LastScheduleName", schedule.type .. " " .. cs.description, cz.udn)
                        else
                            luup.variable_set(ZONESID, "LastSchedule", "", cz.udn)
                            luup.variable_set(ZONESID, "LastScheduleName", schedule.type, cz.udn)
                        end
                        setMessage(formatMinutes(remaining), ZONESID, cz.id, 20)
                    else
                        luup.variable_set(ZONESID, "Remaining", 0, cz.udn)
                        luup.variable_set(ZONESID, "Watering", 0, cz.udn)
                    end
                end
            end
        elseif watering ~= 0 then
            -- No running schedule now (was running previously)
            D("doSchedCheck() schedule ended")
            luup.variable_set(DEVICESID, "Remaining", 0, cd.udn)
            luup.variable_set(DEVICESID, "Watering", 0, cd.udn)
            local children = findChildrenByType( parentDevice, ZONETYPE )
            -- Mark zones idle
            for _,cz in pairs(children) do
                -- If zone belongs to this device...
                local zoneDev = luup.variable_get(DEVICESID, "ParentDevice", cz.udn) -- N.B. device SID here
                if zoneDev == cd.udn then
                    D("doSchedCheck() setting idle zone info for %1 (%2)", cz.description, cz.id)
                    luup.variable_set(ZONESID, "Remaining", 0, cz.udn)
                    luup.variable_set(ZONESID, "Watering", 0, cz.udn)
                end
            end
            -- Do same for schedules
            children = findChildrenByType( parentDevice, SCHEDULETYPE )
            for _,cz in pairs(children) do
                -- If zone belongs to this device...
                local schedDev = luup.variable_get(DEVICESID, "ParentDevice", cz.udn) -- N.B. device SID here
                if schedDev == cd.udn then
                    D("doSchedCheck() setting idle schedule info for %1 (%2)", cz.description, cz.id)
                    luup.variable_set(SCHEDULESID, "Remaining", 0, cz.udn)
                    luup.variable_set(SCHEDULESID, "Watering", 0, cz.udn)
                end
            end
        else
            D("doSchedCheck() idle")
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

local function doDeviceUpdate( data, parentDevice )
    D("doDeviceUpdate(data,%1)", parentDevice)
    local lastUpdate = os.time()

    showServiceStatus("Online (updating)", parentDevice)

    -- Save the service/person UID
    D("doDeviceUpdate(): person %1 (%2) user %3", data.fullName, data.email, data.username)
    luup.variable_set(SYSSID, "Fullname", data.fullName, parentDevice)
    luup.variable_set(SYSSID, "Email", data.email, parentDevice)
    luup.variable_set(SYSSID, "Username", data.username, parentDevice)

    -- Loop over devices
    for _,v in pairs(data.devices) do
        if v.status == nil or v.status:lower() ~= "online" then
            setMessage("*" .. tostring(v.status), DEVICESID, v.id, 99)
        elseif v.on == 0 then
            setMessage("Disabled", DEVICESID, v.id, 10)
        elseif v.paused ~= 0 then
            setMessage("Paused", DEVICESID, v.id, 10)
        else
            setMessage("Enabled", DEVICESID, v.id, 0) -- default message
        end

        -- Find this device
        local cd = findChildByUID( parentDevice, v.id )
        if cd ~= nil then
            luup.variable_set(SYSSID, "ParentService", parentDevice, cd.udn) -- yes, SYSSID, really.
            luup.variable_set(SYSSID, "RachioID", v.id, cd.udn)

            luup.variable_set(DEVICESID, "Status", v.status, cd.udn)
            luup.variable_set(DEVICESID, "On", v.on, cd.udn)
            luup.variable_set(DEVICESID, "Model", v.model, cd.udn)
            luup.variable_set(DEVICESID, "Serial", v.serialNumber, cd.udn)
            luup.variable_set(DEVICESID, "Paused", v.paused, cd.udn)

            local rainEnd = luup.variable_get(DEVICESID, "RainDelayTime", cd.udn)
            if v.rainDelayStartDate then
                D("doDeviceUpdate() rain delay start %1 end %2", v.rainDelayStartDate, v.rainDelayExpirationDate)
                local rainStart = math.floor(v.rainDelayStartDate / 1000)
                rainEnd = math.floor(v.rainDelayExpirationDate / 1000)
                if rainStart <= os.time() and rainEnd > os.time() then
                    setMessage("Rain delay to " .. os.date("%c", rainEnd), DEVICESID, v.id, 0)
                    rainEnd = math.ceil((rainEnd - rainStart) / 60)
                else
                    rainEnd = 0
                end
                luup.variable_set(DEVICESID, "RainDelayTime", rainEnd, cd.udn) -- save as minutes remaining
                luup.variable_set(DEVICESID, "RainDelay", 1, cd.udn) -- save as minutes remaining
            elseif rainEnd ~= 0 then
                luup.variable_set(DEVICESID, "RainDelayTime", 0, cd.udn)
                luup.variable_set(DEVICESID, "RainDelay", 0, cd.udn)
            end

            -- Now go through device's zones, setting data
            local hide = getVarNumeric(SYSSID, "HideZones", 0, parentDevice)
            local hideDisabled = getVarNumeric(SYSSID, "HideDisabledZones", 0, parentDevice)
            for _,z in pairs(v.zones) do
                local cz = findChildByUID( parentDevice, z.id )
                if cz ~= nil then
                    local localHide = hide
                    if hideDisabled ~=0 and z.enabled == 0 then localHide = 1 end
                    setMessage(choose(z.enabled, "Disabled", "Enabled"), ZONESID, z.id, 0) -- default message for zone
                    luup.variable_set(ZONESID, "Enabled", z.enabled, cz.udn)
                    luup.variable_set(ZONESID, "Number", z.zoneNumber, cz.udn)
                    luup.variable_set(ZONESID, "Name", z.name, cz.udn)
                    luup.variable_set(DEVICESID, "ParentDevice", cd.udn, cz.udn) -- yes, DEVICESID, really
                    luup.variable_set(SYSSID, "ParentService", parentDevice, cz.udn) -- yes, SYSSID, really
                    luup.variable_set(SYSSID, "RachioID", z.id, cz.udn) -- yes. ...
                    luup.attr_set("invisible", tostring(localHide), cz.udn)
                else
                    -- Zone not found. Rachio's config may have changed behind our back.
                    -- Don't reset the device automatically, though, because user may
                    -- scenes and Lua that could be broken by the renumbering.
                    L("doDeviceUpdate() child for zone %1 not found--skipping", z.id)
                end
            end

            -- And over schedules...
            hide = getVarNumeric(SYSSID, "HideSchedules", 0, parentDevice)
            hideDisabled = getVarNumeric(SYSSID, "HideDisabledSchedules", 0, parentDevice)
            for _,z in pairs( arraymerge(v.scheduleRules, v.flexScheduleRules) ) do
                if v.on == 0 or v.paused ~= 0 then
                    -- Iro is off, so we there won't be automatic watering.
                    setMessage("Suspended", SCHEDULESID, z.id, 0)
                else
                    setMessage(choose(z.enabled, "Disabled", "Enabled"), SCHEDULESID, z.id, 0)
                end

                -- Find this device
                local cs = findChildByUID( parentDevice, z.id )
                if cs ~= nil then
                    local zn = {}
                    for _,l in pairs(z.zones) do
                        table.insert(zn, l.zoneNumber .. "=" .. (l.duration or ""))
                    end
                    local localHide = hide
                    if hideDisabled ~= 0 and z.enabled == 0 then localHide = 1 end
                    luup.variable_set(SCHEDULESID, "Zones", table.concat(zn, ","), cs.udn)
                    luup.variable_set(SCHEDULESID, "Enabled", z.enabled, cs.udn)
                    luup.variable_set(SCHEDULESID, "Name", z.name, cs.udn)
                    luup.variable_set(SCHEDULESID, "Summary", z.summary, cs.udn)
                    luup.variable_set(SCHEDULESID, "RainDelay", z.rainDelay or "0", cs.udn)
                    luup.variable_set(SCHEDULESID, "Type", z.type or "FIXED", cs.udn)
                    luup.variable_set(DEVICESID, "ParentDevice", cd.udn, cs.udn) -- yes, DEVICESID, really
                    luup.variable_set(SYSSID, "ParentService", parentDevice, cs.udn) -- yes, SYSSID, really.
                    luup.variable_set(SYSSID, "RachioID", z.id, cs.udn) -- yes
                    luup.attr_set("invisible", tostring(localHide), cs.udn)
                else
                    -- Rachio data pointed us to a device we can't find. Forcing a reset
                    -- of the child devices might be unfriendly, as it renumbers (and
                    -- possibly renames) the children, which could break scenes and Lua
                    -- the user has configured. So log, but do nothing.
                    L("doDeviceUpdate() child for schedule %1 not found--skipping", z.id)
                end
            end

            -- Do a schedule check on this device ??? Now done separately
            -- doSchedCheck( cd, parentDevice )
        else
            -- Rachio data pointed us to a device we can't find. Forcing a reset
            -- of the child devices might be unfriendly, as it renumbers (and
            -- possibly renames) the children, which could break scenes and Lua
            -- the user has configured. So log, but do nothing.
            L("doDeviceUpdate() child for device %1 not found--skipping", v.id)
        end
    end

    -- Successful update.
    luup.variable_set(SYSSID, "ServiceCheck", 0, parentDevice)
    luup.variable_set(SYSSID, "LastUpdate", lastUpdate, parentDevice)

    return true
end

local function setUpDevices(data, parentDevice)
    D("setUpDevices(data,%1)", parentDevice)
    if parentDevice == nil then parentDevice = luup.device end

    showServiceStatus("Online (configuring)", parentDevice)

    -- Save the service/person UID
    -- D("setUpDevices(): person %1 (%2) user %3", data.fullName, data.email, data.username)
    L("Taking inventory")
    luup.variable_set(SYSSID, "RachioID", data.id, parentDevice)
    luup.variable_set(SYSSID, "Username", data.username, parentDevice)
    luup.variable_set(SYSSID, "Fullname", data.fullName, parentDevice)
    luup.variable_set(SYSSID, "Email", data.email, parentDevice)

    -- Sync our child devices with Rachio's devices and zones.
    local changes = 0
    local ptr = luup.chdev.start(parentDevice)

    -- Now pass through the devices again and enumerate all the zones for each.
    local knownDevices = findChildrenByType( parentDevice, DEVICETYPE )
    for _,v in pairs(data.devices) do
        D("setUpDevices():     device " .. tostring(v.id) .. " model " .. tostring(v.model))
        local cd = findChildByUID( parentDevice, v.id )
        if cd == nil then
            -- New device
            changes = changes + 1
            D("setUpDevices() adding child for device " .. tostring(v.id))
        end

        -- Always append child (embedded) device. Pass UID as id (string 3), and also initialize UID service variable.
        luup.chdev.append( parentDevice, ptr, v.id, v.name, "", "D_RachioDevice1.xml", "", SYSSID .. ",RachioID=" .. v.id, true )

        -- Child exists or was created, remove from known list
        knownDevices[v.id] = nil

        -- Now go through zones for this device...
        local knownZones = findChildrenByType( parentDevice, ZONETYPE )
        for _,z in pairs(v.zones) do
            D("setUpDevices():         zone " .. tostring(z.zoneNumber) .. " " .. tostring(z.name))
            local cz = findChildByUID( parentDevice, z.id )
            if cz == nil then
                -- New zone
                changes = changes + 1
                D("setUpDevices() adding child device for zone " .. z.id .. " number " .. z.zoneNumber .. " " .. z.name)
            end

            -- Always append child device. Pass UID as id (string 3), and also initialize UID service variable.
            luup.chdev.append( parentDevice, ptr, z.id, z.name, "", "D_RachioZone1.xml", "", SYSSID..",RachioID=" .. z.id, true )

            -- Remove from known list
            knownZones[z.id] = nil
        end
        for _ in pairs(knownZones) do changes = changes + 1 break end

        -- And schedules
        local knownSchedules = findChildrenByType( parentDevice, SCHEDULETYPE )
        for _,z in pairs( arraymerge(v.scheduleRules, v.flexScheduleRules) ) do
            D("setUpDevices():         schedule %1 name %2", z.id, z.name)
            local cs = findChildByUID( parentDevice, z.id )
            if cs == nil then
                -- New schedule
                changes = changes + 1
                D("setUpDevices() adding child for schedule %1", z.id)
            end

            luup.chdev.append( parentDevice, ptr, z.id, z.name, "", "D_RachioSchedule1.xml", "", SYSSID .. ",RachioID=" .. z.id, true )

            knownSchedules[z.id] = nil
        end
        for _ in pairs(knownSchedules) do changes = changes + 1 break end
    end
    for _ in pairs(knownDevices) do changes = changes + 1 break end

    -- Finished enumerating zones for this device. If we changed any, sync() will reload Luup now.
    L("Inventory completed, %1 changes to configuration.", changes)
    luup.chdev.sync( parentDevice, ptr )
    return changes == 0
end

local function forceUpdate( devnum )
    -- local service = findServicePlugin(devnum) -- ??? are we supposed to be using this below, what happened here?
    if luup.devices[devnum].device_type == DEVICETYPE then
        luup.variable_set(DEVICESID, "Message", "---", devnum) -- direct
    end
    if not updatePending then
        updatePending = true
        luup.call_delay("rachio_plugin_tick", 2, "-1") -- "-1" stamp is special signal, see tick()
    else
        D("forceUpdate() an update is already pending")
    end
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
    local ch = findChildrenByType( devnum, ZONETYPE )
    for _,x in pairs(ch) do
        local hideThis = hideAll
        if hideDisabled ~= 0 then
            local enabled = getVarNumeric(ZONESID, "Enabled", 1, x.udn)
            if enabled == 0 then hideThis = 1 end
        end
        luup.attr_set('invisible', tostring(hideThis), x.udn)
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
    local ch = findChildrenByType( devnum, SCHEDULETYPE )
    for _,x in pairs(ch) do
        local hideThis = hideAll
        if hideDisabled ~= 0 then
            local enabled = getVarNumeric(SCHEDULESID, "Enabled", 1, x.udn)
            if enabled == 0 then hideThis = 1 end
        end
        luup.attr_set('invisible', tostring(hideThis), x.udn)
    end
end

function rachioServiceReset( devnum )
    D("rachioServiceReset(%1)", devnum)

    showServiceStatus("Resetting...", devnum)
    luup.variable_set( SYSSID, "PID", "", devnum )
    local ptr = luup.chdev.start( devnum )
    luup.chdev.sync( devnum, ptr )
    -- luup restart will happen, should take care of the rest
end

-- Tell Rachio to stop all watering on device
function rachioDeviceStop( devnum )
    D("rachioDeviceStop(%1)", devnum)

    local d = luup.devices[ devnum ]
    local status,resp = getJSON("/public/device/stop_water", "PUT", { id=d.id })
    D("rachioDeviceStop() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        forceUpdate(devnum)
        return true
    end
    return false
end

-- Tell Rachio to turn device features off
function rachioDeviceOff( devnum )
    D("rachioDeviceOff(%1)", devnum)

    -- Call API to turn off controller
    local d = luup.devices[ devnum ]
    local status,resp = getJSON("/public/device/off", "PUT", { id=d.id })
    D("rachioDeviceOff() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        forceUpdate(devnum)
        return true
    end
    return false
end

-- Tell Rachio to turn device features on
function rachioDeviceOn( devnum )
    D("rachioDeviceOn(%1)", devnum)

    -- Call API to turn on controller
    local d = luup.devices[ devnum ]
    local status,resp = getJSON("/public/device/on", "PUT", { id=d.id })
    D("rachioDeviceOn() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        forceUpdate(devnum)
        return true
    end
    return false
end

function rachioStartMultiZone( devnum, zoneData )
    D("rachioStartMultiZone(%1,%2)", devnum, zoneData)

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
            forceUpdate(devnum)
            return true
        end
    end
    return false
end

-- Tell Rachio to start watering a zone
function rachioStartZone( devnum, durMinutes )
    D("rachioStartZone(%1,%2)", devnum, durMinutes)

    if durMinutes == nil then durMinutes = 0 end
    durMinutes = tonumber(durMinutes,10)
    if durMinutes < 0 then durMinutes = 0 elseif durMinutes > 180 then durMinutes = 180 end

    local d = luup.devices[ devnum ]
    local status,resp = getJSON("/public/zone/start", "PUT", { id=d.id, duration=durMinutes*60 })
    D("rachioStartZone() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        forceUpdate(devnum)
        return true
    end
    return false
end

-- Tell Rachio to start a schedule
function rachioRunSchedule( devnum )
    D("rachioRunSchedule(%1)", devnum)

    local d = luup.devices[ devnum ]
    local status,resp = getJSON("/public/schedulerule/start", "PUT", { id=d.id })
    D("rachioRunSchedule() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        forceUpdate(devnum)
        return true
    end
    return false
end

-- Tell Rachio to skip a schedule
function rachioSkipSchedule( devnum )
    D("rachioSkipSchedule(%1)", devnum)

    local d = luup.devices[ devnum ]
    local status,resp = getJSON("/public/schedulerule/skip", "PUT", { id=d.id })
    D("rachioSkipSchedule() getJSON returned %1,%2", status,resp)
    if status == HTTPREQ_OK then
        forceUpdate(devnum)
        return true
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

-- -----------------------------------------------------------------------------
--
-- G E N E R I C   P L U G I N   F U N C T I O N S
--
-- -----------------------------------------------------------------------------

local function checkFirmware(dev)
    if dev == nil then dev = luup.device end
    D("checkFirmware(%1) version=%1, in parts %2.%3.%4", luup.version,
        luup.version_branch, luup.version_major, luup.version_minor)

    -- Look for UI7 or better. We don't support openLuup at the moment because it does
    -- not support UDNs.
    if isOpenLuup or luup.version_branch ~= 1 or luup.version_major < 7 then
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
    firstRun = true
    messages = {}

    -- Clear cycleMult
    luup.variable_set(SYSSID, "CycleMult", "1", pdev)

    return true
end

-- Get things moving...
local function run(pdev)
    D("run(%1)", pdev)

    -- Immediately set a new timestamp
    runStamp = os.time()

    luup.call_delay("rachio_plugin_tick", 5, runStamp)
    D("run(): scheduled first step, done")

    luup.set_failure(0, pdev)

    return true, true -- signal success and separate thread running
end

-- Initialize.
function start(pdev)
    L("starting plugin version %2 device %1", pdev, _PLUGIN_VERSION)
    if pdev == nil then pdev = luup.device end
    pdev = tonumber(pdev,10)

    -- Check for ALTUI and OpenLuup
    for k,v in pairs(luup.devices) do
        if v.device_type == "urn:schemas-upnp-org:device:altui:1" then
            D("start() detected ALTUI at %1", k)
            isALTUI = true
            local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
                { newDeviceType=SYSTYPE, newScriptFile="J_Rachio1_ALTUI.js", newDeviceDrawFunc="Rachio_ALTUI.DeviceDraw" },
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
    local iv = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, pdev)
    if iv < DEFAULT_INTERVAL then
        L({level=2,msg="Warning: Interval is %1; values < %2 are likely to exceed Rachio's daily API request quota."}, iv, DEFAULT_INTERVAL)
    end
    if init(pdev) then
        -- Start
        run(pdev)
        return true, "OK", _PLUGIN_NAME
    else
        hardFail(HTTPREQ_GENERICERROR, "Offline (failed init)");
        return false, "Initialization failed", _PLUGIN_NAME
    end
end

function stop(pdev)
    D("stop(%1)", pdev)
    if pdev == nil then pdev = luup.device end
    pdev = tonumber(pdev,10)

    -- Setting runStamp to 0 effectively kills the child tick process on the
    -- next cycle
    runStamp = 0
    showServiceStatus("Offline (stopped)", pdev)
end

-- Do interval-based stuff. This is called using pcall(), so any error thrown
-- will result in a stop of the active scheduling process.
local function ptick(p)
    D("ptick(%1)", p)

    local pdev = tonumber(p["pdev"],10)
    assert(pdev ~= nil and pdev > 0, "Invalid pdev");

    local cycleMult = getVarNumeric(SYSSID, "CycleMult", 1, pdev)
    
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
        if firstRun or ( os.time() >= ( lastUpdate + getVarNumeric( SYSSID, "DeviceInterval", 3600, pdev ) ) ) then
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
                    L("Full query, invalid API response: %1", data)
                    if (cycleMult < MAX_CYCLEMULT) then cycleMult = cycleMult * 2 end
                    showServiceStatus("Offline (error--delaying)", pdev)
                end
            else
                -- Good response. Do our device update.
                if firstRun then
                    L("First run, set up devices")
                    setUpDevices( data, pdev )
                    firstRun = false -- don't do this again
                    luup.variable_set( SYSSID, "LastUpdate", 0, pdev )
                end

                -- Do device update (same data as set up if it was done)
                doDeviceUpdate( data, pdev )
            end
        end

        -- Each interval, we do a schedule check on each controller.
        -- N.B. Schedule check for each devices is one query per...
        if not problem then
            local devices = findChildrenByType( pdev, DEVICETYPE )
            for d,v in pairs(devices) do 
                if not doSchedCheck( v, pdev ) then 
                    problem = true
                    break 
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
    D("tick(%1) luup.device=%2", stepStampCheck, luup.device)

    -- See if stamps match. If not, runStamp has changed and another thread is running, so quit.
    -- "Craftiness" here. If stamp is -1, we're being run by another thread explicitly.
    local stepStamp = tonumber(stepStampCheck,10)
    if (stepStamp ~= -1 and stepStamp ~= runStamp) then
        D("tick() stamp mismatch, expecting %1 got %2. Another thread running, bye!", runStamp, stepStampCheck)
        return
    end

    -- Make sure we're working with our parent (plugin) device
    local pdev = findServicePlugin(luup.device)
    tickCount = tickCount + 1
    D("tick() running pdev=%2, tickCount=%1", tickCount, pdev)

    -- Check last tick time. If too soon, skip this
    local tooSoon = stepStamp ~= -1 and (lastTick + 30) > os.time()
    lastTick = os.time()

    -- Use pcall() to run the plugin's stuff. If it fails, we stay in control.
    local success, err
    if tooSoon then
        D("tick() too soon, skipping ptick")
        success = true -- fake it
    elseif stepStamp ~= -1 and updatePending then
        D("tick() update pending, skipping ptick")
        success = true -- fake it
    else
        updatePending = true -- don't allow other updates while we're working
        success,err = pcall( ptick, { pdev=pdev } )
        updatePending = false
        D("tick() ptick returned %1,%2", success, err);
    end
    if success then
        -- No errors, schedule next event (unless stepStamp == -1, then it's a direct/special call)
        if stepStamp ~= -1 then
            local cycleMult = getVarNumeric(SYSSID, "CycleMult", 1, pdev)
            local nextCycleDelay = getVarNumeric(SYSSID, "Interval", DEFAULT_INTERVAL, pdev) * cycleMult
            if nextCycleDelay < 1 then nextCycleDelay = 60 
            elseif nextCycleDelay > MAX_INTERVAL then nextCycleDelay = MAX_INTERVAL end
            D("tick() cycle finished, next in " .. nextCycleDelay .. " seconds, cycleMult is " .. tostring(cycleMult))
            luup.call_delay("rachio_plugin_tick", nextCycleDelay, stepStamp)
        end
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

function setTraceMode( devnum, newState )
    -- Sets debug only; no trace in production/released code.
    debugMode = (type(newState)=="number" and newState ~= 0) or newState == "1" or tostring(newState) == "true"
    D("setTraceMode() debug mode for %2 is now %1", debugMode, devnum)
end

local function issKeyVal( k, v, s )
    if s == nil then s = {} end
    s["key"] = tostring(k)
    s["value"] = tostring(v)
    return s
end

local function map( m, v, d )
    if m[v] == nil then return d end
    return m[v]
end

local function getDevice( dev, pdev, v )
    local dkjson = require("dkjson")
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
    D("requestHandler(%1,%2,%3) luup.device=%4", lul_request, lul_parameters, lul_outputformat, luup.device)
    local action = lul_parameters['action'] or lul_parameters['command'] or ""
    local deviceNum = tonumber( lul_parameters['device'], 10 ) or luup.device
    if action == "debug" then
        local err,msg,job,args = luup.call_action( SYSSID, "SetDebug", { debug=1 }, deviceNum )
        return string.format("Device #%s result: %s, %s, %s, %s", tostring(deviceNum), tostring(err), tostring(msg), tostring(job), dump(args))
    end

    if action:sub( 1, 3 ) == "ISS" then
        -- ImperiHome ISS Standard System API, see http://dev.evertygo.com/api/iss#types
        local dkjson = require('dkjson')
        local path = lul_parameters['path'] or action:sub( 4 ) -- Work even if I'home user forgets &path=
        if path == "/system" then
            return dkjson.encode( { id="AutoVirtualThermostat-" .. luup.pk_accesspoint, apiversion=1 } ), "application/json"
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
                    local z = luup.variable_get( ZONESID, "Watering", lnum ) or "0"
                    local icon = "ok"
                    if z == "1" then icon = "watering" end
                    table.insert( issinfo, issKeyVal("Status", z) )
                    table.insert( issinfo, issKeyVal("pulseable", "0") )
                    table.insert( issinfo, issKeyVal("defaultIcon", "https://www.toggledbits.com/rachio/assets/rachio-zone-" .. icon .. "-60x60.png" ) )
                    local dev = { id=tostring(lnum), 
                        name=ldev.description or ("#" .. lnum), 
                        ["type"]="DevSwitch", 
                        params=issinfo }
                    if ldev.room_num ~= nil and ldev.room_num ~= 0 then dev.room = tostring(ldev.room_num) end
                    table.insert( devices, dev )
                elseif ldev.device_type == SCHEDULETYPE then
                    local issinfo = {}
                    local z = luup.variable_get( SCHEDULESID, "Watering", lnum ) or "0"
                    local icon = "ok"
                    if z == "1" then icon = "running" end
                    table.insert( issinfo, issKeyVal("Status", z) )
                    table.insert( issinfo, issKeyVal("pulseable", "0") )
                    table.insert( issinfo, issKeyVal("defaultIcon", "https://www.toggledbits.com/rachio/assets/rachio-schedule-" .. icon .. "-60x60.png" ) )
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
                            local parent = luup.variable_get(DEVICESID, "ParentDevice", dev)
                            if parent ~= nil then
                                -- No need to resolve; we can pass parent directly.
                                luup.call_action( DEVICESID, "DeviceStop", {}, parent )
                            else
                                L("ISS schedule stop could not be handled, parent device udn=%1 for schedule %2 (%3) could not be located", parent, dev, luup.devices[dev].description)
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
        local dkjson = require("dkjson")
        if dkjson == nil then return "Missing dkjson library", "text/plain" end
        local st = {
            name=_PLUGIN_NAME,
            version=_PLUGIN_VERSION,
            configversion=_CONFIGVERSION,
            author="Patrick H. Rigney (rigpapa)",
            url=_PLUGIN_URL,
            ['type']=SYSTYPE,
            responder=luup.device,
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
                local devinfo = getDevice( k, luup.device, v ) or {}
                table.insert( st.devices, devinfo )
            end
        end
        return dkjson.encode( st ), "application/json"
    end
    
    return "<html><head><title>" .. _PLUGIN_NAME .. " Request Handler"
        .. "</title></head><body bgcolor='white'>Request format: <tt>http://" .. (luup.attr_get( "ip", 0 ) or "...")
        .. "/port_3480/data_request?id=lr_" .. lul_request 
        .. "&action=...</tt><p>Actions: status<br>debug&device=<i>devicenumber</i><br>ISS"
        .. "<p>Imperihome ISS URL: <tt>...&action=ISS&path=</tt><p>Documentation: <a href='"
        .. _PLUGIN_URL .. "' target='_blank'>" .. _PLUGIN_URL .. "</a></body></html>"
        , "text/html"
end
