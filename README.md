# NVDA Remote pour macOS

Client natif macOS pour la fonction **Remote Access** de NVDA : piloter un PC Windows
sous NVDA depuis un Mac, avec la parole, les sons et (à terme) le braille.

Le Mac joue le rôle de **contrôleur** (« leader », `master` dans le protocole).
Le mode inverse, un PC qui piloterait le Mac, est hors périmètre : aucune API publique
ne permet de capter la parole de VoiceOver.

## Où on en est

L'application **NVDA Remote** pilote le PC depuis le Mac : elle prononce la parole
de NVDA avec ses bips, et envoie le clavier au PC. Validé le 27 septembre 2026 avec
un vrai PC sous NVDA. Pas encore de braille, ni de sons, ni de presse-papiers.

Les deux risques structurants du projet sont levés :

| Risque | État | Détail |
|---|---|---|
| La parole système tient-elle le rythme de NVDA ? | **Levé** | [docs/mesures-parole.md](docs/mesures-parole.md) |
| Peut-on capturer tout le clavier, VoiceOver compris ? | **Levé** | [docs/mesures-clavier.md](docs/mesures-clavier.md) |
| Le braille est-il faisable ? | Ouvert | Dernier point dur, voir l'étude |

En trois lignes : `AVSpeechSynthesizer` monte à 643 mots par minute et coupe la
parole en 40 millisecondes ; un `CGEventTap` posé au niveau HID capture tout, y
compris les commandes VoiceOver ; et Verrouillage majuscules devient utilisable
en la remappant vers F18 avec `hidutil`.

## L'application

Ouvrir `NVDARemote.xcodeproj` dans Xcode, schéma **NVDA Remote**, ou compiler en
ligne de commande :

```bash
xcodebuild -project NVDARemote.xcodeproj -scheme "NVDA Remote" -derivedDataPath build/DerivedData build
```

Signature : `com.math65.nvdaremote`, équipe `633EG76YX5`, runtime renforcé, sans bac
à sable, qui interdirait la capture du clavier. L'identité de signature est stable,
donc les autorisations clavier survivent aux recompilations.

Sur le PC, dans NVDA, Remote Access, choisir « Permettre à cette machine d'être
contrôlée ». Sur le Mac, saisir le serveur (vide pour `nvdaremote.com`) et la clé, ou
coller dans le champ Clé le lien obtenu par « Copier le lien ».

### Clavier

Il faut autoriser l'application dans Réglages Système, Confidentialité et sécurité,
à la fois en Accessibilité et en Surveillance de l'entrée.

| Réglage | Par défaut | Remarques |
|---|---|---|
| Raccourci de bascule Mac / PC | Ctrl+Cmd+R | Réglable, actif depuis n'importe quelle application |
| Touche NVDA | Verr. maj. | Ou Option droite, ou fn. Verr. maj. est remappée en F18 seulement pendant le contrôle du PC |
| Disposition du clavier du PC | Français | Ou américain |

Correspondance des modificateurs : Contrôle reste Contrôle, Option devient Alt,
Commande devient la touche Windows. Les lettres suivent le caractère produit, les
chiffres fonctionnent aussi sur la rangée du haut en azerty, et le pavé numérique
suit la disposition « ordinateur de bureau » de NVDA.

Limite connue sur Mac azerty : sans Majuscule, la touche `!` donne `_` sur le PC et
la touche `§` donne `-`, en échange de chiffres fiables avec Majuscule.

Au retour sur le Mac, toutes les touches encore enfoncées côté PC y sont relâchées,
précédées de la touche neutre de NVDA. Le retour est automatique si le PC part ou si
la connexion tombe. Si l'application se figeait, macOS désactive seul le tap et rend
le clavier au Mac. Un remappage de Verr. maj. resté en place après un plantage est
retiré au lancement suivant ; si un autre remappage existe déjà, l'application refuse
de l'écraser.

### Parole

| Message du PC | Traitement |
|---|---|
| `speak` | Parole système, changements de langue, pauses, priorité immédiate |
| `cancel` | Coupure immédiate |
| `pause_speech` | Pause et reprise |
| `tone` | Bips, avec la balance gauche droite |

