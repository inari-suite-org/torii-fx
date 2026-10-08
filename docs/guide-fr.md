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

## 6. Décidez de ce que chaque script a le droit de faire

1. Téléchargez `resources/torii/logs/torii.jsonl` du serveur vers votre ordinateur, par exemple dans `C:\torii-work`.
2. Lancez :

```bash
node cli/torii.mjs approve "C:\torii-work\resources" --from-logs "C:\torii-work\torii.jsonl" --use-presets
```

3. L'outil affiche ce qu'il **propose** d'autoriser, script par script. Rien n'est encore enregistré.

```text
+ weather_sync
    + http              pastebin.com/raw
    + http              api.weather.example/v1
    ~ declaration_hash  - -> 0c3f78047594

! weather_sync
    pastebin.com serves or receives user content: anybody can host a payload there, a path prefix does not make it safe; drop it if you can
```

La ligne `~ declaration_hash` est de la comptabilité interne, vous pouvez l'ignorer. Le bloc qui commence par `!`
liste les avertissements de l'outil : lisez-les tous.

Pour chaque ligne `+ http`, posez-vous ces questions :

| Question | Si oui | Si non |
|---|---|---|
| L'adresse n'est-elle faite que de chiffres (`45.133.1.20`) ? | **Ne pas autoriser.** Les vrais services utilisent des noms. | question suivante |
| Le nom imite-t-il un site connu (`discordd.app`, `githubb.com`, lettres bizarres) ? | **Ne pas autoriser.** | question suivante |
| Est-ce un site où n'importe qui peut publier du texte (`pastebin.com`, `hastebin`, fichiers bruts GitHub) ? | **Ne pas autoriser**, sauf si l'auteur du script explique pourquoi. Les backdoors téléchargent leur code depuis ces sites. | question suivante |
| Est-ce un webhook Discord (`discord.com/api/webhooks/...`) ? | Autorisez-le **seulement s'il est à vous** : dans Discord, *Paramètres du serveur > Intégrations > Webhooks*, le numéro dans l'adresse doit correspondre à l'un de vos webhooks. Une backdoor envoie les secrets de votre serveur sur le webhook du pirate. | question suivante |
| Le site est-il cité dans la documentation du script, ou a-t-il un lien évident avec ce que fait le script (script météo → site météo) ? | Autorisez. | **Demandez à l'auteur** avant d'autoriser. En attendant, laissez-le de côté. |

Pour les lignes `dynamic_code` (le script veut exécuter du code qu'il construit ou télécharge) : les scripts qui
utilisent `ox_lib` en ont besoin, et `--use-presets` s'en occupe pour la bibliothèque elle-même. Un script que vous ne
connaissez pas qui demande `dynamic_code` **et** contacte un site inconnu a exactement la forme d'une backdoor : ne
l'autorisez pas, et supprimez le script.

4. Quand la proposition vous convient, relancez la même commande avec `--write` à la fin. Si vous avez décidé
   d'écarter quelque chose, vous pouvez aussi modifier ensuite `C:\torii-work\resources\torii\policy.lock.json` à la
   main et supprimer la ligne concernée.
5. Envoyez `C:\torii-work\resources\torii\policy.lock.json` dans `resources/torii/` sur le serveur.

## 7. Les scripts en JavaScript et en C#

torii ne peut pas regarder à l'intérieur. En mode enforce, il **refuse de les démarrer**, sauf si vous les déclarez
exemptés. Les plus courants sont `oxmysql`, `pma-voice` et `screenshot-basic`.

Ouvrez `policy.lock.json` et ajoutez leurs noms dans `exempt` :

```json
{
  "version": 1,
  "exempt": ["oxmysql", "pma-voice"],
  "resources": { ... }
}
```

Exempté veut dire « torii ne vérifie pas du tout ce script ». N'exemptez que des scripts de confiance, récupérés à
leur source officielle.

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
