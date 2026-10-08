local verdicts = require('verdicts')

local function level(target)
	return verdicts.http(target).level
end

local function read(path)
	local file = assert(io.open(path, 'rb'))
	local text = file:read('a')
	file:close()
	return text
end

--- Quoted strings inside the first `[ ... ]` that follows `anchor` in a JavaScript file.
local function js_array(text, anchor)
	local start = assert(text:find(anchor, 1, true), anchor)
	local body = assert(text:match('%b[]', start), anchor)
	local out = {}
	for value in body:gmatch("'([^']+)'") do
		out[#out + 1] = value
	end
	return out
end

describe('verdicts.http', function()
	it('marks the shapes loaders use as suspicious', function()
		assert.are.equal('suspicious', level('https://45.133.1.20/p'))
		assert.are.equal('raw_ip', verdicts.http('https://45.133.1.20/p').code)
		assert.are.equal('suspicious', level('https://[2001:db8::1]/x'))
		assert.are.equal('suspicious', level('https://dlscord.com/api/webhooks/1'))
		assert.are.equal('lookalike', verdicts.http('https://dlscord.com/api/webhooks/1').code)
		assert.are.equal('punycode', verdicts.http('https://xn--dscord-6ve.com/').code)
		assert.are.equal('contains_known', verdicts.http('https://github.com.evil.example/x').code)
		assert.are.equal('random_label', verdicts.http('https://k8f3j2m9x7q1.example/x').code)
		assert.are.equal('user_content', verdicts.http('https://pastebin.com/raw/<redacted>').code)
		assert.are.equal('suspicious', level('not a url'))
	end)

	it('only calls exact read-only version checks common', function()
		local trusted = verdicts.http('https://api.github.com/repos/Overextended/ox_lib/releases/latest')
		assert.are.equal('common', trusted.level)
		assert.is_nil(trusted.weak)
		local other = verdicts.http('https://api.github.com/repos/someone/loader/releases/latest')
		assert.are.equal('common', other.level)
		assert.is_true(other.weak)
		assert.are.equal('check', level('https://api.github.com/repos/overextended'))
		assert.are.equal('check', level('https://api.github.com/repos/overextended/ox_lib/issues'))
		assert.are.equal('check', level('http://api.github.com/repos/someone/loader/releases/latest'))
	end)

	it('asks a human about data-receiving services and unknown hosts', function()
		assert.are.equal('discord_webhook', verdicts.http('https://discord.com/api/webhooks/123/<redacted>').code)
		assert.are.equal('discord_no_path', verdicts.http('https://discord.com/').code)
		assert.are.equal('shared_api', verdicts.http('https://api.telegram.org/bot').code)
		assert.are.equal('plain_http', verdicts.http('http://weather.example/v1').code)
		assert.are.equal('unknown_host', verdicts.http('https://api.weather.example/v1').code)
	end)

	it('reads logged targets, redacted segments included', function()
		local t = verdicts.split_target('https://Discord.com:8443/api/webhooks/1/<redacted>')
		assert.are.equal('discord.com', t.host)
		assert.are.equal(':8443', t.port)
		assert.are.equal('/api/webhooks/1', t.path)
		assert.is_true(t.truncated)
		local cut = verdicts.split_target('https://api.example.com/a/b/c/d/e/<more>')
		assert.are.equal('/a/b/c/d/e', cut.path)
		assert.is_true(cut.truncated)
		assert.is_false(verdicts.split_target('https://api.example.com/a').truncated)
		assert.is_nil(verdicts.split_target('https://user@host/x'))
		assert.is_nil(verdicts.split_target(42))
	end)
end)

describe('verdicts: dynamic code and the loader shape', function()
	it('tells code from files apart from code built in memory', function()
		assert.are.equal('common', verdicts.dynamic(false).level)
		assert.are.equal('suspicious', verdicts.dynamic(true).level)
	end)

	it('raises running any text plus an unvouched destination to suspicious', function()
		local unknown = verdicts.http('https://api.weather.example/v1')
		local stranger = verdicts.http('https://api.github.com/repos/someone/loader/releases/latest')
		local trusted = verdicts.http('https://api.github.com/repos/overextended/ox_lib/releases/latest')
		assert.is_true(verdicts.loader_shape({ unknown }, verdicts.dynamic(true)))
		assert.is_true(verdicts.loader_shape({ stranger }, verdicts.dynamic(true)))
		assert.is_false(verdicts.loader_shape({ trusted }, verdicts.dynamic(true)))
		assert.is_false(verdicts.loader_shape({ unknown }, verdicts.dynamic(false)))
		assert.are.equal('check', verdicts.worst({ unknown }, nil))
		assert.are.equal('common', verdicts.worst({ stranger }, verdicts.dynamic(false)))
	end)
end)

describe('verdicts: same lists as the CLI', function()
	it('knows the same domains as cli/lib/hosts.mjs', function()
		assert.are.same(js_array(read('cli/lib/hosts.mjs'), 'KNOWN_DOMAINS'), verdicts.KNOWN_DOMAINS)
	end)

	it('trusts the same release owners as cli/presets/common-hosts.json', function()
		local owners = {}
		for owner in read('cli/presets/common-hosts.json'):gmatch('"owner"%s*:%s*"([^"]+)"') do
			owners[owner:lower()] = true
		end
		assert.are.same(owners, verdicts.RELEASE_OWNERS)
	end)
end)
