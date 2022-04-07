function widget:GetInfo()
   return {
      name = "Prometheus metrics exporter",
      desc = "Exports prometheus metrics on port 9123",
      author = "ecraven",
      date = "2022-03-30",
      license = "GNU GPL, v2 or later",
      layer = 0,
      enabled = true
   }
end

local gameID = nil

-- Prometheus interface
local metrics = {}

local function makeGauge(name, help)
   if not name then
      error('Please specify name for gauge')
   end
   if not help then
      error('Please specify help for gauge ' .. name)
   end
   if metrics[name] then
      error("metric with name already exists " .. name)
   end
   local metric = {
      ['name'] = name,
      ['help'] = help,
      ['type'] = 'gauge',
      ['values'] = {},
      ['inc'] = inc,
      ['set'] = set,
   }
   metrics[name] = metric
   return metric
end

local function makeCounter(name, help)
   if not name then
      error('Please specify name for counter')
   end
   if not help then
      error('Please specify help for counter ' .. name)
   end
   if metrics[name] then
      error("metric with name already exists " .. name)
   end
   local metric = {
      ['name'] = name,
      ['help'] = help,
      ['type'] = 'counter',
      ['values'] = {},
      ['inc'] = inc,
   }
   metrics[name] = metric
   return metric
end


local function is_labels(labels) -- check that labels is a table with string keys and string/number values
   if type(labels) ~= 'table' then
      return false
   else
      for k,v in pairs(labels) do
         if type(k) ~= 'string' then
            return false
         end
         if type(v) ~= 'string' and not type(v) == 'number' then
            return false
         end
      end
   end
   return true
end

local function calcLabels(labels)
   local labs = ''
   if labels == {} then
      return labs
   end
   local ls = {}
   for k,v in pairs(labels) do
      table.insert(ls, k)
   end
   table.sort(ls)
   for _,k in ipairs(ls) do
      if labs ~= '' then
         labs = labs .. ','
      end
      local v = labels[k]
      if type(v) == 'boolean' then
         v = v and "true" or "false"
      end
      labs = labs .. k .. '="' .. v .. '"'
   end
   labs = '{' .. labs .. '}'
   return labs
end

local function inc(metric, labels, amount)
   if not is_labels(labels) then
      error('invalid labels for metric ' .. metric)
   end
   if not metric.type == 'gauge' and not metric.type == 'counter' then
      error('unsupported operation inc for type ' .. metric.type)
   end
   if not amount then
      amount = 1
   end
   if metric.type == 'counter' and amount < 0 then
      error('negative inc amount for counter ' .. amount)
   end
   metric.values[calcLabels(labels)] = amount
   return metric
end

local function set(metric, labels, value)
   if not value then
      -- is this a good idea, just to ignore nil values??
      return
   end
   if not is_labels(labels) then
      error('invalid labels for metric ' .. metric.name)
   end
   if not metric.type == 'gauge' and not metric.type == 'counter' then
      error('unsupported operation inc for type ' .. metric.type)
   end
   if not value then
      error('cannot set nil value ' .. metric.name)
   end
   local ls = calcLabels(labels)
   --   Spring.Echo("Setting metric " .. metric.name .. ls .. " to value " .. value)
   metric.values[ls] = value
   return metric
end

local m_resource = makeGauge('resource', "Stats for resource (energy or metal) current, storage, pull, income, ...")
local m_player_info = makeGauge('player_info', "Information about players")
local m_game_info = makeGauge('game_info', 'Information about the game')
local m_unit_stats = makeCounter('unit_stats', 'Counter for unit state, killed, died, captured, ...')
local m_resource_stats = makeCounter('resource_stats', 'used, produced, excessed, ..')
local m_wind_strength = makeGauge('wind_strength', 'Wind speed')
local m_tidal_strength = makeGauge('tidal_strength', 'Tidal strength')
local m_resource_total = makeCounter('resource_total', 'Counter for total resources')
local m_units = makeGauge('units', 'Stats for units')
local teamNames = {}
local teamColors = {}
local allyTeamColors = {}
local allyTeamNames = {}

