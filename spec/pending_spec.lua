local pending = require('pending')
local policy = require('policy')

local DAY = 86400
-- 2026-10-05 12:00 UTC was a Monday; os.date('*t') uses local time, so stay at noon to keep the weekday stable
local MONDAY = os.time({ year = 2026, month = 10, day = 5, hour = 12 })

local function make(start)
	local clock = { now = start or MONDAY }
	local p = pending.new({
		now = function()
			return clock.now
		end,
	})
	return p, clock
end

local function http(resource, target, decision)
	return {
		resource = resource,
		type = 'http',
		decision = decision or 'would_deny',
		reason = 'resource_not_in_lockfile',
		target = target,
		src = resource .. '/server.lua:1',
	}
end

local function dynamic(resource, origin)
	return {
		resource = resource,
		type = 'dynamic_code',
		decision = 'would_deny',
		reason = 'dynamic_code_not_granted',
		target = 'chunk',
		origin = origin,
	}
end

describe('pending: collecting requests', function()
	it('keeps only what a lockfile line can fix', function()
		local p = make()
		assert.is_true(p:observe(http('shop', 'https://api.shop.example/v1')))
		assert.is_false(p:observe(http('shop', 'https://api.shop.example/v1', 'allow')))
		assert.is_false(p:observe({
			resource = 'shop',
			type = 'http',
			decision = 'deny',
			reason = 'loopback_address',
			target = 'http://127.0.0.1/',
		}))
		assert.is_false(
			p:observe({ resource = 'shop', type = 'bytecode', decision = 'deny', reason = 'binary_chunk_refused' })
		)
		assert.is_false(p:observe(http('torii', 'https://a.example/')))
		assert.is_false(p:observe('not a table'))
		assert.are.equal(1, (p:counts()))
	end)

	it('groups repeated calls and remembers how often and where', function()
		local p, clock = make()
		p:observe(http('shop', 'https://api.shop.example/v1'))
		clock.now = clock.now + 60
		p:observe(http('shop', 'https://api.shop.example/v1'))
		local row = p:list()[1]
		assert.are.equal(2, row.item.count)
		assert.are.equal(MONDAY, row.item.first)
		assert.are.equal(MONDAY + 60, row.item.last)
		assert.are.equal('shop/server.lua:1', row.item.src)
	end)

	it('keeps the redacted part of a path out of the item', function()
		local p = make()
		p:observe(http('logs', 'https://discord.com/api/webhooks/123/<redacted>'))
		assert.are.equal('https://discord.com/api/webhooks/123', p:list()[1].item.target)
	end)

	it('remembers whether any loaded text came from memory', function()
		local p = make()
		p:observe(dynamic('lib_user', 'files'))
		assert.are.equal('common', p:list()[1].verdict.level)
		p:observe(dynamic('lib_user', 'memory'))
		assert.are.equal('suspicious', p:list()[1].verdict.level)
	end)

	it('is bounded, so a hostile resource cannot grow it without limit', function()
		local p = make()
		for i = 1, pending.MAX_PER_RESOURCE + 10 do
			p:observe(http('noisy', 'https://a' .. i .. '.example/'))
		end
		assert.are.equal(pending.MAX_PER_RESOURCE, (p:counts()))
		assert.are.equal(10, p.overflow)
		assert.is_true(p:observe(http('other', 'https://b.example/')), 'other resources still get room')
	end)
end)

describe('pending: the review', function()
	it('puts the worst resources first, numbers the rows, and flags the loader shape once', function()
		local p = make()
		p:observe(http('weather', 'https://api.weather.example/v1'))
		p:observe(http('shop', 'https://api.shop.example/'))
		p:observe(dynamic('shop', 'memory'))
		p:observe(http('versions', 'https://api.github.com/repos/overextended/ox_lib/releases/latest'))
		local rows = p:list()
		local summary = {}
		for _, row in ipairs(rows) do
			summary[#summary + 1] = { row.n, row.item.resource, row.resource_level, row.loader }
		end
		assert.are.same({
			{ 1, 'shop', 'suspicious', false },
			{ 2, 'shop', 'suspicious', true },
			{ 3, 'weather', 'check', false },
			{ 4, 'versions', 'common', false },
		}, summary)
		local total, suspicious = p:counts()
		assert.are.equal(4, total)
		assert.are.equal(1, suspicious, 'one suspicious script, whatever the number of its requests')
	end)

	it('drops what the lockfile now allows', function()
		local p = make()
		p:observe(http('weather', 'https://api.weather.example/v1/now'))
		p:observe(http('logs', 'https://discord.com/api/webhooks/123/<redacted>'))
		p:observe(dynamic('lib_user', 'files'))
		p:observe(dynamic('loader', 'memory'))
		p:refresh(policy.new({
			version = 1,
			resources = {
				weather = { http = { 'api.weather.example/v1' } },
				logs = { http = { 'discord.com/api/webhooks/123' } },
				lib_user = { dynamic_code = 'files' },
				loader = { dynamic_code = 'files' },
			},
		}))
		local rows = p:list()
		assert.are.equal(1, #rows)
		assert.are.equal('loader', rows[1].item.resource, "'files' does not cover text from memory")
	end)
end)

describe('pending: readiness for enforce mode', function()
	it('needs days, a weekend and nothing pending', function()
		local p, clock = make()
		p:tick('observe')
		assert.are.equal('not_ready_days', (p:readiness('observe')))
		clock.now = MONDAY + 3 * DAY
		p:tick('observe')
		assert.are.equal('not_ready_weekend', (p:readiness('observe')))
		clock.now = MONDAY + 5 * DAY -- Saturday
		p:tick('observe')
		local key, vars = p:readiness('observe')
		assert.are.equal('ready_enforce', key)
		assert.are.equal(5, vars.days)
		p:observe(http('shop', 'https://api.shop.example/'))
		assert.are.equal('not_ready_pending', (p:readiness('observe')))
		assert.are.equal('mode_enforce', (p:readiness('enforce')))
	end)

	it('does not start counting in enforce mode', function()
		local p = make()
		p:tick('enforce')
		assert.is_nil(p.since)
	end)
end)

describe('pending: saving and restoring', function()
	it('round-trips its state', function()
		local p, clock = make()
		p:tick('observe')
		p:observe(http('shop', 'https://api.shop.example/'))
		p:observe(dynamic('shop', 'memory'))
		local saved = p:export()
		local q = make(clock.now)
		q:import(saved)
		assert.are.same(p:export(), q:export())
		assert.are.equal(2, (q:counts()))
	end)

	it('skips anything malformed', function()
		local p = make()
		p:import('nope')
		p:import({ version = 2, items = { {} } })
		p:import({
			version = 1,
			since = 'yesterday',
			items = {
				{ resource = 'a' },
				'x',
				{ resource = 'b', kind = 'http', target = 'https://b.example/', count = 1 },
			},
		})
		assert.is_nil(p.since)
		assert.are.equal(1, (p:counts()))
	end)
end)
