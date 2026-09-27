# NVDA Remote pour macOS — étude de faisabilité

Date : 10 septembre 2026.
Base analysée : dépôt `nvaccess/nvda`, commit `dd2bccb` (10 septembre 2026), module `source/_remoteClient/` (17 fichiers, environ 5 300 lignes). Depuis NVDA 2025.1, l'ancienne extension NVDA Remote est intégrée au cœur de NVDA sous le nom « Remote Access ». Le protocole réseau est resté compatible avec l'extension 2.6.x.

Objectif : piloter un PC Windows sous NVDA depuis un Mac. Le Mac joue donc le rôle de **contrôleur** (« leader », `master` sur le fil), le PC celui de **contrôlé** (« follower », `slave`). Aucun code n'est écrit à ce stade.

---

## 1. Ce qui existe déjà

| Projet | Plateformes | Points forts | Limites connues |
|---|---|---|---|
| NVDARemote (App Store, Malte Schoeppe, gratuit, v1.4 de janvier 2025) | iPhone, iPad, Vision Pro, Mac Apple Silicon (en mode iPad) | Client officiel-ish, TTS intégré, transmet Ctrl, Alt, Windows, Échap, F1-F12 | Clavier externe obligatoire, pas de braille, curseur de débit TTS cassé, volume sur la sonnerie et non le média, pas conçu pour macOS |
| nvdr (ogomez92, GPL) | CLI Rust Linux, app Mac SwiftUI, iOS, Android, extension NVDA | App Mac native, capture clavier système via `CGEventTap` + `IOHIDManager`, touche « leader » pour les touches Windows | Passe obligatoirement par un pont SSH sur une machine tierce, pas de braille, pas de bips ni de sons NVDA, ne distingue pas gauche/droite des modificateurs |

Conclusion : il n'existe pas de client macOS natif complet, direct (sans pont), avec parole interruptible, sons et braille. C'est la place à prendre.

---

## 2. Comment fonctionne Remote Access (lecture du code)

### 2.1 Architecture

Trois rôles :

- **Relais** : serveur sans intelligence. Un client authentifié envoie un message, le relais le rediffuse à tous les autres clients du canal en ajoutant un champ `origin` (identifiant du client émetteur). Deux relais possibles :
  - `nvdaremote.com:6837` (relais public). Certificat Let's Encrypt valide, TLS 1.3, vérifié ce jour avec `openssl s_client` : `Verify return code: 0 (ok)`. Un client Mac peut donc utiliser la validation TLS standard du système.
  - NVDA lui-même en mode « Héberger localement » (`server.py`). Certificat auto-signé « NVDA Remote Access Service », renouvelé tous les 365 jours. Le client vérifie l'empreinte SHA-256 du certificat DER et la mémorise (« trust on first use »).
- **Leader** (contrôleur) : capture le clavier, l'envoie ; reçoit parole, sons, braille.
- **Follower** (contrôlé) : injecte les touches reçues ; renvoie sa parole, ses bips, ses sons, ses cellules braille.

Le relais accepte plusieurs leaders et plusieurs followers dans le même canal ; tout est diffusé à tout le monde. Un client doit donc ignorer les messages qui ne le concernent pas (par exemple les `key` envoyés par un autre leader).

### 2.2 Transport

- TCP + TLS (le client NVDA impose TLS 1.2 ; le relais public négocie TLS 1.3).
- Messages JSON UTF-8, un par ligne, terminés par `\n`. Champ obligatoire `type`.
- `TCP_NODELAY` activé, keepalive TCP (1 minute), reconnexion automatique toutes les 5 secondes, `ping` serveur toutes les 5 minutes (sans réponse attendue).
- Les messages envoyés avant la connexion sont jetés, pas mis en file.

Fichiers : `transport.py` (connexion, lecture ligne par ligne, empreinte), `serializer.py` (JSON), `protocol.py` (liste des types).

### 2.3 Poignée de main

```
→ {"type": "protocol_version", "version": 2}
→ {"type": "join", "channel": "<clé>", "connection_type": "master"}
← {"type": "channel_joined", "channel": "<clé>", "user_ids": [3], "clients": [{"id": 3, "connection_type": "slave"}]}
```

Ensuite, au fil de la session :

```
← {"type": "client_joined", "user_id": 4, "client": {"id": 4, "connection_type": "slave"}, "origin": 4}
← {"type": "client_left",   "user_id": 4, "client": {"id": 4, "connection_type": "slave"}, "origin": 4}
← {"type": "motd", "motd": "texte", "force_display": false}
← {"type": "version_mismatch"}
← {"type": "error", "message": "incorrect_password"}        (serveur NVDA local uniquement)
← {"type": "nvda_not_connected"}                             (prévu au protocole, jamais implémenté côté serveur)
```