local function resetMetrics()
   for k,v in pairs(metrics) do
      v.values = {}
   end
end
local sGetWind = Spring.GetWind
local windMin = Game.windMin
local windMax = Game.windMax
local sGetGaiaTeamID = Spring.GetGaiaTeamID
local sGetPlayerList = Spring.GetPlayerList
local sGetPlayerInfo = Spring.GetPlayerInfo
local sGetTeamStatsHistory = Spring.GetTeamStatsHistory
local sGetTeamUnitStats = Spring.GetTeamUnitStats
local sGetTeamResources = Spring.GetTeamResources
local sGetTeamUnitStats = Spring.GetTeamUnitStats
local sGetTeamInfo = Spring.GetTeamInfo
local sGetTeamList = Spring.GetTeamList
local sGetTeamUnitsCounts = Spring.GetTeamUnitsCounts
local sGetAIInfo = Spring.GetAIInfo
local sGetTeamColor = Spring.GetTeamColor

-- taken from grid_menu
local BUILDCAT_ECONOMY = "Economy"
local BUILDCAT_COMBAT = "Combat"
local BUILDCAT_UTILITY = "Utility"
local BUILDCAT_PRODUCTION = "Production"
local categoryGroupMapping = {
	energy = BUILDCAT_ECONOMY,
	metal = BUILDCAT_ECONOMY,
	builder = BUILDCAT_PRODUCTION,
	buildert2 = BUILDCAT_PRODUCTION,
	buildert3 = BUILDCAT_PRODUCTION,
	buildert4 = BUILDCAT_PRODUCTION,
	util = BUILDCAT_UTILITY,
	weapon = BUILDCAT_COMBAT,
	explo = BUILDCAT_COMBAT,
	weaponaa = BUILDCAT_COMBAT,
	aa = BUILDCAT_COMBAT,
	emp = BUILDCAT_COMBAT,
	sub = BUILDCAT_COMBAT,
	nuke = BUILDCAT_COMBAT,
	antinuke = BUILDCAT_COMBAT,
}

local function unitStats(teamID, teamName, allyTeam)
   local metal = 0
   local energy = 0
   local buildspeed = 0
   local buildings_factory = 0
   local builders = 0
   local econv_energy = 0
   local buildcats = {
      [BUILDCAT_ECONOMY]={mobile={}, static={}},
      [BUILDCAT_COMBAT]={mobile={}, static={}},
      [BUILDCAT_PRODUCTION]={mobile={}, static={}},
      [BUILDCAT_UTILITY]={mobile={}, static={}}
   }
   local common = {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName}
   local consturrets = 0
   for udid,count in pairs(sGetTeamUnitsCounts(teamID)) do
      if type(udid) == 'number' then
         local ud = UnitDefs[udid]
         local cat = categoryGroupMapping[ud.customParams.unitgroup] or BUILDCAT_UTILITY
         local t = ud.isBuilding and 'static' or 'mobile'
         buildcats[cat][t]['count'] = (buildcats[cat][t]['count'] or 0) + count
         buildcats[cat][t]['metal'] = (buildcats[cat][t]['metal'] or 0) + count * ud.metalCost
         buildcats[cat][t]['energy'] = (buildcats[cat][t]['energy'] or 0) + count * ud.energyCost
         buildspeed = buildspeed + count * ud.buildSpeed
         if ud.isBuilding and #ud.buildOptions > 0 then
            buildings_factory = buildings_factory + count
         end
         if ud.customParams.energyconv_capacity then
            econv_energy = econv_energy + count * ud.customParams.energyconv_capacity
         end
         if ud.buildSpeed > 0 and ud.buildOptions[1] and not ud.isFactory then
            builders = builders + count
         end
         if ud.name == 'armnanotc' or ud.name == 'cornanotc' then
            consturrets = consturrets + count
         end
      end
   end
   for _,c in pairs({BUILDCAT_ECONOMY, BUILDCAT_UTILITY, BUILDCAT_COMBAT, BUILDCAT_PRODUCTION}) do
      for _,t in pairs({'mobile','static'}) do
         if buildcats[c][t]['count'] then
            set(m_units, table.merge(common, {category=c,stat='count', mobility=t}), buildcats[c][t]['count'])
            set(m_units, table.merge(common, {category=c,stat='metal', mobility=t}), buildcats[c][t]['metal'])
            set(m_units, table.merge(common, {category=c,stat='energy', mobility=t}), buildcats[c][t]['energy'])
         end
      end
   end
   set(m_units, table.merge(common, {name='constructionturret'}), consturrets)
   set(m_units, table.merge(common, {resource='buildspeed'}), buildspeed)
   set(m_units, table.merge(common, {name='econvs',stat='energy'}), econv_energy)
   set(m_units, table.merge(common, {resource='building',['type']='factory'}), buildings_factory)
