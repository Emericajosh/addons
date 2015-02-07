_addon.name = 'healBot'
_addon.author = 'Lorand'
_addon.command = 'hb'
_addon.version = '2.3.4'

require('luau')
rarr = string.char(129,168)
sparr = ' '..rarr..' '
res = require('resources')
config = require('config')
texts = require('texts')
packets = require('packets')

require 'healBot_statics'
require 'healBot_utils'
require 'healBot_buffHandling'
require 'healBot_cureHandling'
require 'healBot_followHandling'
require 'healBot_packetHandling'

aliases = config.load('..\\shortcuts\\data\\aliases.xml')

local trusts = populateTrustList()
local ignoreList = S{}
local extraWatchList = S{}

local moveInfo = texts.new({pos={x=0,y=18}})
local actionInfo = texts.new({pos={x=0,y=0}})

windower.register_event('load', function()
	lastAction = os.clock()
	lastFollowCheck = os.clock()
	actionStart = os.clock()
	actionEnd = actionStart + 0.1
	
	local player = windower.ffxi.get_player()
	if player ~= nil then
		myName = player.name
	else
		myName = 'Player'
	end
	
	showPacketInfo = false
	showMoveInfo = false
	showActionInfo = true
	debugMode = false
	active = false
	actionDelay = 0.08
	minCureTier = 3
	lastActingState = false
	partyMemberInfo = {}
	ignoreTrusts = true
end)

windower.register_event('logout', function()
	windower.send_command('lua unload healBot')
end)

windower.register_event('incoming chunk', handle_incoming_chunk)
windower.register_event('addon command', processCommand)

windower.register_event('prerender', function()
	local now = os.clock()
	local moving = isMoving()
	local acting = isPerformingAction(moving)
	local player = windower.ffxi.get_player()
	if (player ~= nil) and S{0,1}:contains(player.status) then	--Assert player is idle or engaged
		if follow and ((now - lastFollowCheck) > followDelay) then
			if not needToMove(followTarget) then
				windower.ffxi.run(false)
			else
				moveTowards(followTarget)
				moving = true
			end
			lastFollowCheck = now
		end
		
		local disabled = buffActive('Sleep', 'Petrification', 'Charm', 'Terror', 'Lullaby', 'Stun')
		local busy = moving or acting or disabled
		if active and (not busy) and ((now - lastAction) > actionDelay) then
			local action = cureSomeone() or checkDebuffs(player, debuffList) or checkBuffs(player, buffList)
			if (action ~= nil) then
				local spell = action.action
				local tname = action.targetName
				local msg = action.msg or ''
				atcd(spell.en..sparr..tname..msg)
				wcmd(spell.prefix, spell.en, tname)
			end
			lastAction = now
		end
	end
end)

function wcmd(prefix, action, target)
	windower.send_command('input '..prefix..' "'..action..'" '..target)
	actionDelay = 0.6
end

function activate()
	local player = windower.ffxi.get_player()
	if player ~= nil then
		maxCureTier = determineHighestCureTier()
		active = (maxCureTier > 0)
	end
	printStatus()
	checkOwnBuffs()
end

function isMoving()
	if (getPosition() == nil) then
		moveInfo:hide()
		return true
	end
	lastPos = lastPos and lastPos or getPosition()
	posArrival = posArrival and posArrival or os.clock()
	local currentPos = getPosition()
	local now = os.clock()
	local moving = true
	local timeAtPos = math.floor((now - posArrival)*10)/10
	if (lastPos:equals(currentPos)) then
		moving = (timeAtPos < 0.5)
	else
		lastPos = currentPos
		posArrival = now
	end
	if math.floor(timeAtPos) == timeAtPos then
		timeAtPos = timeAtPos..'.0'
	end
	moveInfo:text('Time @ '..currentPos:toString()..': '..timeAtPos..'s')
	moveInfo:visible(showMoveInfo)
	return moving
end

function isPerformingAction(moving)
	if (os.clock() - actionStart) > 8 then
		--Precaution in case an action completion isn't registered for a long time
		actionEnd = os.clock()
	end
	
	local acting = (actionEnd < actionStart)
	local status = acting and 'Performing an Action' or (moving and 'Moving' or 'Idle')
	
	if (lastActingState ~= acting) then	--If the current acting state is different from the last one
		if lastActingState then			--If an action was being performed
			actionDelay = 2.75			--Set a longer delay
			lastAction = os.clock()			--The delay will be from this time
		else					--If no action was being performed
			actionDelay = 0.1			--Set a short delay
		end
		lastActingState = acting		--Refresh the last acting state
	end
	
	actionInfo:text(myName..' is '..status)
	actionInfo:visible(showActionInfo)
	return acting
end

function isTooFar(name)
	local target = windower.ffxi.get_mob_by_name(name)
	if target ~= nil then
		return math.sqrt(target.distance) > 20.8
	end
	return true
end

function canCast(spell)
	local player = windower.ffxi.get_player()
	if (player == nil) or (spell == nil) then return false end
	local mainCanCast = (spell.levels[player.main_job_id] ~= nil) and (spell.levels[player.main_job_id] <= player.main_job_level)
	local subCanCast = (spell.levels[player.sub_job_id] ~= nil) and (spell.levels[player.sub_job_id] <= player.sub_job_level)
	local spellAvailable = windower.ffxi.get_spells()[spell.id]
	return spellAvailable and (mainCanCast or subCanCast)
end

function addPlayer(list, player)
	if (player ~= nil) and (not (ignoreList:contains(player.name))) then
		if (ignoreTrusts and trusts:contains(player.name)) then return end
		local status = player.mob and player.mob.status or player.status
		if (S{2,3}:contains(status)) or (player.hpp <= 0) then
			--Player is dead.  Reset their buff/debuff lists and don't include them in monitored list
			resetDebuffTimers(player.name)
			resetBuffTimers(player.name)
		else
			list[player.name] = player
		end
	end
end

function getMonitoredPlayers()
	local pt = windower.ffxi.get_party()
	local me = pt.p0
	local targets = S{}
	
	local pty = {pt.p0,pt.p1,pt.p2,pt.p3,pt.p4,pt.p5}
	for _,player in pairs(pty) do
		if (me.zone == player.zone) then
			addPlayer(targets, player)
		end
	end
	
	local alliance = {pt.a10,pt.a11,pt.a12,pt.a13,pt.a14,pt.a15,pt.a20,pt.a21,pt.a22,pt.a23,pt.a24,pt.a25}
	for _,ally in pairs(alliance) do
		if (ally ~= nil) and (extraWatchList:contains(ally.name)) and (me.zone == ally.zone) then
			addPlayer(targets, ally)
		end
	end
	
	for extraName,_ in pairs(extraWatchList) do
		local extraPlayer = windower.ffxi.get_mob_by_name(extraName)
		if (extraPlayer ~= nil) and (not targets:contains(extraPlayer.name)) and (me.zone == extraPlayer.zone) then
			addPlayer(targets, extraPlayer)
		end
	end
	return targets
end

function printInfo()
	windower.add_to_chat(0, 'healBot comands: (to be implemented)')
end

function printStatus()
	windower.add_to_chat(0, 'healBot: '..(active and 'active' or 'off'))
end

-----------------------------------------------------------------------------------------------------------
--[[
Copyright � 2015, Lorand
All rights reserved.
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
    * Neither the name of healBot nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL Lorand BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--]]
-----------------------------------------------------------------------------------------------------------