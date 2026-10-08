-- Example manifest of a resource protected by torii.
-- Copy what you need; nothing here is required except the include line.

fx_version 'cerulean'
-- 1. The include. `torii install` adds it for you. It must be the FIRST script line of the manifest.
shared_script '@torii/init.lua'
game 'gta5'
lua54 'yes'

name 'weather_sync'
author 'Example Studio'
version '1.0.0'
repository 'https://example.com/weather_sync'

-- 2. What this resource ASKS for. These lines grant nothing: the server admin approves them into
--    torii/policy.lock.json with `torii approve`.

-- HTTPS to one API, any path under it
torii_http 'api.weather.example'

-- HTTPS to one Discord webhook only (a path prefix: other webhooks on discord.com stay blocked)
torii_http 'discord.com/api/webhooks/1234567890'

-- Plain HTTP or a non-default port must be written out
-- torii_http 'http://legacy.weather.example:8080'

-- Only if the resource runs text as Lua with load() (many libraries do; most scripts do not)
-- torii_dynamic_code 'yes'

-- Only if the resource must follow HTTP redirects (enforce mode turns them off otherwise)
-- torii_follow_redirects 'yes'

shared_script 'config.lua'
server_script 'server.lua'
client_script 'client.lua'