end

function GetAIName(teamID)
   local _, _, _, name, _, options = sGetAIInfo(teamID)
   local niceName = Spring.GetGameRulesParam('ainame_' .. teamID)
   if niceName then
      name = niceName
   end
   return name
end

local function updateMetrics()
   local _, _, _, wind_strength, _, _, _ = sGetWind()
   set(m_wind_strength, {['gameID'] = gameID, min=windMin, max=windMax}, wind_strength)
   set(m_tidal_strength, {['gameID'] = gameID}, Game.tidal or 0)
   local gaiaTeamID = sGetGaiaTeamID()
   set(m_game_info, {['gameID'] = gameID, ['version'] = Game.version, ['mapname'] = Game.mapName, ['mapX'] = Game.mapX, ['mapY'] = Game.mapY}, 1)
   --   Spring.Echo("gaia team id: " .. gaiaTeamID)
   for _,playerID in pairs(sGetPlayerList(-1)) do
      local name, active, spectator, teamID, allyTeamID, pingTime, cpuUsage, country, rank, _ = sGetPlayerInfo(playerID)
      set(m_player_info, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['name'] = name, ['active'] = active, ['spectator'] = spectator, ['teamID'] = teamID, ['allyTeamID'] = allyTeamID, ['pingTime'] = pingTime, ['cpuUsage'] = cpuUsage, ['country'] = country, ['rank'] = rank}, 1)
   end
   for _,teamID in pairs(sGetTeamList()) do
      local _teamID, leader, isDead, isAiTeam, side, allyTeamID, incomeMultiplier, customTeamKeys = sGetTeamInfo(teamID)
      local allyTeam = allyTeamNames[allyTeamID]
      if teamID ~= gaiaTeamID then
         local teamName = teamNames[teamID] or 'UNKNOWN'
         local killed, died, capturedBy, capturedFrom, received, sent = sGetTeamUnitStats(teamID)
         set(m_unit_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['type'] = 'killed'}, killed)
         set(m_unit_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['type'] = 'died'}, died)
         set(m_unit_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['type'] = 'capturedBy'}, capturedBy)
         set(m_unit_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['type'] = 'capturedFrom'}, capturedFrom)
         set(m_unit_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['type'] = 'received'}, received)
         set(m_unit_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['type'] = 'sent'}, sent)

         local current, storage, pull, income, expense, share, sent, received = sGetTeamResources(teamID, 'metal')
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'current'}, current)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'storage'}, storage)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'pull'}, pull)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'income'}, income)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'expense'}, expense)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'share'}, share)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'sent'}, sent)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',['stat'] = 'received'}, received)
         local current, storage, pull, income, expense, share, sent, received = sGetTeamResources(teamID, 'energy')
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'current'}, current)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'storage'}, storage)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'pull'}, pull)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'income'}, income)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'expense'}, expense)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'share'}, share)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'sent'}, sent)
         set(m_resource, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy',['stat'] = 'received'}, received)

         -- something is wrong about the following two...
         local used, produced, excessed, received, sent = sGetTeamUnitStats(teamID, 'metal')
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal', ['stat'] = 'used'}, used)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal', ['stat'] = 'produced'}, produced)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal', ['stat'] = 'excessed'}, excessed)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal', ['stat'] = 'received'}, received)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal', ['stat'] = 'sent'}, sent)
         local used, produced, excessed, received, sent = sGetTeamUnitStats(teamID, 'energy')
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'used'}, used)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'produced'}, produced)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'excessed'}, excessed)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'received'}, received)
         set(m_resource_stats, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'sent'}, sent)

         local range = sGetTeamStatsHistory(teamID)
         if range then
            local history = sGetTeamStatsHistory(teamID,range)[1]
            -- [t=00:45:50.381182][f=0005550] TableEcho = {
            -- [t=00:45:50.381206][f=0005550]     1 = {
            -- [t=00:45:50.381225][f=0005550]         unitsReceived = 0
            -- [t=00:45:50.381241][f=0005550]         energyExcess = 15
            -- [t=00:45:50.381252][f=0005550]         energyProduced = 17412.0898
            -- [t=00:45:50.381263][f=0005550]         metalExcess = 0
            -- [t=00:45:50.381275][f=0005550]         unitsSent = 0
            -- [t=00:45:50.381287][f=0005550]         time = 185
            -- [t=00:45:50.381298][f=0005550]         energySent = 5026.84961
            -- [t=00:45:50.381311][f=0005550]         metalReceived = 1.28367448
            -- [t=00:45:50.381320][f=0005550]         unitsDied = 0
            -- [t=00:45:50.381332][f=0005550]         unitsKilled = 0
            -- [t=00:45:50.381350][f=0005550]         metalProduced = 1119.94287
            -- [t=00:45:50.381372][f=0005550]         metalUsed = 2120.71509
            -- [t=00:45:50.381394][f=0005550]         energyUsed = 12428.9307
            -- [t=00:45:50.381414][f=0005550]         unitsCaptured = 0
            -- [t=00:45:50.381435][f=0005550]         energyReceived = 296.527679
            -- [t=00:45:50.381455][f=0005550]         metalSent = 0
            -- [t=00:45:50.381473][f=0005550]         unitsProduced = 19
            -- [t=00:45:50.381492][f=0005550]         damageDealt = 0
            -- [t=00:45:50.381510][f=0005550]         frame = 5550
            -- [t=00:45:50.381529][f=0005550]         unitsOutCaptured = 0
            -- [t=00:45:50.381549][f=0005550]         damageReceived = 0
            -- [t=00:45:50.381567][f=0005550]     },
            -- [t=00:45:50.381583][f=0005550] },
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'produced'}, history.energyProduced)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',  ['stat'] = 'produced'}, history.metalProduced)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'used'}, history.energyUsed)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',  ['stat'] = 'used'}, history.metalUsed)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'excess'}, history.energyExcess)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',  ['stat'] = 'excess'}, history.metalExcess)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'sent'}, history.energySent)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',  ['stat'] = 'sent'}, history.metalSent)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'energy', ['stat'] = 'received'}, history.energyReceived)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'metal',  ['stat'] = 'received'}, history.metalReceived)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'damage', ['stat'] = 'received'}, history.damageReceived)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'damage', ['stat'] = 'dealt'}, history.damageDealt)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'received'}, history.unitsReceived)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'sent'}, history.unitsSent)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'died'}, history.unitsDied)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'killed'}, history.unitsKilled)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'captured'}, history.unitsCaptured)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'produced'}, history.unitsProduced)
            set(m_resource_total, {['color'] = teamColors[teamID], ['gameID'] = gameID, ['allyTeam'] = allyTeam, ['team'] = teamName, ['resource'] = 'units',  ['stat'] = 'beenCaptured'}, history.unitsOutCaptured)
         end
         unitStats(teamID, teamName, allyTeam)
      end
   end
