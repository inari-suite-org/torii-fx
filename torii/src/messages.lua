-- Messages torii prints for the server owner, in English and French (set torii_lang "fr").
-- Only what a human reads: the JSON log keeps stable codes. Placeholders are {name}. Every key must exist in both
-- languages (spec/messages_spec.lua checks it).

local M = {}

M.en = {
	-- verdict labels (FiveM console colours: ^1 red, ^3 yellow, ^2 green, ^7 reset)
	level_common = '^2COMMON^7',
	level_check = '^3CHECK^7',
	level_suspicious = '^1SUSPICIOUS^7',

	-- why / what to do, per verdict code
	why_raw_ip = '{host} is a raw IP address: real services use a name, loaders often do not',
	why_punycode = '{host} uses look-alike letters (punycode), a common way to imitate a known name',
	why_contains_known = '{host} contains "{known}" but belongs to {owner}',
	why_lookalike = '{host} looks like {known} ({distance} character(s) apart)',
	why_long_label = 'the name "{label}" is unusually long',
	why_random_label = 'the name "{label}" looks randomly generated',
	why_user_content = '{host} hosts content anybody can publish, which is where loaders keep their payload',
	why_invalid_target = 'not an address torii can read',
	why_release_trusted = 'version check against the official GitHub account "{owner}"',
	why_release_other = 'version check: reads the latest release of one repository of the GitHub account "{owner}"',
	why_discord_no_path = 'Discord without a webhook address lets the script post anywhere on Discord',
	why_discord_webhook = 'a Discord webhook receives whatever the script sends; a backdoor sends your secrets to its own webhook',
	why_shared_api = '{host} accepts data from anyone with an account',
	why_plain_http = '{host} is reached without encryption (http://)',
	why_unknown_host = 'torii does not know {host}',
	why_dynamic_files = 'runs code read from its own files, as module loaders such as ox_lib do',
	why_dynamic_memory = 'ran code it built in memory or received, not code from its own files: this is how remote loaders work',

	todo_suspicious = 'do not allow; remove the script or ask its author',
	todo_release_other = 'nothing to do, as long as this script cannot run code it downloads',
	todo_discord_no_path = 'allow only your own webhook address (discord.com/api/webhooks/<number>)',
	todo_discord_webhook = 'allow only if it is yours: Discord > Server Settings > Integrations > Webhooks must list this number',
	todo_shared_api = "allow only if the account in the address is yours or the script author's",
	todo_plain_http = 'ask the script author why it does not use https',
	todo_unknown_host = 'ask the script author what it is for before allowing it',
	todo_common = 'nothing to do',
	loader_shape = 'together: runs code it was not shipped with and talks to a destination torii cannot vouch for, the shape of a download-and-run loader. Check this script before allowing anything.',

	-- what a pending request is about
	item_http = '{resource} wants to contact {target}',
	item_dynamic = '{resource} wants to run code ({origin})',
	origin_files = 'from its own files',
	origin_memory = 'built in memory or received',

	-- summary and review
	summary_none = 'No request waiting for a decision.',
	summary_some = '{count} request(s) to review, {suspicious} script(s) look suspicious. Type "torii review".',
	review_header = '{count} request(s) waiting for a decision (observing for {days} day(s)):',
	review_empty = 'Nothing to review: every script stayed within what the lockfile allows.',
	review_footer = 'To allow one, add it with `torii approve` on your computer (see docs/guide.md). "torii explain <number>" shows the details.',
	explain_unknown = 'No request number {n}. Type "torii review" for the list.',
	explain_seen = 'seen {count} time(s), first {first}, last {last}',
	explain_at = 'last call site: {src}',
	why = 'why',
	todo = 'do',

	-- readiness for enforce mode
	ready_enforce = 'Observed for {days} day(s), weekend included, nothing waiting: you can switch to enforce mode (set torii_mode "enforce").',
	not_ready_days = 'Keep observing: {days} of at least {min} day(s), weekend included, before switching to enforce mode.',
	not_ready_weekend = 'Keep observing until a weekend has passed (peak traffic), then review again.',
	not_ready_pending = 'Not ready for enforce mode: {count} request(s) still need a decision.',
	mode_enforce = 'Enforce mode: everything not in the lockfile is blocked.',

	-- help
	help = 'torii commands: "torii" (status), "torii review" (requests waiting for a decision), "torii explain <number>", "torii_status" (coverage).',
}

