local console = require('console')
local pending = require('pending')

local MONDAY = os.time({ year = 2026, month = 10, day = 5, hour = 12 })

local function make()
	local clock = { now = MONDAY }
	local review = pending.new({
		now = function()
			return clock.now
		end,
	})
	return review, clock
end

local function event(resource, target, extra)
	local e = {
		resource = resource,
		type = 'http',
		decision = 'would_deny',
		reason = 'resource_not_in_lockfile',
		target = target,
		src = resource .. '/server.lua:7',
	}
	for k, v in pairs(extra or {}) do
		e[k] = v
	end
	return e
end

local function joined(lines)
	return table.concat(lines, '\n')
end

describe('console: status', function()
	it('says when nothing is waiting, and what enforce mode still needs', function()
		local review = make()
		review:tick('observe')
		local text = joined(console.status(review, 'en', 'observe'))
		assert.truthy(text:find('No request waiting', 1, true))
		assert.truthy(text:find('Keep observing: 0 of at least 3 day(s)', 1, true))
	end)

	it('counts requests and suspicious ones, in French too', function()
		local review = make()
		review:observe(event('shop', 'https://45.133.1.20/p'))
		review:observe(event('weather', 'https://api.weather.example/v1'))
		local text = joined(console.status(review, 'fr', 'observe'))
		assert.truthy(text:find('2 demande(s) à examiner, 1 script(s) suspect(s)', 1, true))
		assert.truthy(text:find('torii review', 1, true))
	end)
end)

describe('console: review', function()
	it('lists rows worst first, with why and what to do', function()
		local review = make()
		review:observe(event('weather', 'https://api.weather.example/v1'))
		review:observe(event('shop', 'https://45.133.1.20/p'))
		review:observe({
			resource = 'shop',
			type = 'dynamic_code',
			decision = 'would_deny',
			reason = 'dynamic_code_not_granted',
			target = 'chunk',
			origin = 'memory',
		})
		local lines = console.review(review, 'en')
		local text = joined(lines)
		local first = text:find('shop wants to contact https://45.133.1.20/p', 1, true)
		local weather = text:find('weather wants to contact', 1, true)
		assert.truthy(first and weather and first < weather)
		assert.truthy(text:find('45.133.1.20 is a raw IP address', 1, true))
		assert.truthy(text:find('do not allow', 1, true))
		assert.truthy(text:find('download-and-run loader', 1, true))
		assert.truthy(text:find('ask the script author what it is for', 1, true))
		assert.truthy(text:find('torii approve', 1, true))
	end)

	it('says so when there is nothing to review', function()
		assert.truthy(joined(console.review(make(), 'fr')):find('Rien à examiner', 1, true))
	end)

	it('strips colour codes from what resources report', function()
		local review = make()
		review:observe(event('fake^2', 'https://a.example/^2COMMON^7'))
		local text = joined(console.review(review, 'en'))
		assert.is_nil(text:find('fake^2', 1, true))
		assert.is_nil(text:find('^2COMMON^7', 1, true))
		assert.truthy(text:find('^3CHECK^7', 1, true), 'torii keeps its own colours')
	end)
end)

describe('console: explain', function()
	it('shows counts, dates, call site and advice', function()
		local review, clock = make()
		review:observe(event('logs', 'https://discord.com/api/webhooks/1/<redacted>'))
		clock.now = clock.now + 3600
		review:observe(event('logs', 'https://discord.com/api/webhooks/1/<redacted>'))
		local text = joined(console.explain(review, 'en', '1'))
		assert.truthy(text:find('seen 2 time(s)', 1, true))
		assert.truthy(text:find('logs/server.lua:7', 1, true))
		assert.truthy(text:find('Integrations > Webhooks', 1, true))
	end)

	it('answers an unknown number without failing', function()
		assert.truthy(joined(console.explain(make(), 'en', '9')):find('No request number 9', 1, true))
		assert.truthy(joined(console.explain(make(), 'en', nil)):find('No request number', 1, true))
	end)
end)
