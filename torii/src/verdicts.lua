-- Plain-language verdicts for what a resource tried to do without a grant: common, check, suspicious.
-- Same rules as cli/lib/verdicts.mjs (spec/verdicts_spec.lua checks the shared lists). A verdict is advice for the
-- admin; it never grants or blocks anything. It returns codes, and messages.lua turns them into sentences.

local req = type((...)) == 'function' and (...) or require
local url = req('url')

local M = {}

local byte, find, lower, match, sub, gmatch =
	string.byte, string.find, string.lower, string.match, string.sub, string.gmatch

M.LEVELS = { common = 1, check = 2, suspicious = 3 }

--- Domains people expect in FiveM resources, used to spot look-alikes (same list as cli/lib/hosts.mjs).
M.KNOWN_DOMAINS = {
	'github.com',
	'githubusercontent.com',
	'discord.com',
	'discordapp.com',
	'discord.gg',
	'cfx.re',
	'fivem.net',
	'tebex.io',
	'google.com',
	'googleapis.com',
	'cloudflare.com',
	'pastebin.com',
	'youtube.com',
	'twitch.tv',
	'steamcommunity.com',
	'steampowered.com',
	'microsoft.com',
	'amazonaws.com',
	'paypal.com',
	'imgur.com',
}

--- GitHub accounts whose release checks are common (same list as cli/presets/common-hosts.json).
M.RELEASE_OWNERS = { overextended = true, ['qbcore-framework'] = true, ['esx-framework'] = true }

local DISCORD =
	{ ['discord.com'] = true, ['ptb.discord.com'] = true, ['canary.discord.com'] = true, ['discordapp.com'] = true }

