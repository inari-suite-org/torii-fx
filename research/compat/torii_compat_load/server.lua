-- Synthetic load for a torii compatibility run. It exercises, at a steady rate, the paths torii sits on:
-- exports and events between resources, ox_lib modules (compiled with load), oxmysql queries, HTTP to an approved
-- local endpoint, HTTP to an unapproved one (must be blocked in enforce mode), load() of text, convar reads.
-- Every minute it prints one STATS line that the driver script collects. It never involves real players.

local TICK_MS = tonumber(GetConvar('torii_compat_tick_ms', '50'))
local QBCore = exports['qb-core']:GetCoreObject()

local stats = {
	ticks = 0,
	exports = 0,
	events = 0,
	ox_lib = 0,
	sql_ok = 0,
	sql_err = 0,
	http_ok = 0,
	http_fail = 0,
	denied_http_sent = 0,
	load_ok = 0,
	errors = 0,
}

AddEventHandler('torii_compat:ping', function(n)
	stats.events = stats.events + 1
	return n
end)

MySQL.ready(function()
	MySQL.query.await('CREATE TABLE IF NOT EXISTS torii_compat (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(64))')
end)

local function step()
	stats.ticks = stats.ticks + 1

	-- exports and shared data of the framework
	local players = QBCore.Functions.GetPlayers()
	local items = QBCore.Shared.Items
	stats.exports = stats.exports + 1 + (players and 0 or 0) + (items and 0 or 0)

	-- events between handlers
	TriggerEvent('torii_compat:ping', stats.ticks)

	-- ox_lib modules
	local copy = lib.table.deepclone({ a = 1, b = { c = stats.ticks } })
	local rounded = lib.math.round(copy.b.c / 3, 2)
	local token = lib.string.random('AAA111')
	if rounded and token then
		stats.ox_lib = stats.ox_lib + 1
	end

	-- dynamic code on text (granted to this resource)
	local fn = load('return ' .. (stats.ticks % 97))
	if fn and fn() == stats.ticks % 97 then
		stats.load_ok = stats.load_ok + 1
	end

	-- database (oxmysql, JavaScript runtime)
	if stats.ticks % 4 == 0 then
		MySQL.scalar('SELECT 1', {}, function(result)
			if result == 1 then
				stats.sql_ok = stats.sql_ok + 1
			else
				stats.sql_err = stats.sql_err + 1
			end
		end)
	end
	if stats.ticks % 200 == 0 then
		MySQL.insert('INSERT INTO torii_compat (v) VALUES (?)', { token }, function() end)
	end

	-- HTTP: an approved local endpoint, and an unapproved host that enforce mode must block
	if stats.ticks % 20 == 0 then
		PerformHttpRequest('http://127.0.0.1:8099/ok', function(status)
			if status == 200 then
				stats.http_ok = stats.http_ok + 1
			else
				stats.http_fail = stats.http_fail + 1
			end
		end, 'GET')
	end
	if stats.ticks % 600 == 0 then
		stats.denied_http_sent = stats.denied_http_sent + 1
		PerformHttpRequest('https://not-approved.invalid/x', function() end, 'GET')
	end

	-- convar reads, sensitive and ordinary
	if stats.ticks % 100 == 0 then
		GetConvar('sv_hostname', '')
		GetConvar('mysql_connection_string', '')
	end
end

CreateThread(function()
	while true do
		local ok, err = pcall(step)
		if not ok then
			stats.errors = stats.errors + 1
			if stats.errors <= 5 then
				print(('[compat] step error: %s'):format(tostring(err)))
			end
		end
		Wait(TICK_MS)
	end
end)

CreateThread(function()
	while true do
		Wait(60000)
		print(
			('[compat] STATS lua_kb=%d ticks=%d exports=%d events=%d ox_lib=%d load_ok=%d sql_ok=%d sql_err=%d http_ok=%d http_fail=%d denied_http_sent=%d errors=%d'):format(
				math.floor(collectgarbage('count')),
				stats.ticks,
				stats.exports,
				stats.events,
				stats.ox_lib,
				stats.load_ok,
				stats.sql_ok,
				stats.sql_err,
				stats.http_ok,
				stats.http_fail,
				stats.denied_http_sent,
				stats.errors
			)
		)
	end
end)
