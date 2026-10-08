fx_version 'cerulean'
shared_script '@torii/init.lua'
game 'gta5'
lua54 'yes'

name 'torii_compat_load'
description 'Synthetic load for torii compatibility runs on a development server (no players involved)'

-- what this resource legitimately needs
torii_http 'http://127.0.0.1:8099/ok'
torii_dynamic_code 'yes'

shared_script '@ox_lib/init.lua'
server_script '@oxmysql/lib/MySQL.lua'
server_script 'server.lua'

dependencies { 'ox_lib', 'oxmysql', 'qb-core' }
