local url = require('url')

local function parse(raw)
	local parsed, why = url.parse(raw)
	return parsed, why
end

describe('url.parse', function()
	it('normalises host, port and path', function()
		local p = assert(parse('HTTPS://Example.COM./a/../b/./c?token=1#frag'))
		assert.are.equal('https', p.scheme)
		assert.are.equal('example.com', p.host)
		assert.are.equal(443, p.port)
		assert.are.equal('/b/c', p.path)
		assert.are.equal('name', p.kind)
	end)

	it('uses explicit ports and defaults', function()
		assert.are.equal(80, assert(parse('http://example.com')).port)
		assert.are.equal(8080, assert(parse('http://example.com:8080/x')).port)
		assert.are.equal('/', assert(parse('http://example.com')).path)
	end)

	it('decodes only unreserved percent escapes', function()
		assert.are.equal('/A/b', assert(parse('https://x.com/%41/%62')).path)
		assert.are.equal('/a%20b', assert(parse('https://x.com/a%20b')).path)
		assert.are.equal('/b', assert(parse('https://x.com/a/%2e%2e/b')).path)
	end)

	it('rejects ambiguous or malformed urls', function()
		local cases = {
			['https://user@evil.com/'] = 'userinfo_not_allowed',
			['https://good.com\\@evil.com/'] = 'forbidden_character',
			['https://good.com@evil.com/'] = 'userinfo_not_allowed',
			['ftp://example.com/'] = 'scheme_not_allowed',
			['file:///etc/passwd'] = 'scheme_not_allowed',
			['//example.com/'] = 'no_scheme',
			['example.com'] = 'no_scheme',
			['https://exa mple.com/'] = 'forbidden_character',
			['https://example.com/\n'] = 'forbidden_character',
			['https://ex%61mple.com/'] = 'percent_in_host',
			['https://ex\195\164mple.com/'] = 'non_ascii',
			['https://example.com:99999/'] = 'bad_port',
			['https://example.com:0/'] = 'bad_port',
			['https://example.com:abc/'] = 'bad_port',
			['https://example.com:/'] = 'bad_port',
			['https://a..b/'] = 'bad_host',
			['https://-a.com/'] = 'bad_host',
			['https://a_b.com/'] = 'bad_host',
			['https:///path'] = 'empty_host',
			['https://[::1/'] = 'bad_ipv6_literal',
			['https://[zz::1]/'] = 'bad_ipv6_literal',
			['https://[fe80::1%25eth0]/'] = 'percent_in_host',
			['https://example.com/%2fadmin'] = 'encoded_separator',
			['https://example.com/%5cadmin'] = 'encoded_separator',
			['https://example.com/%zz'] = 'bad_percent_escape',
			['https://example.com/../../x'] = 'path_escapes_root',
			['http://4294967296/'] = 'bad_ip_literal',
			['http://1.2.3.4.5/'] = 'bad_ip_literal',
			['http://0x/'] = 'bad_ip_literal',
			['http://09.0.0.1/'] = 'bad_ip_literal',
		}
		for raw, expected in pairs(cases) do
			local parsed, why = parse(raw)
			assert.is_nil(parsed, raw)
			assert.are.equal(expected, why, raw)
		end
		assert.is_nil(parse(nil))
		assert.is_nil(parse(42))
		assert.is_nil(parse(string.rep('a', 3000)))
	end)

	it('canonicalises every spelling of an IPv4 address', function()
		for _, raw in ipairs({
			'http://127.0.0.1/',
			'http://127.1/',
			'http://2130706433/',
			'http://0x7f000001/',
			'http://0x7f.1/',
			'http://0177.0.0.1/',
			'http://127.0.0.1./',
			'http://0177.0.0.01/',
		}) do
			local p = assert(parse(raw), raw)
			assert.are.equal('ipv4', p.kind, raw)
			assert.are.equal('127.0.0.1', p.host, raw)
		end
	end)
end)