La clé sert à la fois d'identifiant de canal et de mot de passe. Génération d'une clé par le serveur : se connecter, envoyer `protocol_version` puis `{"type": "generate_key"}` au lieu de `join`, recevoir `{"type": "generate_key", "key": "..."}`, fermer.

### 2.4 Messages reçus par le contrôleur (venant du PC)

| Type | Champs | Sens |
|---|---|---|
| `speak` | `sequence`, `priority` (0 normal, 1 suivant, 2 immédiat) | Parole de NVDA, voir format ci-dessous |
| `cancel` | aucun | NVDA a interrompu sa parole (touche pressée, etc.). À traiter **immédiatement** : c'est ce qui rend la lecture réactive |
| `pause_speech` | `switch` (bool) | Pause ou reprise (Maj sur le PC) |
| `tone` | `hz`, `length` (ms), `left`, `right` (0-100) | Bip NVDA (progression, mode navigation, etc.) |
| `wave` | `fileName` | Son NVDA. Le chemin est un chemin **Windows** sur le PC distant ; seul le nom de base est exploitable |
| `display` | `cells` (liste d'entiers 0-255) | Cellules braille, 1 ligne, motif de points par cellule |
| `set_clipboard_text` | `text` | Le PC pousse son presse-papiers |
| `set_braille_info` | `name`, `numCells` | Envoyé par les **autres leaders** ; NVDA y répond en renvoyant ses propres infos |
| `key` | | Touches envoyées par un autre leader : à ignorer |

### 2.5 Messages envoyés par le contrôleur

| Type | Champs | Remarques |
|---|---|---|
| `key` | `vk_code`, `extended`, `pressed`, `scan_code` | Un message par enfoncement et par relâchement, modificateurs compris. **`scan_code` est ignoré** par le PC (`localMachine.sendKey` passe `None`, puis `MapVirtualKey` recalcule). Conséquence : `VK_PACKET` (Unicode) est inutilisable |
| `set_braille_info` | `name`, `numCells` | À envoyer à chaque `client_joined` d'un follower. Avec `numCells` = 0, le PC n'envoie jamais de `display` |
| `braille_input` | voir 2.7 | Gestes de l'afficheur du contrôleur |
| `set_clipboard_text` | `text` | Pousser le presse-papiers |
| `send_SAS` | aucun | Ctrl+Alt+Suppr ; ne marche que si NVDA est installé sur le PC avec UIAccess et stratégie `SoftwareSASGeneration` adéquate |

### 2.6 Format de `speak`

`sequence` est une liste mélangeant des chaînes et des paires `[NomDeClasse, {attributs}]`. Seules les sous-classes de `SynthCommand` et `EndUtteranceCommand` sont sérialisées (`serializer.py`) ; les commandes à rappel (`BeepCommand`, `WaveFileCommand`, `CallbackCommand`) sont filtrées côté PC et arrivent séparément sous forme de `tone` et `wave`.

| Classe | Attributs | Signification |
|---|---|---|
| `IndexCommand` | `index` | Marqueur de position (NVDA s'en sert pour le suivi du curseur) |
| `CharacterModeCommand` | `state`, `isDefault` | Mode épellation |
| `LangChangeCommand` | `lang` (ex. `fr_FR`), `isDefault` | Changement de langue |
| `BreakCommand` | `time` (ms) | Pause |
| `PitchCommand`, `RateCommand`, `VolumeCommand` | `_offset`, `_multiplier`, `isDefault` | Prosodie relative |
| `PhonemeCommand` | `ipa`, `text` | Prononciation IPA avec texte de repli |
| `EndUtteranceCommand` | aucun | Fin d'énoncé |

Exemple réel :

```json
{"type": "speak", "priority": 0, "origin": 3,
 "sequence": [["LangChangeCommand", {"lang": "fr_FR", "isDefault": false}],
              "Bureau  liste",
              ["IndexCommand", {"index": 12}],
              ["EndUtteranceCommand", {}]]}
```

Un client doit tolérer une classe inconnue (l'ignorer), comme le fait NVDA.

### 2.7 Clavier, tel que le PC le traite

- Le PC fait `SendInput` avec `wVk` = `vk_code`, `wScan` = `MapVirtualKey(vk)`, drapeau `KEYEVENTF_EXTENDEDKEY` si `extended`, `KEYUP` si `pressed` est faux (`input.py`).
- Les codes utiles sont dans `vkCodes.py`. Points importants :
  - Insert = `0x2D` avec `extended` = vrai ; `0x2D` non étendu = pavé numérique Insert. Les deux sont « touche NVDA » par défaut.
  - Flèches, Début, Fin, Page : `extended` vrai. Les mêmes codes avec `extended` faux sont les touches du pavé numérique (`numpad8`, `numpad4`…), celles qu'utilise la disposition « ordinateur de bureau » de NVDA.
  - `VK_NONE` = `0xFF` : NVDA l'envoie pressé puis relâché comme « touche neutre » pour casser une combinaison au moment de repasser en contrôle local (`releaseKeys`).
- Bascule côté NVDA : NVDA+Alt+Tab. Au passage en mode distant, les modificateurs de la combinaison de bascule sont mis en attente pour que leur relâchement ne parte pas vers le PC ; au retour en local, tous les modificateurs encore enfoncés sont relâchés à distance.
- Le contrôleur envoie les touches **brutes** : c'est le PC qui interprète les combinaisons. Ordre à respecter : modificateur enfoncé, touche enfoncée, touche relâchée, modificateur relâché.

### 2.8 Braille

- Le PC n'envoie `display` que si au moins un leader a déclaré `numCells` > 0. Il réduit alors sa propre largeur à la plus petite largeur déclarée et force une seule ligne (`localMachine._handleFilterDisplayDimensions`).
- `cells` : entiers 0-255, un par cellule, bits = points 1 à 8. Le contrôleur complète à droite avec des zéros.
- Entrée braille (`braille_input`) : dictionnaire plat avec `source`, `model`, `id` ou `identifiers`, `dots`, `space`, `cellIndexes` (liste) plus `routingIndex` (compatibilité, une seule cellule), et `scriptPath` = `[module, classe, script]` que le PC résout dans ses propres scripts (`input.py`, `BrailleInputGesture.findScript`).

### 2.9 Divers

- Schéma d'URL : `nvdaremote://hôte:port/?key=…&mode=master&insecure=true`. « Copier le lien » sur le PC contrôlé produit déjà un lien avec `mode=master`, prêt pour le Mac.
- Sons NVDA (`source/waves/`) : `connected`, `disconnected`, `controlled`, `controlling`, `clipboardPush`, `clipboardReceive`, `browseMode`, `focusMode`, `error`, etc. Ils sont sous GPL v2+.
- Bureau sécurisé (UAC, écran de connexion) : géré entièrement côté PC par un pont local ; rien à faire côté Mac.

---

## 3. Ce qu'un client macOS peut faire, fonction par fonction

| Fonction | Faisabilité | Comment sur macOS | Remarques |
|---|---|---|---|
| Connexion relais public | Facile | `Network.framework` (`NWConnection` + TLS), validation système | Certificat valide vérifié ce jour |
| Connexion à un NVDA serveur | Facile | Même chose + `sec_protocol_options_set_verify_block` : SHA-256 du certificat DER, dialogue de confiance la première fois, empreinte mémorisée | Reproduit le comportement de NVDA |
| Poignée de main, clé générée, MOTD, liste des clients, reconnexion | Facile | `JSONSerialization`, lecture par lignes, boucle toutes les 5 s | |
| Parole, voie A | Facile | `AVSpeechSynthesizer` : voix système, indépendante de VoiceOver. `stopSpeaking(.immediate)` pour `cancel`, `pauseSpeaking` pour `pause_speech`, `rate`/`pitchMultiplier`/`volume` pour la prosodie, choix de voix par langue pour `LangChangeCommand`, épellation pour `CharacterModeCommand`, attribut `AVSpeechSynthesisIPANotationAttribute` pour `PhonemeCommand`, délégué pour `IndexCommand` | Recommandé par défaut. Priorité 2 = interrompre l'énoncé en cours |
| Parole, voie B | Moyen | Annonces VoiceOver (`NSAccessibility.post(… .announcementRequested …)`) : parlées avec la voix et le débit de VoiceOver | Pas d'interruption ni de pause, cadence limitée, coalescence possible. Utile en option pour les gens qui veulent tout dans VoiceOver |
| Parole, voie C | Plus tard | eSpeak-ng embarqué (bibliothèque C, se compile sur macOS) | Pour retrouver la voix eSpeak habituelle des utilisateurs NVDA, débit très rapide |
| Bips (`tone`) | Facile | `AVAudioEngine` avec générateur sinusoïdal, panoramique gauche/droite | |
| Sons (`wave`) | Facile | Table nom de base → son embarqué | Reprendre les `.wav` de NVDA impose la GPL ; sinon, sons maison |
| Presse-papiers dans les deux sens | Facile | `NSPasteboard` | |
| Ctrl+Alt+Suppr | Facile | Un message | Dépend de la configuration du PC |
| Capture clavier en mode distant | Le gros morceau | `CGEventTap` (permission « Surveillance de l'entrée ») posé en tête de session : avaler toutes les touches, les convertir, les envoyer. Karabiner-Elements et nvdr font exactement cela, donc c'est faisable, y compris pour ⌘+Tab | Voir les points de conception ci-dessous |
| Raccourci de bascule local/distant | Facile | Raccourci global reconnu dans le tap, hors capture | Doit rester fiable dans les deux modes |
| Braille en sortie | Difficile | Voir section 4.5 | VoiceOver possède l'afficheur |
| Braille en entrée | Difficile | Dépend de la sortie | |
| Mode contrôlé (le PC pilote le Mac) | Hors périmètre | Aucune API publique pour capter la parole de VoiceOver | Ne pas viser |
| URL `nvdaremote://` | Facile | `CFBundleURLTypes` | |
| Muet distant, autoconnexion au lancement, liste des dernières connexions | Facile | Préférences | |

---

## 4. Points de conception à trancher

### 4.1 Parole

**Tranché et mesuré le 10 septembre 2026, voir [mesures-parole.md](mesures-parole.md).**
`AVSpeechSynthesizer` par défaut : 643 mots par minute au maximum, interruption
effective en 40 millisecondes, enchaînement sans blanc. eSpeak-ng embarqué n'est
pas nécessaire. Annonces VoiceOver conservées en option.

### 4.2 Capture clavier : globale ou fenêtre au premier plan

- **Globale** (`CGEventTap`) : fonctionne quelle que soit l'application au premier plan, permet d'avaler les touches avant VoiceOver et avant le système. Demande la permission « Surveillance de l'entrée » (et « Accessibilité » si on veut aussi poster des événements). C'est ce que fait nvdr.
- **Locale** (`NSEvent` monitor quand l'app a le focus) : sans permission, mais VoiceOver intercepte ses propres combinaisons et le système garde ⌘+Tab, ⌘+Espace, etc.

Recommandation : globale, activée uniquement en mode « contrôle du PC ».

### 4.3 Correspondance des touches

**Mesuré le 10 septembre 2026, voir [mesures-clavier.md](mesures-clavier.md).**
Deux points de cette section sont corrigés par les mesures : le tap doit être posé
au niveau HID et non au niveau session, sans quoi VoiceOver confisque ses propres
commandes ; et la correspondance doit se faire **par caractère produit**, non par
position physique, contrairement à ce qui est écrit plus bas.


- Correspondance de base kVK (position physique, `Carbon.HIToolbox`) → VK Windows, table à écrire une fois.
- Modificateurs : ⌃ → Ctrl, ⌥ → Alt, ⌘ → Windows (convention Boot Camp / Parallels), gauche et droite distingués (`0xA2`/`0xA3`, `0xA4`/`0xA5`, `0x5B`/`0x5C`).
- **Touche NVDA** : pas d'Insert sur Mac. Prévoir un réglage : `fn`, ⌥ droite, ⌘ droite ou Verrouillage majuscules → `0x2D` étendu. Verr. maj. est délicat (l'état bascule au niveau système) ; `fn` est simple (événement `flagsChanged`, code 63).
- **Pavé numérique** : envoyer les chiffres du pavé Mac comme touches de navigation non étendues (`0x26` non étendu = `numpad8`, etc.) pour que la disposition « bureau » de NVDA fonctionne, ou proposer la disposition « portable » côté NVDA.
- **Dispositions** : les lettres passent bien (VK `0x41`-`0x5A` = lettre de la disposition courante du PC). La ponctuation dépend de la disposition du PC (`VK_OEM_*`), et AltGr sur PC azerty n'existe pas sur Mac. ~~Recommandation : commencer par la position physique.~~ **Corrigé par la mesure : la correspondance se fait par caractère produit sans modificateurs.** Sur le Mac azerty testé, la touche de code 12 est nommée « ANSI_Q » mais produit « a » ; mapper par position enverrait `VK_Q` et le PC écrirait « q ». Les lettres se règlent ainsi complètement ; les chiffres et la ponctuation demandent une petite table par disposition.

### 4.4 Cohabitation avec VoiceOver

- En mode distant, le tap avale tout, VoiceOver ne voit rien : c'est voulu. Il faut une sortie de secours (raccourci de bascule, et par exemple maintien d'une touche 2 secondes).
- Option « muet au retour en local » comme dans NVDA, pour ne pas entendre le PC pendant qu'on travaille sur le Mac.
- L'app elle-même doit être irréprochable côté VoiceOver (fenêtre de connexion, réglages, historique).

### 4.5 Braille

Trois paliers, par difficulté croissante :

1. **Aucun braille** en v1 : envoyer `set_braille_info` avec `numCells` = 0.
2. **Afficheur virtuel** : une fenêtre affichant les cellules reçues sous forme de caractères Unicode braille (`U+2800` + valeur de la cellule). VoiceOver relaie ce texte sur l'afficheur physique. Peu de code, à valider en pratique (traduction et rafraîchissement par VoiceOver). Pas d'entrée braille ni de routage.
3. **Pilote direct** : ouvrir l'afficheur en USB HID (norme « HID braille », page d'usage 0x41) ou Bluetooth via IOKit, quand VoiceOver ne l'a pas pris. Sortie et entrée complètes (points, espace, routage → `braille_input`). Du code de pilotage direct existant, par exemple un projet Brailliant, serait réutilisable ici.

### 4.6 Technologie

- Application native Swift + AppKit (ou SwiftUI), zéro dépendance externe : `Network`, `AVFoundation`, `CoreGraphics`, `IOKit`.
- Avant cela, un **prototype Python** en ligne de commande peut réutiliser presque tels quels `serializer.py` et `transport.py` de NVDA (retirer `wx.CallAfter` et `SIO_KEEPALIVE_VALS`), parler via `say` ou `AVSpeechSynthesizer` par PyObjC, et valider le protocole de bout en bout en une soirée.

### 4.7 Licence

Le protocole n'est pas protégé ; un client écrit à neuf peut avoir n'importe quelle licence. Reprendre du code ou les sons de NVDA place le projet sous GPL v2 ou ultérieure.

---

## 5. Plan proposé pour quand on codera

1. ~~**Phase 0, prototype Python**~~ : abandonné. Xcode 26 et Swift 6.3 étant
   présents sur la machine, les bancs d'essai sont écrits directement en Swift,
   dans la pile finale, donc sans rien à réécrire. Le banc parole est fait
   (`spikes/speech-bench`), voir [mesures-parole.md](mesures-parole.md).
2. **Phase 1, app Swift** : connexion (relais et serveur NVDA avec empreinte), parole `AVSpeechSynthesizer` avec `cancel` et priorités, bips, sons, presse-papiers, génération de clé, historique, URL `nvdaremote://`.
3. **Phase 2, clavier** : tap global, bascule, table kVK → VK, touche NVDA configurable, pavé numérique, table de disposition FR.
4. **Phase 3, braille** : afficheur virtuel, puis pilote direct.

Environnement de test : un PC avec NVDA 2025.1 ou plus récent, Remote Access activé dans les paramètres, soit via `nvdaremote.com`, soit en « Héberger localement » sur le port 6837 avec le journal `debugLog.remoteClient` activé pour voir les messages.

---

## 6. Repères dans le code cloné

Tous sous `nvda/source/_remoteClient/` :

- `protocol.py` : types de messages, port 6837, préfixe d'URL.
- `serializer.py` : JSON ligne par ligne, encodage des commandes de parole.
- `transport.py` : socket TLS, empreinte, reconnexion, `RelayTransport.onConnected` (poignée de main).
- `session.py` : `LeaderSession` (ce que fait le contrôleur) et `FollowerSession` (ce que fait le PC), négociation braille, `handleDecideExecuteGesture` (format de `braille_input`).
- `client.py` : `processKeyInput` (envoi des touches), `toggleRemoteKeyControl`, `releaseKeys`, gestion des certificats.
- `localMachine.py` : réception côté contrôleur (`speak`, `display`, `beep`, `playWave`, `sendKey`, `sendSAS`).
- `input.py` : injection des touches sur le PC (`SendInput`).
- `server.py` : serveur relais intégré, certificat auto-signé, `ping`.
- `connectionInfo.py` : URL `nvdaremote://`.
- `../vkCodes.py` : table des codes de touches Windows.
- `../../user_docs/en/userGuide.md`, section « Remote Access » : comportement attendu côté utilisateur.
