local dkjson = require('dkjson')

-- Runs torii/server/core.lua against simulated FiveM natives: the wiring between the log, the review list, the saved
-- state and the "torii" console command. Threads are recorded, not run (they loop forever in the real server).

local function read_file(path)
	local file = assert(io.open(path, 'rb'))
	local text = file:read('a')
	file:close()
	return text
end

local CORE_SOURCE = read_file('torii/server/core.lua')

local function start_core(opts)
	opts = opts or {}
	local files = opts.files or {}
	local state = {
		printed = {},
		commands = {},
		events = {},
		exports = {},
		threads = {},
		timers = {},
		saved = files,
		invoking = nil,
	}
	local convars = opts.convars or {}
	local env = setmetatable({
		print = function(...)
			state.printed[#state.printed + 1] = table.concat({ ... }, ' ')
		end,
		json = { encode = dkjson.encode, decode = dkjson.decode },
		io = {
			open = function()
				return { write = function() end, flush = function() end, close = function() end }
			end,
		},
		LoadResourceFile = function(resource, file)
			if resource == 'torii' and file:match('^src/') then
				return read_file('torii/' .. file)
			end
			if resource == 'torii' then
				return files[file]
			end
			return nil
		end,
		SaveResourceFile = function(resource, file, text)
			assert(resource == 'torii')
			files[file] = text
			return true
		end,
		GetConvar = function(name, default)
			return convars[name] or default
		end,
		GetInvokingResource = function()
			return state.invoking
		end,
		GetGameTimer = function()
			return 0
		end,
		exports = function(name, fn)
			state.exports[name] = fn
		end,
		RegisterCommand = function(name, fn, restricted)
			state.commands[name] = { fn = fn, restricted = restricted }
		end,
		AddEventHandler = function(name, fn)
			state.events[name] = fn
		end,
		CreateThread = function(fn)
			state.threads[#state.threads + 1] = fn
		end,
		SetTimeout = function(_, fn)
			state.timers[#state.timers + 1] = fn
		end,
		CancelEvent = function() end,
		GetNumResourceMetadata = function()
			return 0
		end,
		GetResourceMetadata = function()
			return nil
		end,
	}, { __index = _G })
	assert(load(CORE_SOURCE, '@@torii/server/core.lua', 't', env))()

	function state.report(resource, event)
		state.invoking = resource
		state.exports.report(event)
		state.invoking = nil
	end
	function state.run(...)
		state.printed = {}
		state.commands.torii.fn(0, { ... }, 'torii')
		return table.concat(state.printed, '\n')
	end
	function state.stop()
		state.events.onResourceStop('torii')
	end
	return state
end

local function blocked_http(target)
	return {
		type = 'http',
		api = 'PerformHttpRequestInternalEx',
		decision = 'would_deny',
		reason = 'resource_not_in_lockfile',
		target = target,
		src = 'shop/server.lua:3',
	}
end

describe('core: review list and console command', function()
	it('registers a restricted, read-only torii command', function()
		local core = start_core()
		assert.is_true(core.commands.torii.restricted)
		assert.truthy(core.run('help'):find('torii review', 1, true))
	end)

	it('turns reports into a numbered review, in the chosen language', function()
		local core = start_core({ convars = { torii_lang = 'fr' } })
		core.report('shop', blocked_http('https://45.133.1.20/payload'))
		core.report('weather', blocked_http('https://api.weather.example/v1'))
		local text = core.run('review')
		assert.truthy(text:find('2 demande(s) en attente', 1, true))
		assert.truthy(text:find('SUSPECT', 1, true))
		assert.truthy(text:find('shop veut contacter https://45.133.1.20/payload', 1, true))
		assert.truthy(core.run():find('2 demande(s) à examiner, 1 script(s) suspect(s)', 1, true))
		assert.truthy(core.run('explain', '1'):find('shop/server.lua:3', 1, true))
	end)

	it('attributes a report to the resource that sent it, whatever the report says', function()
		local core = start_core()
		local forged = blocked_http('https://45.133.1.20/x')
		forged.resource = 'victim'
		core.report('attacker', forged)
		local text = core.run('review')
		assert.truthy(text:find('attacker wants to contact', 1, true))
		assert.is_nil(text:find('victim', 1, true))
	end)

	it('ignores reports nobody can approve, and its own events', function()
		local core = start_core()
		core.report(
			'shop',
			{ type = 'http', decision = 'deny', reason = 'loopback_address', target = 'http://127.0.0.1/' }
		)
		core.report(
			'shop',
			{ type = 'bytecode', decision = 'deny', reason = 'binary_chunk_refused', target = 'bytecode' }
		)
		assert.truthy(core.run('review'):find('Nothing to review', 1, true))
	end)
end)

describe('core: saved state', function()
	it('saves soon after a change, without waiting for the resource to stop', function()
		local core = start_core()
		core.report('shop', blocked_http('https://45.133.1.20/payload'))
		core.report('shop', blocked_http('https://45.133.1.21/payload'))
		assert.are.equal(1, #core.timers, 'one save scheduled for a burst of changes')
		core.timers[1]()
		assert.truthy(core.saved['review-state.json']:find('45.133.1.21', 1, true))
	end)

	it('keeps the review across a restart', function()
		local core = start_core()
		core.report('shop', blocked_http('https://45.133.1.20/payload'))
		core.stop()
		assert.is_string(core.saved['review-state.json'])
		local again = start_core({ files = core.saved })
		assert.truthy(again.run('review'):find('shop wants to contact https://45.133.1.20/payload', 1, true))
	end)

	it('drops what the lockfile granted in the meantime', function()
		local core = start_core()
		core.report('weather', blocked_http('https://api.weather.example/v1/now'))
		core.report('shop', blocked_http('https://45.133.1.20/payload'))
		core.stop()
		local files = core.saved
		files['policy.lock.json'] =
			dkjson.encode({ version = 1, resources = { weather = { http = { 'api.weather.example/v1' } } } })
		local text = start_core({ files = files }).run('review')
		assert.is_nil(text:find('weather', 1, true))
		assert.truthy(text:find('shop', 1, true))
	end)

	it('survives a damaged state file', function()
		local core = start_core({ files = { ['review-state.json'] = '{not json' } })
		assert.truthy(core.run('review'):find('Nothing to review', 1, true))
	end)

	it('says enforce mode is on instead of a readiness hint', function()
		local core = start_core({ convars = { torii_mode = 'enforce' } })
		assert.truthy(core.run():find('Enforce mode', 1, true))
	end)
end)