--- Optimal string alignment distance (Damerau-Levenshtein with adjacent transpositions).
function M.edit_distance(a, b)
	local d = {}
	for i = 0, #a do
		d[i] = { [0] = i }
	end
	for j = 0, #b do
		d[0][j] = j
	end
	for i = 1, #a do
		for j = 1, #b do
			local cost = byte(a, i) == byte(b, j) and 0 or 1
			local best = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
			if i > 1 and j > 1 and byte(a, i) == byte(b, j - 1) and byte(a, i - 1) == byte(b, j) then
				best = math.min(best, d[i - 2][j - 2] + 1)
			end
			d[i][j] = best
		end
	end
	return d[#a][#b]
end

--- Shannon entropy in bits per character.
function M.entropy(text)
	if #text == 0 then
		return 0
	end
	local counts = {}
	for i = 1, #text do
		local c = sub(text, i, i)
		counts[c] = (counts[c] or 0) + 1
	end
	local h = 0
	for _, n in pairs(counts) do
		local p = n / #text
		h = h - p * math.log(p, 2)
	end
	return h
end

local function ends_with(text, suffix)
	return suffix == '' or sub(text, -#suffix) == suffix
end

--- First signal that a host name looks wrong, as (code, params), or nil.
function M.host_signal(host, kind)
	if kind == 'ipv4' or kind == 'ipv6' or match(host, '^%d+%.%d+%.%d+%.%d+$') then
		return 'raw_ip', { host = host }
	end
	local labels = {}
	for label in gmatch(host, '[^.]+') do
		labels[#labels + 1] = label
	end
	local registrable = #labels >= 2 and (labels[#labels - 1] .. '.' .. labels[#labels]) or host
	for _, label in ipairs(labels) do
		if sub(label, 1, 4) == 'xn--' then
			return 'punycode', { host = host }
		end
	end
	local known = false
	for _, domain in ipairs(M.KNOWN_DOMAINS) do
		if host == domain or ends_with(host, '.' .. domain) then
			known = true
			break
		end
	end
	if not known then
		for _, domain in ipairs(M.KNOWN_DOMAINS) do
			if find(host, domain .. '.', 1, true) then
				return 'contains_known', { host = host, known = domain, owner = registrable }
			end
			local distance = M.edit_distance(registrable, domain)
			if distance > 0 and distance <= 2 and #domain >= 6 then
				return 'lookalike', { host = registrable, known = domain, distance = distance }
			end
		end
	end
	for i = 1, #labels - 1 do
		local label = labels[i]
		local _, digits = label:gsub('%d', '')
		if #label >= 30 then
			return 'long_label', { label = sub(label, 1, 40) }
		elseif (#label >= 12 and M.entropy(label) >= 3.6) or (#label >= 8 and digits / #label >= 0.4) then
			return 'random_label', { label = label }
		end
	end
	return nil
end

--- Splits a logged target ("https://host:port/path", path possibly redacted) into its parts. Returns nil when the
--- target is not a URL torii would log.
function M.split_target(target)
	if type(target) ~= 'string' then
		return nil
	end
	local scheme, host, port, path = match(target, '^(https?)://([%w%.%-]+)(:?%d*)(/?[!-~]*)$')
	local kind = 'name'
	if not scheme then
		scheme, host, port, path = match(target, '^(https?)://%[([%x:%.]+)%](:?%d*)(/?[!-~]*)$')
		kind = 'ipv6'
		if not scheme then
			return nil
		end
	end
	host = lower(host)
	if kind == 'name' and match(host, '^%d+%.%d+%.%d+%.%d+$') then
		kind = 'ipv4'
	end
	local cut = find(path, '/<redacted>', 1, true)
	if cut then
		path = sub(path, 1, cut - 1)
	end
	if path ~= '' and sub(path, 1, 1) ~= '/' then
		return nil -- user info, or anything else between the host and the path
	end
	if path == '' then
		path = '/'
	end
	return { scheme = scheme, host = host, port = port, path = path, kind = kind }
end

--- Verdict for an HTTP destination: { level = 'common'|'check'|'suspicious', code = string, params = table,
--- weak = boolean|nil }. `weak`: common on its own, but no help for a resource that also runs any text.
function M.http(target)
	local t = M.split_target(target)
	if not t then
		return { level = 'suspicious', code = 'invalid_target', params = {} }
	end
	local code, params = M.host_signal(t.host, t.kind)
	if code then
		return { level = 'suspicious', code = code, params = params }
	end
	local risk = url.host_risk(t.host)
	if risk == 'user_content' then
		return { level = 'suspicious', code = 'user_content', params = { host = t.host } }
	end
	if t.host == 'api.github.com' and t.scheme == 'https' then
		local owner = match(t.path, '^/repos/([%w%-]+)/[%w%._%-]+/releases/latest$')
		if owner then
			if M.RELEASE_OWNERS[lower(owner)] then
				return { level = 'common', code = 'release_trusted', params = { owner = owner } }
			end
			return { level = 'common', code = 'release_other', params = { owner = owner }, weak = true }
		end
	end
	if DISCORD[t.host] then
		if sub(t.path, 1, 14) ~= '/api/webhooks/' then
			return { level = 'check', code = 'discord_no_path', params = {} }
		end
		return { level = 'check', code = 'discord_webhook', params = {} }
	end
	if risk == 'shared_api' then
		return { level = 'check', code = 'shared_api', params = { host = t.host } }
	end
	if t.scheme == 'http' then
		return { level = 'check', code = 'plain_http', params = { host = t.host } }
	end
	return { level = 'check', code = 'unknown_host', params = { host = t.host } }
end

--- Verdict for dynamic code. `from_memory`: some loaded text did not come from the resource's files.
function M.dynamic(from_memory)
	if from_memory then
		return { level = 'suspicious', code = 'dynamic_memory', params = {} }
	end
	return { level = 'common', code = 'dynamic_files', params = {} }
end

--- Running text that did not come from files, plus a destination torii cannot vouch for: a download-and-run loader.
function M.loader_shape(http_verdicts, dynamic_verdict)
	if not dynamic_verdict or dynamic_verdict.level == 'common' then
		return false
	end
	for _, v in ipairs(http_verdicts) do
		if v.level ~= 'common' or v.weak then
			return true
		end
	end
	return false
end

--- Worst level among verdicts (with the loader shape counted as suspicious).
function M.worst(http_verdicts, dynamic_verdict)
	local worst = 'common'
	local function consider(level)
		if M.LEVELS[level] > M.LEVELS[worst] then
			worst = level
		end
	end
	for _, v in ipairs(http_verdicts) do
		consider(v.level)
	end
	if dynamic_verdict then
		consider(dynamic_verdict.level)
	end
	if M.loader_shape(http_verdicts, dynamic_verdict) then
		worst = 'suspicious'
	end
	return worst
end

return M