end

local function getMetrics()
   resetMetrics()
   updateMetrics()
   local res = ''
   for _, m in pairs(metrics) do
      res = res .. "# HELP " .. m.name .. " " .. m.help .. "\n"
      res = res .. "# TYPE " .. m.name .. " " .. m.type .. "\n"
      if m.type == 'histogram' then
         -- if m.static.labels then
         --    for labelset, valuecontainer in pairs(m.values) do
         --       for le, val in pairs(valuecontainer) do
         --          res = res .. m.static.name .. '{' .. labelset .. ',le="' .. val.value '"} ' .. valuecontainer.value .. "\n"
         --       end
         --    end
         -- else
         --    for le, val in pairs(m.values.value) do
         --       res = res .. m.static.name .. '{le="' .. le .. '"} ' .. val .. "\n"
         --    end
         -- end
      else  -- counter or gauge
         for labels,value in pairs(m.values) do
            res = res .. m.name .. labels .. ' ' .. value .. "\n"
         end
      end

   end

   local msg = "HTTP/1.1 200 OK\n"
   msg = msg .. "Content-Type: text/plain\n"
   --   msg = msg .. 'Content-Length: ' .. #res .. '\n'
   msg = msg .. "\n"
   msg = msg .. res

   return msg
end


-- "web" server
local server
function widget:Initialize()
   server = assert(socket.bind("*", 9123))
   local ip, port = server:getsockname()
   Spring.Echo("metrics port " .. port)
   server:settimeout(0.0000001)
   initGameID()
   for teamID=0,63 do
      local r,g,b = sGetTeamColor(teamID)
      if r and g and b then
         teamColors[teamID] = string.format("#%02x%02x%02x", r * 255, g * 255, b * 255)
         local _,_,_,_,_,allyTeamID,_,_ = sGetTeamInfo(teamID)
         if not allyTeamColors[allyTeamID] then
            allyTeamColors[allyTeamID] = teamColors[teamID]
         end
      end
      local ainame = GetAIName(teamID)
      if ainame then
         teamNames[teamID] = ainame .. ' (AI)'
      end
   end
   local allyTeamNameMapping = {
      ['#004dff']='Blue',
      ['#ff1005']='Red',
      ['#0ce818']='Green',
      ['#ffd70d']='Yellow',
      ['#ff00db']='Fuchsia',
      ['#ff6b00']='Orange',
      ['#0cc4e8']='Turquoise',
      ['#ffe178']='Raptors',
      ['#612461']='Scavengers'
   }
   for k,v in pairs(allyTeamColors) do
      allyTeamNames[k] = allyTeamNameMapping[v] or 'UNKNOWN'
      Spring.Echo("ally team " .. k .. " has color " .. v .. ' and name ' .. allyTeamNames[k])

   end
   for playerID=0,63 do
      local name, active, spectator, teamID, allyTeamID, pingTime, cpuUsage, country, rank, _ = sGetPlayerInfo(playerID)
      if name and not spectator then
         teamNames[teamID] = name
      end
   end
end

local function readRequest(client)
   local line = ''
   local continue = true
   while continue do
      line = client:receive('*l')
      if line == '' then
         continue = false
      end
   end
end
-- actual metrics
function widget:Update(dt) -- dt in seconds
   local client, err = server:accept()
   if client then
      readRequest(client)
      if gameID then
         client:send(getMetrics())
      end
      client:close()
   elseif err ~= 'timeout' then
      Spring.Echo("metrics error: " .. err)
   end
end
function initGameID()
   local count = {}
   local gaiaTeamID = sGetGaiaTeamID()
   for _,teamID in pairs(sGetTeamList()) do
      if teamID ~= gaiaTeamID then
         local _teamID, leader, isDead, isAiTeam, side, allyTeamID, incomeMultiplier, customTeamKeys = sGetTeamInfo(teamID)
         count[allyTeamID] = (count[allyTeamID] or 0) + 1
      end
   end
   local teams = ''
   for k,v in pairs(count) do
      if teams ~= '' then
         teams = teams .. 'v'
      end
      teams = teams .. v
   end
   gameID = os.date('%Y-%m-%dT%H:%M:%S ') .. teams .. ' on ' .. Game.mapName
   Spring.Echo('unique id for metrics: ' .. gameID)
end
