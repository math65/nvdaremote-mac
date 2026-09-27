# Mesures de la capture clavier sur macOS — CGEventTap

Date : 10 septembre 2026. macOS 26.6, Mac Apple Silicon, clavier **azerty français**.
Banc d'essai : `spikes/keyboard-tap`, cible `KeyboardTap`.
VoiceOver était actif pendant tous les tests.

## Verdict

**La capture clavier globale fonctionne, à condition de poser le tap au niveau HID
et non au niveau session.** C'est la découverte principale de ce banc.

Au niveau session, tout est capturé et neutralisé sauf les commandes de VoiceOver,
que VoiceOver confisque avant nous. Au niveau HID, elles arrivent aussi.

Repère confirmant que la voie est la bonne : l'application Clean Buddy verrouille
l'intégralité du clavier pour le nettoyage, VoiceOver compris.

Le cas de Verrouillage majuscules, d'abord jugé bloquant, est **résolu** par un
remappage `hidutil` vers F18. Voir la section correspondante.

## Permissions

Les deux sont nécessaires, et macOS refuse de créer le tap sans elles :

| Permission | Rôle |
|---|---|
| Accessibilité | Modifier et avaler les événements |
| Surveillance de l'entrée | Observer les événements |

Piège pratique : un exécutable en ligne de commande n'a pas d'identité propre pour
macOS. Les autorisations se rattachent à l'application qui le lance, donc au
terminal. L'application finale, elle, aura sa propre identité et demandera pour
son compte, ce qui est le comportement souhaité.

## Niveau d'interception : le point décisif

| Combinaison | Tap `.cgSessionEventTap` | Tap `.cghidEventTap` |
|---|---|---|
| Lettre simple | vue et avalée | vue et avalée |
| Commande+Tab | vue et avalée, l'application au premier plan n'a pas changé | vue et avalée |
| Commande+Espace | vue et avalée, Spotlight ne s'est pas ouvert | vue et avalée |
| Contrôle+Option+flèche (VoiceOver) | **flèche jamais reçue**, seuls les modificateurs | **flèche reçue**, code 124 avec option+ctrl |

Au niveau session, seuls les changements de modificateurs remontaient : la flèche
elle-même était consommée par VoiceOver, qui a bien réagi à voix haute. Au niveau
HID, le `keyDown` de la flèche est présent avec ses modificateurs.

Conséquence pour le projet : utiliser `.cghidEventTap` avec `.headInsertEventTap`.

Le tap n'a jamais été désactivé par le système pendant les essais, ni par délai
d'attente ni par entrée utilisateur, sur les deux niveaux.

## Verrouillage majuscules : résolu

### Le problème

Sans traitement particulier, la touche est vue par le tap comme un `flagsChanged`
sur le code 57, **mais l'avaler ne l'empêche pas d'agir**. La preuve figure dans
les mesures : après une bascule, la touche suivante a produit « A » majuscule et
non « a ». L'état de verrouillage est géré sous le niveau du tap, y compris au
niveau HID.

C'est bloquant si l'on veut proposer Verr. maj. comme touche NVDA, ce qui est
l'habitude de beaucoup d'utilisateurs sur portable.

### La solution retenue : remapper la touche avec hidutil

`hidutil` réécrit la correspondance au niveau du pilote HID, avant tout le reste.
En redirigeant Verr. maj. vers une touche de fonction inutilisée, elle devient une
touche ordinaire : plus aucune bascule, et le tap la reçoit normalement.

```bash
hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
```

`0x700000039` est le code d'usage HID de Verr. maj., `0x70000006D` celui de F18.

Pour annuler :

```bash
hidutil property --set '{"UserKeyMapping":[]}'
```

**Testé le 10 septembre 2026, résultat sans ambiguïté.** Après remappage, deux
essais consécutifs donnent :

```
keyDown  code 79 (F18)  aucun caractère  modificateurs fn  avalé
keyDown  code 12 (ANSI_Q)  caractère « a »  modificateurs aucun  avalé
```

La lettre tapée juste après reste minuscule aux deux essais : la bascule ne se
produit plus du tout. La touche arrive comme un F18 ordinaire, que le tap avale
sans difficulté.

Propriétés de cette méthode :

- Ni `sudo`, ni pilote, ni extension noyau, ni redémarrage.
- Effet immédiat, et **annulé au redémarrage**. Pour le rendre permanent, un agent
  de lancement dans `~/Library/LaunchAgents` rejoue la commande à l'ouverture de
  session.
- `hidutil` n'est qu'un client en ligne de commande d'une API IOKit : l'app
  pourrait donc appliquer et retirer le remappage elle-même, sans dépendre du
  binaire système. À vérifier au moment de l'implémentation.

Note au passage : le F18 issu du remappage porte lui aussi le drapeau `fn`, ce qui
confirme une fois de plus qu'il ne faut jamais se fier à ce drapeau.

### Précaution indispensable

Tant que le remappage est actif, l'utilisateur n'a plus de Verr. maj. **dans tout
le système**. L'app doit donc :

- ne l'appliquer que si l'utilisateur choisit Verr. maj. comme touche NVDA, après
  une explication claire ;
- le retirer à la fermeture de l'app, y compris en cas d'arrêt anormal, en
  vérifiant et en nettoyant au lancement suivant ;
- rappeler qu'un simple redémarrage suffit à tout remettre en ordre.

### Les deux autres pistes, écartées

- **`IOHIDSetModifierLockState`** : avaler l'événement puis forcer l'état de
  verrouillage à revenir en arrière. Fonctionne en théorie, mais c'est un
  rattrapage après coup, avec un risque de clignotement de la diode et une course
  entre l'événement et la correction. Inutile puisque le remappage règle le
  problème à la source. À garder en réserve.
