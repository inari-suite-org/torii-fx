local policy = require('policy')

local function lock_with(resource_grants)
	return { version = 1, exempt = { 'builtin' }, resources = resource_grants }
end

describe('policy.parse_entry / entry_matches', function()
	local url = require('url')

	local function matches(entry_text, request_url)
		local entry = assert(policy.parse_entry(entry_text))
		return policy.entry_matches(entry, assert(url.parse(request_url)))
	end

	it('matches a host exactly, https by default', function()
		assert.is_true(matches('api.example.com', 'https://api.example.com/anything?x=1'))
		assert.is_false(matches('api.example.com', 'https://evil.example.com/'))
		assert.is_false(matches('api.example.com', 'https://example.com/'))
		assert.is_false(matches('api.example.com', 'http://api.example.com/'))
	end)

	it('lets the admin allow plain http explicitly', function()
		assert.is_true(matches('http://api.example.com', 'http://api.example.com/x'))
		assert.is_false(matches('http://api.example.com', 'https://api.example.com/x'))
	end)

	it('compares ports', function()
		assert.is_false(matches('api.example.com', 'https://api.example.com:8443/'))
		assert.is_true(matches('api.example.com:8443', 'https://api.example.com:8443/'))
		assert.is_true(matches('api.example.com:443', 'https://api.example.com/'))
	end)

	it('matches path prefixes on segment boundaries only (Discord webhook case)', function()
		local entry = 'discord.com/api/webhooks/123456'
		assert.is_true(matches(entry, 'https://discord.com/api/webhooks/123456'))
		assert.is_true(matches(entry, 'https://discord.com/api/webhooks/123456/sometoken?wait=true'))
		assert.is_false(matches(entry, 'https://discord.com/api/webhooks/1234567/sometoken'))
		assert.is_false(matches(entry, 'https://discord.com/api/webhooks/999/sometoken'))
		assert.is_false(matches(entry, 'https://discord.com/'))
	end)

	it('cannot be escaped with dot segments or encoded dots', function()
		local entry = 'api.example.com/v1'
		assert.is_false(matches(entry, 'https://api.example.com/v1/../admin'))
		assert.is_false(matches(entry, 'https://api.example.com/v1/%2e%2e/admin'))
		assert.is_true(matches(entry, 'https://api.example.com/v1/./users'))
	end)

	it('refuses wildcard and malformed entries', function()
		assert.is_nil(policy.parse_entry('*.example.com'))
		assert.is_nil(policy.parse_entry(''))
		assert.is_nil(policy.parse_entry('https://user@example.com'))
		assert.is_nil(policy.parse_entry(42))
	end)
end)