Pas encore traités : les sons de NVDA (`wave`), le presse-papiers, et les commandes
de débit, de hauteur et de volume incluses dans la parole. Une parole interrompue
par une priorité immédiate n'est pas reprise ensuite, contrairement à NVDA.

### Outil en ligne de commande

Le paquet [NVDARemote/](NVDARemote) contient la bibliothèque `RemoteCore`, partagée
avec l'application, et un outil `nvdaremote` qui écoute le PC sans clavier :

```bash
cd NVDARemote && swift run -c release nvdaremote --verbose 'nvdaremote://nvdaremote.com:6837/?key=…&mode=master'
```

Tests : `cd NVDARemote && swift test`, 34 tests.

## Prochaine étape proposée

Au choix : les sons de NVDA et le presse-papiers, qui complètent l'usage quotidien ;
ou le braille, dernier point dur de l'étude.

## Documentation

| Fichier | Contenu |
|---|---|
| [docs/etude-nvda-remote-macos.md](docs/etude-nvda-remote-macos.md) | Étude de faisabilité : protocole détaillé, faisabilité fonction par fonction, points de conception, plan |
| [docs/mesures-parole.md](docs/mesures-parole.md) | Mesures `AVSpeechSynthesizer` et consignes d'implémentation |
| [docs/mesures-clavier.md](docs/mesures-clavier.md) | Mesures `CGEventTap`, niveau d'interception, pièges, table clavier |

Les deux documents de mesures corrigent chacun un point de l'étude initiale :
la correspondance des touches se fait par caractère produit et non par position,
et le prototype Python prévu a été abandonné au profit de bancs directement en Swift.

## Bancs d'essai

Chacun est un paquet Swift autonome, sans dépendance externe.

| Commande | Ce qu'elle mesure |
|---|---|
| `cd spikes/speech-bench && swift run -c release SpeechBench` | Latences, débit, enchaînement, synthèse hors lecture |
| `cd spikes/speech-bench && swift run -c release StopDiag` | Comportement fin de l'interruption de parole |
| `cd spikes/keyboard-tap && swift run -c release KeyboardTap --check` | Permissions seules, sans rien capturer |
| `cd spikes/keyboard-tap && swift run -c release KeyboardTap` | Test guidé complet, niveau session |
| `cd spikes/keyboard-tap && swift run -c release KeyboardTap --hid --voiceover` | Commandes VoiceOver, niveau HID |
| `cd spikes/keyboard-tap && swift run -c release KeyboardTap --hid --capslock` | Verrouillage majuscules |

Les bancs clavier capturent le clavier pendant leur exécution : VoiceOver ne répond
plus, les consignes sont donc données à la voix. Trois sorties de secours existent,
toutes validées : Échap passe toujours et termine le test, un chien de garde relâche
le clavier au bout de 90 secondes, et tuer le processus détruit le tap.

Le banc `--capslock` suppose un remappage `hidutil` actif, à appliquer avant et à
retirer après. La procédure figure dans [docs/mesures-clavier.md](docs/mesures-clavier.md).

## Organisation

| Chemin | Contenu |
|---|---|
| `NVDARemote.xcodeproj`, `App/` | Application macOS |
| `NVDARemote/` | Paquet Swift : bibliothèque `RemoteCore` et outil `nvdaremote` |
| `docs/` | Étude de faisabilité et mesures |
| `spikes/` | Bancs d'essai Swift |
| `nvda/` | Clone de référence de NVDA, non versionné |

Le module qui nous intéresse est `nvda/source/_remoteClient/`.
Pour recréer le clone de référence :

```bash
git clone --depth 1 --filter=blob:none https://github.com/nvaccess/nvda.git nvda
```

## Prérequis de test

Un PC sous Windows avec NVDA 2025.1 ou plus récent, Remote Access activé dans les
paramètres, joignable via le relais public `nvdaremote.com:6837` ou en mode
« Héberger localement ».

Côté Mac, les bancs clavier exigent que l'application qui les lance, donc le
terminal, soit autorisée dans Réglages Système, Confidentialité et sécurité, à la
fois en Accessibilité et en Surveillance de l'entrée.
