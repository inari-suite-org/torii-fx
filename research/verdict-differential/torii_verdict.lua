-- Reads logged targets on stdin (one per line) and prints the console's verdict for each: level <TAB> weak
-- Run from the repository root: lua research/verdict-differential/torii_verdict.lua < targets.txt

package.path = './torii/src/?.lua;' .. package.path
local verdicts = require('verdicts')

for line in io.lines() do
	local v = verdicts.http(line)
	io.write(v.level, '\t', v.weak and 'weak' or '-', '\t', v.code, '\n')
end
