# Feu de statut Claude Code — partie logicielle

Un seul script, `traffic-light.ps1`, avec deux modes selon qu'on lui passe un argument :

```
hook Claude Code -> traffic-light.ps1 working -> named pipe -> traffic-light.ps1 (sans argument) -> USB série -> Nano
                      mode client                 local pur     mode pont, résident
```

Pourquoi deux rôles : Claude Code lance un processus neuf à chaque événement,
qui meurt aussitôt. Il ne peut donc pas garder le port série ouvert. Or ouvrir
le port provoque un reset de la carte, d'où un pont résident qui l'ouvre une
seule fois, et un client jetable qui se contente de lui parler.

## Plusieurs instances de Claude Code

Le pont tient un état par instance et affiche la synthèse. Les trois LEDs sont
indépendantes, donc rouge et orange peuvent être allumés en même temps :

| LED | Allumée quand |
|---|---|
| Rouge clignotant | au moins une instance attend ta validation |
| Rouge fixe | au moins une instance attend une entrée |
| Orange | au moins une instance travaille |
| Vert | plus rien ne tourne, plus rien n'attend |

Un `Stop` d'une instance ne peut donc plus éteindre le rouge d'une autre, ce
qui était le vrai risque : rater une demande de confirmation.

L'identification de l'instance se fait par le PID du processus `claude` parent,
retrouvé en remontant la chaîne des processus. C'est plus solide qu'un
identifiant de session, parce qu'un PID permet de vérifier que le processus vit
encore : une fenêtre fermée brutalement, qui n'envoie jamais son `SessionEnd`,
est détectée et oubliée. Si le PID est introuvable, le client se rabat sur le
`session_id` transmis par le hook, avec péremption au bout de 20 minutes de
silence.

## Comportement du vert

Après la fin du dernier travail : vert franc pendant 1 min, puis balayage
blanc doux façon K2000 sur les trois LEDs pendant 4 min, puis extinction.
Réglable en tête de `traffic-light.ps1` :

```powershell
$SolidGreenSec = 60
$IdleAnimMin   = 4
```

Le passage au balayage se fait côté firmware : le pont envoie toujours la
trame `S003` (rouge et orange éteints, vert en veille), et c'est
`traffic_light.ino` qui interprète cette trame précise comme un signal pour
lancer l'animation plutôt que d'allumer simplement le vert en faible. Vitesse
du balayage réglable en tête du `.ino` (`KNIGHT_MS`, en ms par pas ; plus
grand = plus lent). Intensité réglable via `KNIGHT_SCALE`.

Cette séquence ne se déclenche que si une instance a vraiment travaillé —
lancer le pont sans que Claude Code ait rien fait ne fait pas clignoter le
feu tout seul, il reste éteint.

À noter : une fois éteint, le feu ne se distingue plus d'un pont planté. Mettre
`$IdleAnimMin = 0` pour un balayage veille permanent si tu préfères l'inverse.

Le port série est lui aussi rendu automatiquement à ce moment-là (une fois le
`S000` envoyé) : pas besoin de tuer le pont pour reflasher la carte, il suffit
d'attendre la fin du fondu. Une nouvelle activité rouvre le port tout seul
(avec un reset de la carte, comme à chaque ouverture).

## 1. Firmware

