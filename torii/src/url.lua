-- Strict URL parser used by the HTTP policy.
--
-- Goal: refuse anything ambiguous instead of guessing. The HTTP client inside FXServer is libcurl, and
-- any difference between how we read a URL and how curl reads it is a possible policy bypass, so this
-- parser rejects userinfo, backslashes, whitespace, non-ASCII, percent-encoded hosts, odd IP spellings, etc.
-- Pure Lua, no FiveM globals. Standard functions are captured in locals (see sha256.lua for why).

local M = {}

local find, sub, lower, upper, match, gsub, format, char =
	string.find, string.sub, string.lower, string.upper, string.match, string.gsub, string.format, string.char
local tonumber, type, ipairs = tonumber, type, ipairs
local concat, insert, remove = table.concat, table.insert, table.remove

local MAX_URL_LENGTH = 2048

--- Splits `str` on the single character `sep`, keeping empty fields.
local function split(str, sep)
	local out, start = {}, 1
	while true do
		local at = find(str, sep, start, true)
		if not at then
			out[#out + 1] = sub(str, start)
			return out
		end
		out[#out + 1] = sub(str, start, at - 1)
		start = at + 1
	end
end

local function ends_with(str, suffix)
	return #str >= #suffix and sub(str, -#suffix) == suffix
end

-- IPv4 -----------------------------------------------------------------------------------------------

local function parse_ip_number(s)
	if match(s, '^0[xX]%x+$') then
		return tonumber(s)
	elseif match(s, '^0%d+$') then
		if find(s, '[89]') then
			return nil
		end
		return tonumber(s, 8)
	elseif match(s, '^%d+$') then
		return tonumber(s, 10)
	end
	return nil
end

--- inet_aton-style parser (accepts 1 to 4 parts, decimal, octal, hex). Returns { b1, b2, b3, b4 } or nil.
local function parse_ipv4_loose(host)
	local parts = split(host, '.')
	if #parts < 1 or #parts > 4 then
		return nil
	end
	local nums = {}
	for i, p in ipairs(parts) do
		local n = parse_ip_number(p)
		if not n then
			return nil
		end
		if i < #parts and n > 255 then
			return nil
		end
		nums[i] = n
	end
	local last_limit = 256 ^ (5 - #parts)
	if nums[#parts] >= last_limit then
		return nil
	end
	local value = 0
	for i = 1, #parts - 1 do
		value = value | (nums[i] << (8 * (4 - i)))
	end
	value = value | nums[#parts]
	return { (value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255 }
end

--- Strict dotted quad (used inside IPv6 literals).
local function parse_ipv4_strict(s)
	local a, b, c, d = match(s, '^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	if not a then
		return nil
	end
	local out = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
	for _, n in ipairs(out) do
		if n > 255 then
			return nil
		end
	end
	return out
end

-- IPv6 -----------------------------------------------------------------------------------------------

local function parse_groups(str, allow_v4)
	if str == '' then
		return {}
	end
	local out = {}
	local parts = split(str, ':')
	for i, p in ipairs(parts) do
		if p == '' then
			return nil
		end
		if find(p, '.', 1, true) then
			if not allow_v4 or i ~= #parts then
				return nil
			end
			local b = parse_ipv4_strict(p)
			if not b then
				return nil
			end
			out[#out + 1] = b[1] * 256 + b[2]
			out[#out + 1] = b[3] * 256 + b[4]
		else
			if #p > 4 or not match(p, '^%x+$') then
				return nil
			end
			out[#out + 1] = tonumber(p, 16)
		end
	end
	return out
end

--- Returns a table of 8 numbers (16-bit groups) or nil. Zone identifiers ("%eth0") are rejected.
local function parse_ipv6(s)
	if find(s, '[^%x:%.]') then
		return nil
	end
	local dc = find(s, '::', 1, true)
	local head, tail
	if dc then
		if find(s, '::', dc + 1, true) then
			return nil
		end
		head = parse_groups(sub(s, 1, dc - 1), false)
		tail = parse_groups(sub(s, dc + 2), true)
		if not head or not tail or #head + #tail > 7 then
			return nil
		end
	else
		head = parse_groups(s, true)
		tail = {}
		if not head or #head ~= 8 then
			return nil
		end
	end
	local out = {}
	for _, g in ipairs(head) do
		out[#out + 1] = g
	end
	for _ = 1, 8 - #head - #tail do
		out[#out + 1] = 0
	end
	for _, g in ipairs(tail) do
		out[#out + 1] = g
	end
	return out
end

-- Address classification -----------------------------------------------------------------------------

--- Returns a reason string when the IPv4 address is not a public unicast address.
local function classify_v4(b)
	local a, b2 = b[1], b[2]
	if a == 0 then
		return 'unspecified_address'
	elseif a == 10 then
		return 'private_address'
	elseif a == 127 then
		return 'loopback_address'
	elseif a == 100 and b2 >= 64 and b2 <= 127 then
		return 'shared_address_space'
	elseif a == 169 and b2 == 254 then
		return 'link_local_address'
	elseif a == 172 and b2 >= 16 and b2 <= 31 then
		return 'private_address'
	elseif a == 192 and b2 == 168 then
		return 'private_address'
	elseif a == 192 and b2 == 0 and b[3] == 0 then
		return 'reserved_address'
	elseif a == 198 and (b2 == 18 or b2 == 19) then
		return 'reserved_address'
	elseif a >= 224 then
		return 'multicast_or_reserved_address'
	end
	return nil
end

local function classify_v6(g)
	local zero_to_5 = g[1] == 0 and g[2] == 0 and g[3] == 0 and g[4] == 0 and g[5] == 0
	if zero_to_5 and g[6] == 0 and g[7] == 0 and g[8] == 0 then
		return 'unspecified_address'
	end
	if zero_to_5 and g[6] == 0 and g[7] == 0 and g[8] == 1 then
		return 'loopback_address'
	end
	-- IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d): judge the embedded IPv4.
	if zero_to_5 and (g[6] == 0xffff or g[6] == 0) then
		return classify_v4({ g[7] >> 8, g[7] & 255, g[8] >> 8, g[8] & 255 }) or 'ipv4_embedded_address'
	end
	-- NAT64 (64:ff9b::/96)
	if g[1] == 0x64 and g[2] == 0xff9b and g[3] == 0 and g[4] == 0 and g[5] == 0 and g[6] == 0 then
		return classify_v4({ g[7] >> 8, g[7] & 255, g[8] >> 8, g[8] & 255 }) or 'ipv4_embedded_address'
	end
	-- 6to4 (2002::/16)
	if g[1] == 0x2002 then
		return classify_v4({ g[2] >> 8, g[2] & 255, g[3] >> 8, g[3] & 255 }) or 'ipv4_embedded_address'
	end
	if (g[1] & 0xfe00) == 0xfc00 then
		return 'private_address'
	end
	if (g[1] & 0xffc0) == 0xfe80 then
		return 'link_local_address'
	end
	if (g[1] & 0xff00) == 0xff00 then
		return 'multicast_or_reserved_address'
	end
	if g[1] == 0x2001 and (g[2] == 0x0db8 or g[2] == 0) then
		return 'reserved_address'
	end
	return nil
end

local LOCAL_SUFFIXES = {
	'.localhost',
	'.local',
	'.internal',
	'.lan',
	'.home.arpa',
	'.intranet',
	'.corp',
	'.home',
	'.localdomain',
	-- FXServer rewrites *.users.cfx.re to http://localhost:<port> before sending (HttpScriptFunctions.cpp).
	'.users.cfx.re',
}

--- Returns a reason string when the parsed host must be refused regardless of the allow-list.
---@param parsed table result of M.parse
---@return string|nil
function M.classify_host(parsed)
	if parsed.kind == 'ipv4' then
		return classify_v4(parsed.ip)
	elseif parsed.kind == 'ipv6' then
		return classify_v6(parsed.ip)
	end
	local host = parsed.host
	if host == 'localhost' then
		return 'local_name'
	end
	if not find(host, '.', 1, true) then
		return 'single_label_host'
	end
	for _, suffix in ipairs(LOCAL_SUFFIXES) do
		if ends_with(host, suffix) then
			return 'local_name'
		end
	end
	return nil
end

-- Hosts that are a poor allow-list entry on their own: anybody can host or receive data there.
local USER_CONTENT_SUFFIXES = {
	'pastebin.com',
	'githubusercontent.com',
	'github.io',
	'gitlab.io',
	'hastebin.com',
	'paste.ee',
	'ghostbin.com',
	'transfer.sh',
	'ngrok.io',
	'ngrok-free.app',
	'trycloudflare.com',
	'workers.dev',
	'pages.dev',
	'herokuapp.com',
	'vercel.app',
	'netlify.app',
	'glitch.me',
	'repl.co',
	'replit.dev',
	'firebaseapp.com',
	'web.app',
	'onrender.com',
	'fly.dev',
	'000webhostapp.com',
	'bit.ly',
	'tinyurl.com',
	'is.gd',
	'cdn.discordapp.com',
	'media.discordapp.net',
	'dropboxusercontent.com',
	'drive.google.com',
	'docs.google.com',
	'sites.google.com',
	'blogspot.com',
	'wordpress.com',
}

-- APIs that can receive data from anyone who owns an account: only safe with a path prefix.
local SHARED_API_HOSTS = {
	['discord.com'] = true,
	['ptb.discord.com'] = true,
	['canary.discord.com'] = true,
	['discordapp.com'] = true,
	['api.telegram.org'] = true,
	['hooks.slack.com'] = true,
	['api.github.com'] = true,
	['api.pastes.dev'] = true,
}

--- Returns 'user_content', 'shared_api' or nil.
---@param host string normalised host name
function M.host_risk(host)
	if SHARED_API_HOSTS[host] then
		return 'shared_api'
	end
	for _, suffix in ipairs(USER_CONTENT_SUFFIXES) do
		if host == suffix or ends_with(host, '.' .. suffix) then
			return 'user_content'
		end
	end
	return nil
end

-- Paths ----------------------------------------------------------------------------------------------

local function is_unreserved(c)
	return match(c, '^[%w%-%._~]$') ~= nil
end

--- Normalises a path: decodes unreserved percent-escapes, upper-cases the rest, resolves dot segments.
--- Returns the normalised path ("/a/b", never with a trailing slash except "/") or nil, reason.
function M.normalize_path(path)
	if path == '' then
		return '/'
	end
	local bad
	local decoded = gsub(path, '%%(.?.?)', function(hex)
		if not match(hex, '^%x%x$') then
			bad = 'bad_percent_escape'
			return ''
		end
		local c = char(tonumber(hex, 16))
		if c == '/' or c == '\\' or c == '\0' then
			bad = 'encoded_separator'
			return ''
		end
		if is_unreserved(c) then
			return c
		end
		return '%' .. upper(hex)
	end)
	if bad then
		return nil, bad
	end
	local out = {}
	for _, seg in ipairs(split(sub(decoded, 2), '/')) do
		if seg == '..' then
			if #out == 0 then
				return nil, 'path_escapes_root'
			end
			remove(out)
		elseif seg ~= '.' and seg ~= '' then
			insert(out, seg)
		end
	end
	return '/' .. concat(out, '/')
end

--- Replaces anything that looks like a secret (long opaque segments) and keeps at most 3 segments.
--- Used for log output: webhook tokens and API keys often live in the path.
function M.redact_path(path)
	local out = {}
	for seg in string.gmatch(path, '[^/]+') do
		if #out >= 3 then
			break
		end
		if #seg > 20 and match(seg, '^[%w%-_%.~%%]+$') then
			seg = '<redacted>'
		end
		out[#out + 1] = seg
	end
	return '/' .. concat(out, '/')
end

-- Main entry point -----------------------------------------------------------------------------------

---@class ToriiParsedUrl
---@field scheme string 'http'|'https'
---@field host string normalised host (lower-case, no trailing dot, dotted-quad for IPv4, compressed-free for IPv6)
---@field kind string 'name'|'ipv4'|'ipv6'
---@field ip table|nil bytes (IPv4) or groups (IPv6)
---@field port integer
---@field path string normalised path without query or fragment

--- Parses an absolute http(s) URL. Returns the parsed table, or nil and a reason string.
---@param raw any
---@return ToriiParsedUrl|nil, string|nil
function M.parse(raw)
	if type(raw) ~= 'string' then
		return nil, 'not_a_string'
	end
	if #raw == 0 or #raw > MAX_URL_LENGTH then
		return nil, 'bad_length'
	end
	if find(raw, '[%c%s\\]') then
		return nil, 'forbidden_character'
	end
	if find(raw, '[\128-\255]') then
		return nil, 'non_ascii'
	end

	local scheme, rest = match(raw, '^(%a[%w+.-]*)://(.*)$')
	if not scheme then
		return nil, 'no_scheme'
	end
	scheme = lower(scheme)
	if scheme ~= 'http' and scheme ~= 'https' then
		return nil, 'scheme_not_allowed'
	end

	local authority, tail = match(rest, '^([^/?#]*)(.*)$')
	if authority == '' then
		return nil, 'empty_host'
	end
	if find(authority, '@', 1, true) then
		return nil, 'userinfo_not_allowed'
	end
	if find(authority, '%', 1, true) then
		return nil, 'percent_in_host'
	end

	local host, port_str, kind, ip
	if sub(authority, 1, 1) == '[' then
		local inner, after = match(authority, '^%[([^%]]+)%](.*)$')
		if not inner then
			return nil, 'bad_ipv6_literal'
		end
		ip = parse_ipv6(inner)
		if not ip then
			return nil, 'bad_ipv6_literal'
		end
		if after ~= '' then
			port_str = match(after, '^:(%d+)$')
			if not port_str then
				return nil, 'bad_port'
			end
		end
		kind = 'ipv6'
		host = lower(inner)
	else
		local colons = 0
		for _ in string.gmatch(authority, ':') do
			colons = colons + 1
		end
		if colons > 1 then
			return nil, 'bad_host'
		end
		if colons == 1 then
			host, port_str = match(authority, '^([^:]*):(.*)$')
			if not match(port_str, '^%d+$') then
				return nil, 'bad_port'
			end
		else
			host = authority
		end
		host = lower(host)
		if sub(host, -1) == '.' then
			host = sub(host, 1, -2)
		end
		if host == '' or find(host, '..', 1, true) or sub(host, 1, 1) == '.' then
			return nil, 'bad_host'
		end

		local last_label = match(host, '([^.]*)$')
		if match(last_label, '^%d+$') or match(last_label, '^0[xX]%x*$') then
			ip = parse_ipv4_loose(host)
			if not ip then
				return nil, 'bad_ip_literal'
			end
			kind = 'ipv4'
			host = format('%d.%d.%d.%d', ip[1], ip[2], ip[3], ip[4])
		else
			if #host > 253 then
				return nil, 'bad_host'
			end
			for _, label in ipairs(split(host, '.')) do
				if
					#label < 1
					or #label > 63
					or not match(label, '^[a-z0-9]$') and not match(label, '^[a-z0-9][a-z0-9-]*[a-z0-9]$')
				then
					return nil, 'bad_host'
				end
			end
			kind = 'name'
		end
	end

	local port
	if port_str then
		port = tonumber(port_str, 10)
		if not port or port < 1 or port > 65535 then
			return nil, 'bad_port'
		end
	else
		port = scheme == 'https' and 443 or 80
	end

	local path_raw = match(tail, '^([^?#]*)') or ''
	if path_raw ~= '' and sub(path_raw, 1, 1) ~= '/' then
		return nil, 'bad_path'
	end
	local path, why = M.normalize_path(path_raw)
	if not path then
		return nil, why
	end

	return { scheme = scheme, host = host, kind = kind, ip = ip, port = port, path = path }
end

return M