M.fr = {
	level_common = '^2COURANT^7',
	level_check = '^3À VÉRIFIER^7',
	level_suspicious = '^1SUSPECT^7',

	why_raw_ip = '{host} est une adresse IP brute : les vrais services utilisent un nom, les chargeurs de backdoor souvent pas',
	why_punycode = "{host} utilise des lettres trompeuses (punycode), une façon courante d'imiter un nom connu",
	why_contains_known = '{host} contient « {known} » mais appartient à {owner}',
	why_lookalike = '{host} ressemble à {known} ({distance} caractère(s) de différence)',
	why_long_label = 'le nom « {label} » est anormalement long',
	why_random_label = 'le nom « {label} » semble généré au hasard',
	why_user_content = "{host} héberge du contenu que n'importe qui peut publier : c'est là que les chargeurs rangent leur code",
	why_invalid_target = 'adresse illisible pour torii',
	why_release_trusted = 'vérification de version auprès du compte GitHub officiel « {owner} »',
	why_release_other = "vérification de version : lit la dernière version d'un dépôt du compte GitHub « {owner} »",
	why_discord_no_path = "Discord sans adresse de webhook permet au script de poster n'importe où sur Discord",
	why_discord_webhook = 'un webhook Discord reçoit tout ce que le script envoie ; une backdoor envoie vos secrets sur son propre webhook',
	why_shared_api = "{host} accepte des données de n'importe quel compte",
	why_plain_http = '{host} est contacté sans chiffrement (http://)',
	why_unknown_host = 'torii ne connaît pas {host}',
	why_dynamic_files = "exécute du code lu dans ses propres fichiers, comme le font les chargeurs de modules tels qu'ox_lib",
	why_dynamic_memory = "a exécuté du code construit en mémoire ou reçu, pas du code de ses fichiers : c'est ainsi que fonctionnent les chargeurs à distance",

	todo_suspicious = 'ne pas autoriser ; supprimez le script ou contactez son auteur',
	todo_release_other = 'rien à faire, tant que ce script ne peut pas exécuter de code téléchargé',
	todo_discord_no_path = "n'autorisez que l'adresse de votre propre webhook (discord.com/api/webhooks/<numéro>)",
	todo_discord_webhook = "autorisez seulement s'il est à vous : Discord > Paramètres du serveur > Intégrations > Webhooks doit afficher ce numéro",
	todo_shared_api = "autorisez seulement si le compte dans l'adresse est le vôtre ou celui de l'auteur du script",
	todo_plain_http = "demandez à l'auteur du script pourquoi il n'utilise pas https",
	todo_unknown_host = "demandez à l'auteur du script à quoi il sert avant de l'autoriser",
	todo_common = 'rien à faire',
	loader_shape = "ensemble : exécute du code qui n'était pas livré avec lui et contacte une destination dont torii ne peut pas se porter garant, la forme d'un chargeur de backdoor. Vérifiez ce script avant d'autoriser quoi que ce soit.",

	item_http = '{resource} veut contacter {target}',
	item_dynamic = '{resource} veut exécuter du code ({origin})',
	origin_files = 'de ses propres fichiers',
	origin_memory = 'construit en mémoire ou reçu',

	summary_none = 'Aucune demande en attente de décision.',
	summary_some = '{count} demande(s) à examiner, {suspicious} script(s) suspect(s). Tapez "torii review".',
	review_header = '{count} demande(s) en attente de décision (observation depuis {days} jour(s)) :',
	review_empty = 'Rien à examiner : chaque script est resté dans ce que le lockfile autorise.',
	review_footer = 'Pour en autoriser une, ajoutez-la avec `torii approve` sur votre ordinateur (voir docs/guide-fr.md). "torii explain <numéro>" affiche le détail.',
	explain_unknown = 'Pas de demande numéro {n}. Tapez "torii review" pour la liste.',
	explain_seen = 'vu {count} fois, la première le {first}, la dernière le {last}',
	explain_at = 'dernier appel : {src}',
	why = 'pourquoi',
	todo = 'à faire',

	ready_enforce = 'Observé depuis {days} jour(s), week-end compris, rien en attente : vous pouvez passer en mode enforce (set torii_mode "enforce").',
	not_ready_days = "Continuez d'observer : {days} jour(s) sur au moins {min}, week-end compris, avant de passer en mode enforce.",
	not_ready_weekend = "Continuez d'observer jusqu'après un week-end (pic de fréquentation), puis réexaminez.",
	not_ready_pending = 'Pas encore prêt pour le mode enforce : {count} demande(s) attendent encore une décision.',
	mode_enforce = "Mode enforce : tout ce qui n'est pas dans le lockfile est bloqué.",

	help = 'Commandes torii : "torii" (état), "torii review" (demandes en attente de décision), "torii explain <numéro>", "torii_status" (couverture).',
}

--- Language from a convar value: 'fr' or 'en' (default).
function M.lang(value)
	return (type(value) == 'string' and value:lower():sub(1, 2) == 'fr') and 'fr' or 'en'
end

--- Message `key` in `lang`, with {placeholders} replaced. Falls back to English, then to the key itself.
function M.t(lang, key, vars)
	local text = (M[lang] and M[lang][key]) or M.en[key] or key
	return (
		text:gsub('{(%w+)}', function(name)
			local value = vars and vars[name]
			return value ~= nil and tostring(value) or '{' .. name .. '}'
		end)
	)
end

return M