Bibliothèque nécessaire : FastLED (gestionnaire de bibliothèques de l'IDE Arduino).

Carte : *Arduino Nano*, processeur *ATmega328P (Old Bootloader)* sur la plupart
des clones. Si le téléversement échoue sur une erreur de synchronisation, c'est
ce réglage qu'il faut changer.

Au démarrage, la carte balaie les trois LEDs de haut en bas : c'est le test de
câblage. Si le balayage part du bas, le ruban est monté à l'envers — inverse
`I_GREEN` et `I_RED` en tête du fichier plutôt que de le démonter.

Protocole série : une trame `S<rouge><orange><vert>` décrit l'état complet,
chaque chiffre valant `0` éteint, `1` allumé, `2` clignotant, `3` veille.
`S201` = rouge clignotant, orange éteint, vert allumé. `X` éteint tout,
`?` renvoie la trame courante.

## 2. Câblage

| Ruban | Nano |
|---|---|
| 5V | 5V |
| GND | GND |
| DIN | D6 |

## 3. Installation du script

Copier `traffic-light.ps1` dans `%USERPROFILE%\.claude\hooks\`.

Test manuel, dans deux fenêtres :

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\traffic-light.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\traffic-light.ps1" permission
```

Lancé à la main, le client ne trouve pas de processus `claude` parent et se
range sous la clé `sid:default` — c'est normal, ça teste quand même la chaîne
complète.

Le pont détecte le port COM tout seul, par identifiant USB du convertisseur
(CH340, CH9102, FTDI ou puce Arduino). Aucun numéro de COM à renseigner, et ça
continue de marcher si tu changes de prise USB.

Lancement automatique à l'ouverture de session :

```
schtasks /Create /TN "Claude Code Traffic Light" /SC ONLOGON /RL LIMITED /F /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"%USERPROFILE%\.claude\hooks\traffic-light.ps1`""
```

(Une seule ligne, syntaxe PowerShell — le `` ` `` avant les guillemets
internes est le caractère d'échappement de PowerShell. Ne pas la couper avec
`^`, c'est de la syntaxe cmd.exe qui échoue sous PowerShell.)

## 4. Hooks

Fusionner `settings-hooks.json` dans `%USERPROFILE%\.claude\settings.json` (si
le fichier a déjà une section `hooks`, ajouter les entrées dedans plutôt que de
remplacer le fichier). Aucun chemin à adapter à la main : chaque hook utilise
la forme "exec" (`command` + tableau `args`), qui lance `powershell.exe`
directement sans passer par un shell intermédiaire. C'est donc PowerShell
lui-même qui résout `$env:USERPROFILE` au moment de l'exécution — le fichier
marche tel quel une fois copié dans n'importe quel `%USERPROFILE%\.claude\`.

(Ancienne méthode abandonnée : la forme "shell", un simple `command` texte
sans `args`, passe par Git Bash sous Windows quand il est installé — qui ne
comprend pas la syntaxe PowerShell `$env:USERPROFILE` ni `%USERPROFILE%` du
cmd. C'est ce qui forçait à écrire le chemin en dur avant.)

| Événement | État envoyé |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` | working |
| `PreToolUse` | working |
| `PostToolUse` | working |
| `PermissionRequest` | permission |
| `Notification` | waiting |
| `Stop` | idle |
| `SessionEnd` | end |

`PostToolUse` compte : c'est lui qui repasse à l'orange une fois que tu as
accordé une permission, sinon le rouge resterait allumé jusqu'au `Stop`.

Vérifier avec `claude --debug` que les hooks se déclenchent, ou `/hooks` pour
lister la configuration chargée.

## Dépannage

**La carte redémarre à chaque changement de couleur.** Le pont ne tourne pas et
le client n'a personne à qui parler — ou un autre logiciel occupe le port.
Vérifie que `traffic-light.ps1` sans argument est bien lancé. La tâche
planifiée est en `ONLOGON` : elle ne démarre pas toute seule après création,
lance-la à la main une première fois.

**« Accès refusé » sur COM3 en lançant `traffic-light.ps1` sans argument.** Un
autre programme tient déjà le port — le pont ne peut avoir qu'un seul
titulaire à la fois. Deux causes courantes :

- Un pont précédent tourne encore en arrière-plan (fenêtre cachée, lancé par
  la tâche planifiée ou par un test précédent). Cherche-le avec
  `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object
  { $_.CommandLine -match 'traffic-light\.ps1' }` et arrête-le
  (`Stop-Process -Id … -Force`) avant de relancer.
- L'IDE Arduino a le port ouvert — son Moniteur Série le verrouille dès qu'il
  est ouvert, et l'IDE lui-même peut le garder brièvement dès qu'une carte est
  sélectionnée. Ferme le Moniteur Série (ou l'IDE) avant de lancer le pont.

Si le pont échoue à l'ouverture du port, il essaie quand même de créer le
named pipe local, ce qui peut faire remonter une seconde erreur sans rapport
(`BeginWaitForConnection`) — ignore-la, c'est une conséquence de la première.

**Le rouge reste allumé alors que tout est fini.** Une instance a été tuée en
plein travail. Le pont l'oublie quand son processus disparaît, mais si la clé
utilisée est un `session_id` (PID introuvable), il faut attendre les 20 minutes
de péremption. La console du pont journalise chaque instance disparue.

**Rien ne s'allume, mais l'autotest au démarrage fonctionne.** Le firmware va
bien, c'est la chaîne logicielle. Appelle `traffic-light.ps1 permission` à la
main et regarde la console du pont : il journalise chaque trame émise et le
nombre d'instances suivies.

**L'autotest ne fonctionne pas non plus.** Câblage ou alimentation. Vérifie le
sens du ruban : la flèche imprimée part de DIN.

**Le pont ne trouve pas la carte.** Ouvre le gestionnaire de périphériques. Si
la carte apparaît en périphérique inconnu, il manque le pilote CH340. Si elle
apparaît avec un identifiant USB absent de la liste, ajoute-le à `$VendorIds`
en tête du script.

**PowerShell refuse d'exécuter les scripts.** Les commandes ci-dessus passent
déjà `-ExecutionPolicy Bypass`. Si besoin, `Set-ExecutionPolicy -Scope
CurrentUser RemoteSigned` ne demande pas de droits administrateur.

**Bonus fiabilité (facultatif).** Sur ce montage (3 LEDs, 5 cm de fil, dans un
boîtier), rien de ce qui suit n'est nécessaire — mais si un jour le câblage
s'allonge ou que le ruban grandit, une résistance de 330 Ω en série sur DIN et
un condensateur de 1000 µF entre 5V et GND côté ruban protègent contre les
glitches de la première LED et l'appel de courant à la mise sous tension.