describe('url.classify_host', function()
	local function reason(raw)
		return url.classify_host(assert(parse(raw), raw))
	end

	it('refuses loopback, private and special-use IPv4', function()
		assert.are.equal('loopback_address', reason('http://127.0.0.1/'))
		assert.are.equal('loopback_address', reason('http://127.1/'))
		assert.are.equal('loopback_address', reason('http://2130706433/'))
		assert.are.equal('private_address', reason('http://10.1.2.3/'))
		assert.are.equal('private_address', reason('http://172.16.0.1/'))
		assert.are.equal('private_address', reason('http://172.31.255.255/'))
		assert.are.equal('private_address', reason('http://192.168.0.1/'))
		assert.are.equal('link_local_address', reason('http://169.254.169.254/'))
		assert.are.equal('shared_address_space', reason('http://100.64.0.1/'))
		assert.are.equal('unspecified_address', reason('http://0.0.0.0/'))
		assert.are.equal('multicast_or_reserved_address', reason('http://224.0.0.1/'))
		assert.are.equal('multicast_or_reserved_address', reason('http://255.255.255.255/'))
	end)

	it('allows public IPv4 next to the private ranges', function()
		assert.is_nil(reason('https://8.8.8.8/'))
		assert.is_nil(reason('https://172.15.0.1/'))
		assert.is_nil(reason('https://172.32.0.1/'))
		assert.is_nil(reason('https://100.63.0.1/'))
		assert.is_nil(reason('https://192.169.0.1/'))
	end)

	it('refuses private IPv6 and IPv4 hidden inside IPv6', function()
		assert.are.equal('loopback_address', reason('http://[::1]/'))
		assert.are.equal('unspecified_address', reason('http://[::]/'))
		assert.are.equal('private_address', reason('http://[fd00::1]/'))
		assert.are.equal('link_local_address', reason('http://[fe80::1]/'))
		assert.are.equal('loopback_address', reason('http://[::ffff:127.0.0.1]/'))
		assert.are.equal('loopback_address', reason('http://[::ffff:7f00:1]/'))
		assert.are.equal('private_address', reason('http://[::ffff:10.0.0.1]/'))
		assert.are.equal('private_address', reason('http://[64:ff9b::a00:1]/'))
		assert.are.equal('loopback_address', reason('http://[2002:7f00:1::]/'))
		assert.are.equal('multicast_or_reserved_address', reason('http://[ff02::1]/'))
		assert.are.equal('loopback_address', reason('http://[0:0:0:0:0:0:0:1]/'))
	end)

	it('allows public IPv6', function()
		assert.is_nil(reason('https://[2606:4700:4700::1111]/'))
	end)

	it('refuses local names', function()
		assert.are.equal('local_name', reason('http://localhost/'))
		assert.are.equal('local_name', reason('http://LOCALHOST./'))
		assert.are.equal('local_name', reason('http://app.localhost/'))
		assert.are.equal('local_name', reason('http://printer.local/'))
		assert.are.equal('local_name', reason('http://db.internal/'))
		assert.are.equal('local_name', reason('http://anything.users.cfx.re/'))
		assert.are.equal('single_label_host', reason('http://intranet/'))
		assert.is_nil(reason('https://example.com/'))
	end)
end)

describe('url.host_risk', function()
	it('flags user-content hosts and shared APIs', function()
		assert.are.equal('user_content', url.host_risk('pastebin.com'))
		assert.are.equal('user_content', url.host_risk('raw.githubusercontent.com'))
		assert.are.equal('user_content', url.host_risk('someone.github.io'))
		assert.are.equal('shared_api', url.host_risk('discord.com'))
		assert.are.equal('shared_api', url.host_risk('api.telegram.org'))
		assert.is_nil(url.host_risk('api.example.com'))
		assert.is_nil(url.host_risk('notpastebin.com'))
	end)
end)

describe('url.redact_path', function()
	it('hides long opaque segments and keeps three segments at most', function()
		local token = 'abcdefghijklmnopqrstuvwxyz0123456789'
		assert.are.equal('/api/webhooks/<redacted>', url.redact_path('/api/webhooks/' .. token))
		assert.are.equal('/api/webhooks/123', url.redact_path('/api/webhooks/123/' .. token))
		assert.are.equal('/', url.redact_path('/'))
	end)
end)
