# NVDA Remote pour macOS

Client natif macOS pour la fonction **Remote Access** de NVDA : piloter un PC Windows
sous NVDA depuis un Mac, avec la parole, les sons et (à terme) le braille.

Le Mac joue le rôle de **contrôleur** (« leader », `master` dans le protocole).
Le mode inverse, un PC qui piloterait le Mac, est hors périmètre : aucune API publique
ne permet de capter la parole de VoiceOver.

## Où on en est

Phase d'étude et de levée des risques. **Pas encore de code applicatif**, seulement
des bancs d'essai qui répondent chacun à une question précise.

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

## Prochaine étape proposée

Construire la première tranche réelle de l'application : se connecter au PC et
**entendre NVDA parler depuis le Mac**. C'est du travail sans incertitude
maintenant que le protocole est lu et la parole validée, et c'est le moment où le
projet devient tangible. Le braille viendra après.

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
