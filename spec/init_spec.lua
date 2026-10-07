local dkjson = require('dkjson')

-- Runs torii/init.lua against a simulated resource state: this is the path every protected resource takes.

local function read_file(path)
	local file = assert(io.open(path, 'rb'))
	local text = file:read('a')
	file:close()
	return text
end

local INIT_SOURCE = read_file('torii/init.lua')

--- Builds the globals of a fake Lua state and runs init.lua inside it.
local function run_init(opts)
	opts = opts or {}
	local reports, printed = {}, {}
	local metadata = opts.metadata or {}
	local lock_text = opts.lock_text
	if lock_text == nil then
		lock_text = dkjson.encode({ version = 1, resources = {} })
	end

	local state = { reports = reports, printed = printed }
	local env = {
		print = function(...)
			printed[#printed + 1] = table.concat({ ... }, ' ')
		end,
		IsDuplicityVersion = function()
			return opts.server ~= false
		end,
		GetCurrentResourceName = function()
			return opts.resource or 'shop'
		end,
		LoadResourceFile = function(resource, file)
			if resource == 'torii' and file == 'policy.lock.json' then
				return lock_text
			end
			if resource == 'torii' and file:match('^src/') and not opts.missing_modules then
				return read_file('torii/' .. file)
			end
			return nil
		end,
		GetConvar = function(name, default)
			if name == 'torii_mode' then
				return opts.mode or 'observe'
			end
			return default
		end,
		GetNumResourceMetadata = function(_, key)
			return metadata[key] and #metadata[key] or 0
		end,
		GetResourceMetadata = function(_, key, index)
			return metadata[key] and metadata[key][index + 1]
		end,
		GetGameTimer = function()
			return 0
		end,
		json = { decode = dkjson.decode, encode = dkjson.encode },
		msgpack = { pack = dkjson.encode, unpack = dkjson.decode },
		exports = setmetatable({}, {
			__index = function(_, name)
				assert.are.equal('torii', name)
				return {
					report = function(_, event)
						if opts.core_down then
							error('No such export report in resource torii')
						end
						reports[#reports + 1] = event
					end,
				}
			end,
		}),
		debug = { getinfo = debug.getinfo, getupvalue = debug.getupvalue },
		load = load,
		pcall = pcall,
		error = error,
		tostring = tostring,
		tonumber = tonumber,
		type = type,
		select = select,
		next = next,
		rawget = rawget,
		rawset = rawset,
		ipairs = ipairs,
		pairs = pairs,
		setmetatable = setmetatable,
		string = string,
		table = table,
		math = math,
		Citizen = {
			InvokeNative = function()
				return 'native'
			end,
		},
		PerformHttpRequestInternalEx = function()
			return 1
		end,
		PerformHttpRequestInternal = function()
			return 1
		end,
		ExecuteCommand = function() end,
		SetHttpHandler = function() end,
		SaveResourceFile = function()
			return true
		end,
	}
	env._G = env
	local original = {
		load = env.load,
		get_convar = env.GetConvar,
		http = env.PerformHttpRequestInternalEx,
		getupvalue = env.debug.getupvalue,
	}
	state.env = env
	state.original = original
	local chunk = assert(load(INIT_SOURCE, '@@torii/init.lua', 't', env))
	chunk()
	return state
end

describe('init.lua', function()
	it('does nothing on the client', function()
		local s = run_init({ server = false })
		assert.are.equal(s.original.load, s.env.load)
		assert.are.equal(s.original.http, s.env.PerformHttpRequestInternalEx)
		assert.are.equal(0, #s.reports)
	end)

	it('does nothing inside the torii resource itself', function()
		local s = run_init({ resource = 'torii' })
		assert.are.equal(s.original.load, s.env.load)
		assert.are.equal(0, #s.reports)
	end)

	it('installs the hooks on the server and attests that it ran', function()
		local s = run_init()
		assert.are_not.equal(s.original.load, s.env.load)
		assert.are_not.equal(s.original.http, s.env.PerformHttpRequestInternalEx)
		assert.are_not.equal(s.original.getupvalue, s.env.debug.getupvalue)
		assert.are.equal('attest', s.reports[#s.reports].type)
		assert.are.same({}, s.printed)
	end)

	it('enforces the lockfile it finds (denied host, refused load, granted host)', function()
		local lock = dkjson.encode({
			version = 1,
			resources = { shop = { http = { 'api.example.com' }, dynamic_code = false } },
		})
		local s = run_init({ mode = 'enforce', lock_text = lock })
		assert.are.equal(-1, s.env.PerformHttpRequestInternalEx({ url = 'https://evil.example/' }))
		assert.are.equal(1, s.env.PerformHttpRequestInternalEx({ url = 'https://api.example.com/x' }))
		local fn, err = s.env.load('return 1')
		assert.is_nil(fn)
		assert.is_truthy(err:find('not permitted', 1, true))
	end)

	it('reads the mode from the convar', function()
		local s = run_init({ mode = 'observe' })
		assert.are.equal(1, s.env.PerformHttpRequestInternalEx({ url = 'https://evil.example/' }))
		local deny
		for _, r in ipairs(s.reports) do
			if r.type == 'http' then
				deny = r
			end
		end
		assert.are.equal('would_deny', deny.decision)
	end)

	it('treats a missing or corrupt lockfile as "no grants"', function()
		for _, text in ipairs({ 'not json {{{', '[]', '{"version":99}' }) do
			local s = run_init({ mode = 'enforce', lock_text = text })
			assert.are.equal(-1, s.env.PerformHttpRequestInternalEx({ url = 'https://api.example.com/x' }), text)
		end
	end)

	it('reports declarations that were never approved or changed since approval', function()
		local metadata = { torii_http = { 'api.example.com' } }
		local pending = run_init({ metadata = metadata })
		local found
		for _, r in ipairs(pending.reports) do
			if r.type == 'declaration' then
				found = r.reason
			end
		end
		assert.are.equal('declaration_not_approved', found)

		local lock = dkjson.encode({
			version = 1,
			resources = { shop = { http = { 'api.example.com' }, declaration_hash = string.rep('0', 64) } },
		})
		local changed = run_init({ metadata = metadata, lock_text = lock })
		found = nil
		for _, r in ipairs(changed.reports) do
			if r.type == 'declaration' then
				found = r.reason
			end
		end
		assert.are.equal('declaration_changed_since_approval', found)

		local approved_hash = require('policy').declaration_hash({ http = { 'api.example.com' } })
		local ok_lock = dkjson.encode({
			version = 1,
			resources = { shop = { http = { 'api.example.com' }, declaration_hash = approved_hash } },
		})
		local same = run_init({ metadata = metadata, lock_text = ok_lock })
		for _, r in ipairs(same.reports) do
			assert.are_not.equal('declaration', r.type)
		end
	end)

	it('never raises when torii cannot load its modules; it says so and leaves the resource running', function()
		local s
		assert.has_no.errors(function()
			s = run_init({ missing_modules = true })
		end)
		assert.are.equal(s.original.load, s.env.load)
		assert.is_truthy(s.printed[1]:find('could not protect shop', 1, true))
	end)

	it('falls back to the console when the torii core is not running', function()
		local s = run_init({ core_down = true, mode = 'observe' })
		s.env.PerformHttpRequestInternalEx({ url = 'https://evil.example/' })
		local joined = table.concat(s.printed, '\n')
		assert.is_truthy(joined:find('[torii] shop http', 1, true))
	end)
end)
