-- Reads hex-encoded URLs on stdin (one per line) and prints how torii's parser reads each one:
--   ok <TAB> scheme <TAB> host <TAB> port <TAB> kind
--   err <TAB> reason
-- Run from the repository root: lua research/url-differential/torii_parse.lua < urls.hex

package.path = './torii/src/?.lua;' .. package.path
local url = require('url')

local function unhex(s)
	return (s:gsub('%x%x', function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

for line in io.lines() do
	local raw = unhex(line)
	local parsed, why = url.parse(raw)
	if parsed then
		io.write('ok\t', parsed.scheme, '\t', parsed.host, '\t', tostring(parsed.port), '\t', parsed.kind, '\n')
	else
		io.write('err\t', tostring(why), '\n')
	end
end
