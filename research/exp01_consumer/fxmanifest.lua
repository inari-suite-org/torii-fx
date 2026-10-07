fx_version 'cerulean'
game 'gta5'
description 'torii experiment 01: consumer of @exp01_provider/init.lua'

-- Deliberately in the "wrong" order: server_script is declared FIRST.
server_script 'server.lua'
shared_script '@exp01_provider/init.lua'
shared_script 'late_shared.lua'
