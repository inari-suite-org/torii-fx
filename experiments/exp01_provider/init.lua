-- First line mirrors the future torii/init.lua (server-only guard).
if not IsDuplicityVersion() then return end

EXP01_ORDER = EXP01_ORDER or {}
EXP01_ORDER[#EXP01_ORDER + 1] = 'provider-init'
print(('[exp01] provider init.lua runs inside resource "%s" (provider state: %s)'):format(
	GetCurrentResourceName(), GetResourceState('exp01_provider')))