- **Réglages Système, Clavier, Touches de modification, « Aucune action »** :
  manipulation manuelle, et surtout non testée ici. Le doute porte sur le fait
  qu'elle pourrait supprimer complètement l'événement, ce qui rendrait la touche
  inutilisable pour nous plutôt que capturable. À évaluer si besoin.

## Touche fn, et un piège sérieux

La touche fn est bien vue, sous deux formes : un `keyDown` de code **179**, la
touche Globe des Mac récents, absente des constantes Carbon, et un `flagsChanged`
de code 63.

Le piège : **les flèches portent en permanence le drapeau fn**, ainsi que le
drapeau pavé numérique. Relevé brut d'une flèche droite pressée seule :

```
keyDown  code 124 (RightArrow)  modificateurs fn+pavénum
```

Il est donc impossible de détecter un appui sur fn en lisant les drapeaux : il
faut s'appuyer sur les codes de touche 179 et 63. Une implémentation naïve qui
testerait le drapeau fn croirait que la touche NVDA est enfoncée dès que
l'utilisateur appuie sur une flèche, ce qui casserait toute la navigation.

Le même raisonnement vaut pour le drapeau pavé numérique, inutilisable pour
distinguer le vrai pavé numérique.

## Disposition du clavier : la table doit se faire par caractère

Relevé sur le clavier azerty de la machine :

| Code de touche | Nom de position | Caractère produit |
|---|---|---|
| 0 | ANSI_A | q |
| 6 | ANSI_Z | w |
| 12 | ANSI_Q | a |
| 13 | ANSI_W | z |

Le code de touche macOS est **positionnel** : il désigne un emplacement physique,
nommé d'après le clavier américain. Le caractère produit dépend de la disposition
active sur le Mac.

Or les codes de touches virtuelles de Windows ne sont pas positionnels : sur une
disposition française, la touche qui produit « a » porte le code `VK_A`, et NVDA
recalcule lui-même le code de balayage à partir du code virtuel, puisqu'il ignore
celui que nous envoyons.

**Il faut donc établir la correspondance par caractère produit, pas par position.**
Exemple : la touche de code 12 produit « a » sur le Mac, on envoie `VK_A`, et la
machine Windows produit « a », qu'elle soit en azerty ou en qwerty.

Cela **corrige la recommandation initiale de l'étude de faisabilité**, qui
proposait de commencer par la position physique. Cette approche aurait envoyé
`VK_Q` quand l'utilisateur appuie sur la touche marquée « a ».

Réserves à traiter au moment de l'implémentation :

- Le caractère doit être lu **sans modificateurs**. Sinon Majuscule+A donne « A »
  et Option+A donne un caractère composé. Il faut retraduire la touche avec des
  modificateurs vides, par `UCKeyTranslate` ou en effaçant les drapeaux d'une
  copie de l'événement avant de lire la chaîne.
- Cette règle est propre et suffisante pour les **lettres**. Pour les **chiffres
  et la ponctuation**, elle ne suffit pas : sur azerty la rangée du haut produit
  « & é " ' ( » sans majuscule, alors que les codes `VK_1` à `VK_0` de Windows
  désignent ces mêmes touches. Il faudra une petite table par disposition, à
  écrire une fois pour le français et une fois pour l'américain.
- Les touches sans caractère, flèches, fonctions, navigation, se mappent par code
  de touche, ce qui ne pose aucun problème.

## Ce que le code devra faire

1. Poser le tap avec `.cghidEventTap` et `.headInsertEventTap`, en `.defaultTap`
   pour pouvoir avaler les événements.
2. Traiter `tapDisabledByTimeout` et `tapDisabledByUserInput` en réactivant le tap.
   Le cas ne s'est jamais produit ici, mais il survient si le rappel devient lent.
3. Ne jamais lire le drapeau fn pour détecter la touche fn : utiliser les codes
   179 et 63.
4. Déduire le code de touche virtuelle Windows du caractère produit sans
   modificateurs, avec repli sur une table positionnelle pour les touches muettes.
5. Si Verr. maj. est retenue comme touche NVDA, appliquer le remappage `hidutil`
   vers F18 à l'activation, le retirer à la fermeture, et nettoyer au lancement
   suivant si l'app s'est arrêtée anormalement.
6. Prévoir une sortie de secours indépendante du reste, car un tap actif rend la
   machine inutilisable en cas de blocage. Le banc en utilise trois, toutes
   validées : Échap systématiquement laissée passer, chien de garde libérant le
   clavier au bout d'un délai, et destruction du tap à la mort du processus.

## Question restée ouverte

Au niveau HID, le `keyDown` de Contrôle+Option+flèche est bien capturé et avalé.
Il reste à confirmer par l'oreille que VoiceOver ne réagit plus du tout dans ce
mode, c'est-à-dire que l'avalement est effectif et pas seulement l'observation.
Les événements ont bien été marqués comme avalés par le banc, mais seul un
retour auditif le prouve.

## Rejouer les mesures

Vérifier les permissions sans rien capturer :

```bash
cd spikes/keyboard-tap && swift run -c release KeyboardTap --check
```

Test guidé complet, sept étapes, niveau session :

```bash
cd spikes/keyboard-tap && swift run -c release KeyboardTap
```

Test ciblé sur VoiceOver, quatre étapes, niveau HID :

```bash
cd spikes/keyboard-tap && swift run -c release KeyboardTap --hid --voiceover
```

Les consignes sont données à la voix, puisque VoiceOver est neutralisé pendant
la capture. Échap termine à tout moment.