describe('policy.declaration_hash', function()
	it('is stable and order-independent', function()
		local a = policy.declaration_hash({ http = { 'b.example.com', 'a.example.com' }, dynamic_code = true })
		local b = policy.declaration_hash({ http = { ' a.example.com ', 'b.example.com' }, dynamic_code = true })
		assert.are.equal(a, b)
		assert.are.equal(64, #a)
	end)

	it('changes when any permission changes', function()
		local base = policy.declaration_hash({ http = { 'a.example.com' }, dynamic_code = false })
		assert.are_not.equal(
			base,
			policy.declaration_hash({ http = { 'a.example.com', 'b.example.com' }, dynamic_code = false })
		)
		assert.are_not.equal(base, policy.declaration_hash({ http = { 'a.example.com' }, dynamic_code = true }))
		assert.are_not.equal(
			base,
			policy.declaration_hash({ http = { 'a.example.com' }, dynamic_code = false, follow_redirects = true })
		)
	end)

	it('matches the Node CLI implementation (shared test vector)', function()
		local hash = policy.declaration_hash({
			http = { 'discord.com/api/webhooks/123', 'api.example.com' },
			dynamic_code = true,
			follow_redirects = false,
		})
		assert.are.equal('1529d180165a4ed687b671ddcf294eb70ddf5878b2ddda8e7edbe89e1951720d', hash)
	end)
end)

describe('policy.read_declaration', function()
	it('reads torii_* keys through the metadata natives', function()
		local meta = { torii_http = { 'a.example.com', 'b.example.com/v1' }, torii_dynamic_code = { 'yes' } }
		local decl = policy.read_declaration(function(_, key)
			return meta[key] and #meta[key] or 0
		end, function(_, key, index)
			return meta[key] and meta[key][index + 1]
		end, 'res')
		assert.are.same({ 'a.example.com', 'b.example.com/v1' }, decl.http)
		assert.is_true(decl.dynamic_code)
		assert.is_false(decl.follow_redirects)
	end)
end)

describe('Policy:check_http', function()
	local p = policy.new(lock_with({
		res = { http = { 'api.example.com/v1', 'discord.com/api/webhooks/123' }, dynamic_code = false },
		open = { http = { 'pastebin.com' } },
	}))

	it('allows covered requests', function()
		local d = p:check_http('res', 'https://api.example.com/v1/users?token=abc')
		assert.is_true(d.allow)
		assert.are.equal('allowed', d.reason)
	end)

	it('denies everything for resources missing from the lockfile', function()
		local d = p:check_http('stranger', 'https://api.example.com/v1/users')
		assert.is_false(d.allow)
		assert.are.equal('resource_not_in_lockfile', d.reason)
	end)

	it('denies hosts outside the allow-list', function()
		local d = p:check_http('res', 'https://cipher-panel.example/api')
		assert.is_false(d.allow)
		assert.are.equal('not_in_allow_list', d.reason)
	end)

	it('denies unparseable and trick urls', function()
		for _, raw in ipairs({
			'https://api.example.com@evil.example/v1',
			'https://api.example.com\\@evil.example/v1',
			'https://api.example.com.evil.example/v1',
			'api.example.com/v1',
			'',
			42,
		}) do
			assert.is_false(p:check_http('res', raw).allow, tostring(raw))
		end
	end)

	it('denies private and loopback targets even if the lockfile lists them', function()
		local lock = lock_with({ res = { http = { 'localhost', '127.0.0.1', '10.0.0.5' } } })
		local strict = policy.new(lock)
		assert.are.equal('local_name', strict:check_http('res', 'http://localhost/').reason)
		assert.is_false(strict:check_http('res', 'https://127.0.0.1/').allow)
		assert.is_false(strict:check_http('res', 'https://10.0.0.5/').allow)
		local dev = policy.new(lock, { allow_private = true })
		assert.is_true(dev:check_http('res', 'https://127.0.0.1/').allow)
	end)

	it('never puts the query string or a long token into the log-safe target', function()
		local token = 'abcdefghijklmnopqrstuvwxyz0123456789'
		local d = p:check_http('res', 'https://discord.com/api/webhooks/123/' .. token .. '?secret=1')
		assert.is_true(d.allow)
		assert.is_nil(d.target:find(token, 1, true))
		assert.is_nil(d.target:find('secret', 1, true))
		assert.are.equal('https://discord.com/api/webhooks/123', d.target)
	end)

	it('warns when a user-content host is allowed without a path prefix', function()
		assert.are.equal('user_content', p:check_http('open', 'https://pastebin.com/raw/x').risk)
		assert.is_nil(p:check_http('res', 'https://api.example.com/v1/x').risk)
	end)
end)

describe('Policy:check_dynamic_code / follow_redirects / exempt', function()
	local p = policy.new(lock_with({
		granted = { dynamic_code = true, follow_redirects = true },
		plain = { dynamic_code = false },
	}))

	it('requires an explicit grant', function()
		assert.is_true(p:check_dynamic_code('granted'))
		assert.is_false(p:check_dynamic_code('plain'))
		assert.is_false(p:check_dynamic_code('unknown'))
	end)

	it('does not follow redirects unless granted', function()
		assert.is_true(p:follow_redirects('granted'))
		assert.is_false(p:follow_redirects('plain'))
		assert.is_false(p:follow_redirects('unknown'))
	end)

	it('reads the exempt list', function()
		assert.is_true(p:is_exempt('builtin'))
		assert.is_false(p:is_exempt('plain'))
	end)
end)

describe('policy.new robustness', function()
	it('survives a missing or broken lockfile', function()
		assert.is_false(policy.new(nil):check_http('x', 'https://example.com/').allow)
		assert.is_false(policy.new('not a table'):check_http('x', 'https://example.com/').allow)
		local wrong_version = policy.new({ version = 99, resources = { x = { http = { 'example.com' } } } })
		assert.is_false(wrong_version:check_http('x', 'https://example.com/').allow)
		assert.are.equal(1, #wrong_version.warnings)
	end)

	it('skips invalid entries and reports them', function()
		local p = policy.new(lock_with({ res = { http = { '*.example.com', 'good.example.com', 7 } } }))
		assert.is_true(p:check_http('res', 'https://good.example.com/').allow)
		assert.are.equal(2, #p.warnings)
	end)
end)
