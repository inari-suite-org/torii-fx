# Guide pas à pas

Pour les propriétaires de serveur qui ne sont pas développeurs. Pas besoin de lire du code. Comptez environ
20 minutes de manipulations, puis quelques jours d'attente pendant que torii observe. English version: [guide.md](guide.md).

> [!WARNING]
> torii est **expérimental** : il n'a encore jamais tourné sur un serveur avec de vrais joueurs. En mode **observe**
> (le mode par défaut), il ne bloque rien et ne peut pas casser votre serveur. Restez en observe jusqu'à l'étape 6.

## Ce que fait torii, en trois phrases

Aujourd'hui, chaque script de votre serveur peut contacter n'importe quel site et exécuter n'importe quel code qu'il
télécharge. C'est comme ça que les backdoors cachées dans des scripts « gratuits » ou leakés prennent le contrôle des
serveurs. torii donne à chaque script une liste de ce qu'il a le droit de faire, et signale (mode observe) ou bloque
(mode enforce) tout le reste.

## Ce qu'il vous faut

- Un accès aux fichiers du serveur : FTP, le gestionnaire de fichiers de votre hébergeur, ou la machine elle-même.
- Un accès au `server.cfg` (txAdmin a un **CFG Editor** dans son menu).
- Un ordinateur Windows, macOS ou Linux avec **Node.js 18 ou plus récent** ([nodejs.org](https://nodejs.org), version
  « LTS »). Node sert à lancer l'outil torii **sur votre ordinateur**. Votre serveur n'en a pas besoin.
- torii lui-même : sur la [page GitHub](https://github.com/inari-suite-org/torii-fx), cliquez sur **Code**, puis
  **Download ZIP**, et décompressez-le sur votre ordinateur.

## 1. Faites une sauvegarde

Téléchargez une copie de tout votre dossier `resources` sur votre ordinateur, et mettez-la de côté. En cas de
problème, vous la remettez en place.

Gardez une deuxième copie pour travailler dessus aux étapes suivantes. Dans ce guide, elle s'appelle
`C:\torii-work\resources` (prenez le dossier que vous voulez).

## 2. Ajoutez la ressource torii

1. Dans le téléchargement décompressé, trouvez le dossier `torii` (celui qui contient `fxmanifest.lua` et `init.lua`).
2. Envoyez-le dans le dossier `resources` de votre serveur, à côté de vos autres scripts.
3. Dans `server.cfg`, mettez `ensure torii` en **première** ligne `ensure`, au-dessus de tous les autres scripts :

```cfg
ensure torii
# ... vos autres lignes ensure en dessous
```

## 3. Protégez vos scripts

Chaque script a besoin d'une ligne dans son `fxmanifest.lua` pour que torii tourne à l'intérieur. L'outil l'ajoute
pour vous.

1. Ouvrez un terminal **sur votre ordinateur**, dans le dossier torii décompressé (sous Windows : ouvrez le dossier,
   tapez `cmd` dans la barre d'adresse et appuyez sur Entrée).
2. Lancez, avec le chemin de votre copie de travail :

```bash
node cli/torii.mjs install "C:\torii-work\resources"
```

3. L'outil liste ce qu'il a modifié. Chaque manifest modifié garde une sauvegarde à côté de lui
   (`fxmanifest.lua.torii.bak`).
4. Renvoyez les fichiers `fxmanifest.lua` modifiés sur le serveur (renvoyer toute la copie de travail marche aussi).
   Les fichiers `.torii.bak` peuvent rester sur votre ordinateur.

Voici la ligne, si vous préférez l'ajouter à la main : juste après la ligne `fx_version`,

```lua
fx_version 'cerulean'
shared_script '@torii/init.lua'
```

Les scripts sans code serveur sont ignorés : torii ne protège que le Lua côté serveur.

## 4. Redémarrez et vérifiez

Redémarrez le serveur (txAdmin : **Restart**). Dans la console, cherchez :

```text
[torii] core started in observe mode
[torii] mode=observe  protected=42  unprotected=0  js/c#=3  exempt=0  no-server-code=17
```

| Mot | Signification | Que faire |
|---|---|---|
| `protected` | scripts que torii surveille | rien |
| `unprotected` | scripts avec du code serveur mais sans la ligne torii | refaites l'étape 3 pour eux (leurs noms sont sur la ligne suivante) |
| `js/c#` | scripts écrits en JavaScript ou en C#, que torii ne peut pas inspecter | voir l'étape 7 |
| `no-server-code` | scripts qui tournent seulement chez les joueurs | rien |

Vous pouvez réafficher ce bilan à tout moment en tapant `torii_status` dans la console live de txAdmin.

## 5. Laissez-le observer

Laissez le serveur tourner normalement **au moins trois jours, week-end compris**, pour que chaque script soit utilisé.

Vous verrez des lignes comme celle-ci dans la console :

```text
[torii] WOULD BLOCK  weather_sync  http PerformHttpRequestInternalEx -> https://api.weather.example/v1  (resource_not_in_lockfile)  at weather_sync/server.lua:12
```

Lisez-la comme : *« le script `weather_sync` a contacté `api.weather.example` ; en mode enforce ce serait bloqué,
parce que vous ne l'avez pas encore autorisé. »* Rien n'est bloqué pour l'instant. Tout est aussi écrit dans
`resources/torii/logs/torii.jsonl`.

Pas besoin de surveiller la console. Au démarrage, puis au plus une fois par heure, torii affiche un résumé comme
`3 demande(s) à examiner (dont 1 suspecte(s)). Tapez "torii review".` Tapez ces commandes dans la console live de
txAdmin :

| Commande | Ce qu'elle affiche |
|---|---|
| `torii` | combien de demandes attendent une décision, et si le mode enforce semble sûr |
| `torii review` | la liste numérotée, la plus grave d'abord : ce que chaque script a tenté, pourquoi c'est important, quoi faire |
| `torii explain 2` | la demande 2 en détail : combien de fois, depuis quand, depuis quel fichier et quelle ligne |

Pour les messages en français, ajoutez `set torii_lang "fr"` dans `server.cfg`.

## 6. Décidez de ce que chaque script a le droit de faire

1. Téléchargez `resources/torii/logs/torii.jsonl` du serveur vers votre ordinateur, par exemple dans `C:\torii-work`.
2. Lancez :

```bash
node cli/torii.mjs approve "C:\torii-work\resources" --from-logs "C:\torii-work\torii.jsonl" --use-presets --ask
```

3. L'outil commence par un **bilan** : chaque demande reçoit un verdict et une phrase qui dit quoi faire.

| Verdict | Signification |
|---|---|
| 🟢 common (courant) | habituel pour ce type de script (vérification de version, bibliothèque vérifiée à la source). Pas de question. |
| 🟠 check (à vérifier) | torii ne peut pas trancher : site inconnu, webhook Discord. Lisez le conseil, puis répondez `y` pour autoriser ou appuyez sur Entrée pour refuser. |
| 🔴 suspicious (suspect) | ce que font les backdoors : adresse IP brute, nom qui imite un site connu, site de dépôt de code, code exécuté depuis la mémoire. Refusé sauf si vous tapez `yes` en entier. |

4. Quand torii demande `allow? [y/N]`, suivez le conseil affiché. En bref :
   - un webhook Discord : autorisez-le **seulement s'il est à vous** (Discord, *Paramètres du serveur > Intégrations >
     Webhooks*, le numéro doit correspondre à l'un des vôtres). Une backdoor envoie les secrets de votre serveur sur
     le webhook du pirate ;
   - un site cité dans la documentation du script, ou qui a un lien évident avec ce qu'il fait (script météo, site
     météo) : autorisez ;
   - tout le reste : **demandez d'abord à l'auteur du script**. Entrée le refuse pour l'instant, vous pourrez
     l'autoriser plus tard ;
   - un script que vous ne connaissez pas qui exécute du code depuis la mémoire **et** contacte un site dont torii ne
     peut pas se porter garant a exactement la forme d'une backdoor : refusez, et supprimez le script.
5. torii affiche ce qu'il va écrire et demande une dernière confirmation. Répondez `y`.
6. Envoyez `C:\torii-work\resources\torii\policy.lock.json` dans `resources/torii/` sur le serveur.

## 7. Les scripts en JavaScript et en C#

torii ne peut pas regarder à l'intérieur. En mode enforce, il **refuse de les démarrer**, sauf si vous les déclarez
exemptés. Les plus courants sont `oxmysql`, `pma-voice` et `screenshot-basic`. Pour voir lesquels vous avez :

```bash
node cli/torii.mjs exempt "C:\torii-work\resources"
```

Pour en exempter un (puis renvoyez `policy.lock.json` sur le serveur) :

```bash
node cli/torii.mjs exempt "C:\torii-work\resources" oxmysql --write
```

Exempté veut dire « torii ne vérifie pas du tout ce script ». N'exemptez que des scripts de confiance, récupérés à
leur source officielle. `--remove` retire un nom de la liste.

## 8. Passez en mode enforce

1. Dans `server.cfg`, au-dessus de `ensure torii`, ajoutez :

```cfg
set torii_mode "enforce"
ensure torii
```

2. Redémarrez. Les lignes disent maintenant `BLOCKED` au lieu de `WOULD BLOCK`.
3. Surveillez la console pendant une journée. Si un script de confiance ne marche plus à cause d'une ligne
   `BLOCKED`, remettez le mode sur `observe`, redémarrez, et refaites l'étape 6 avec le nouveau journal.

## Plus tard : quand vous mettez à jour ou ajoutez un script

Après une mise à jour, torii peut afficher `declaration_changed_since_approval` ou `declaration_not_approved` : le
script demande maintenant quelque chose que vous n'avez pas examiné. Refaites les étapes 3 et 6 pour lui. Un script
que vous venez d'ajouter n'a aucune permission tant que vous ne l'avez pas validé : en mode enforce, ses connexions
réseau sont bloquées.

## Retirer torii

```bash
node cli/torii.mjs uninstall "C:\torii-work\resources"
```

Renvoyez les manifests sur le serveur, retirez `ensure torii` (et `set torii_mode`) du `server.cfg`, redémarrez. Ou
remettez la sauvegarde de l'étape 1.

## En cas de problème

| Vous voyez | Ça veut dire | Faites ceci |
|---|---|---|
| `Couldn't start resource X` juste après une ligne torii `BLOCKED ... manifest_gate` | en mode enforce, X a du code serveur mais pas la ligne torii | ajoutez la ligne (étape 3), ou exemptez-le (étape 7) |
| `policy.lock.json is not valid JSON` | le fichier contient une faute de frappe | vérifiez les virgules et les guillemets (un validateur JSON en ligne aide), ou renvoyez la version écrite par l'outil |
| Un script de confiance dit qu'il n'arrive pas à joindre son site | son site n'est pas encore autorisé | repassez en `observe`, puis étape 6 |
| Rien de torii dans la console | `ensure torii` manque ou n'est pas en premier | étape 2 |

Toujours bloqué, ou vous pensez avoir trouvé une backdoor ? Ouvrez une issue sur GitHub (ne collez jamais de secrets,
de tokens ni de mots de passe). Si vous avez trouvé un moyen de **contourner** torii, signalez-le plutôt en privé :
voir [SECURITY.md](../SECURITY.md).
