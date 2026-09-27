# Mesures de la parole sur macOS — AVSpeechSynthesizer

Date : 10 septembre 2026. macOS 26.6, Swift 6.3.3, Mac Apple Silicon.
Voix de mesure : Audrey (Enhanced), fr-FR.
Bancs d'essai : `spikes/speech-bench`, cibles `SpeechBench` et `StopDiag`.

## Verdict

**AVSpeechSynthesizer suffit.** Pas besoin d'embarquer eSpeak-ng en v1.
Le moteur système atteint 643 mots par minute, coupe la parole en 40 millisecondes
et enchaîne les énoncés sans blanc audible. C'est au niveau du ressenti NVDA.

Cela lève le risque principal identifié dans l'étude de faisabilité.

## Mesures

### Latence

| Mesure | Valeur |
|---|---|
| Premier énoncé de la session, jusqu'au premier mot | 449 ms |
| Énoncé suivant, jusqu'au premier mot | 120 ms (médiane) |
| Appel de `speak` jusqu'à `didStart` | 2 ms (médiane) |
| Couper puis prononcer le mot suivant | 40 ms (médiane), 53 ms au pire sur 10 essais |
| Blanc entre deux énoncés enchaînés | 1,8 ms (médiane), 6,7 ms cumulés sur 5 fragments |
| Blanc lors d'un changement de voix français vers anglais | 5 à 44 ms |

Le fait que couper puis reprendre (40 ms) soit plus rapide que parler après un
silence (120 ms) s'explique : dans le premier cas le moteur audio tourne déjà.
D'où la recommandation de le garder chaud.

### Débit

| `rate` | Mots par minute |
|---|---|
| 0,50 (défaut) | 177 |
| 0,60 | 279 |
| 0,70 | 378 |
| 0,85 | 519 |
| 1,00 (maximum) | 643 |
| 2,00 | 642, plafonné comme prévu |

La courbe est linéaire au-dessus de 0,5 : environ 100 mots par minute de plus
par pas de 0,1. Approximation utilisable : `motsParMinute ≈ 177 + (rate - 0,5) × 933`.

Repère : NVDA avec eSpeak tourne couramment entre 300 et 450 mots par minute,
soit un `rate` compris entre 0,63 et 0,79. La marge au-dessus est confortable.

### Synthèse hors lecture

`write(_:toBufferCallback:)` produit 2,12 secondes d'audio en 0,236 seconde de
calcul, soit 9 fois le temps réel, en 22 050 Hz.

Conséquence : si un jour la lecture par AVSpeechSynthesizer devient gênante, on
peut synthétiser vers des tampons et gérer nous-mêmes la sortie audio, ce qui
permettrait de mélanger proprement la parole et les bips de NVDA dans un même
graphe audio. Ce n'est pas nécessaire aujourd'hui.

### Voix disponibles

181 voix au total sur cette machine, dont 10 en fr-FR : 1 améliorée (Audrey),
9 standard, aucune premium. Les voix premium françaises se téléchargent depuis
les Réglages Système. Leur latence n'a pas été mesurée, voir les questions ouvertes.

## Ce que le code devra faire

1. **Ne pas utiliser `didCancel`.** Le rappel n'est jamais appelé sur macOS 26.
   `stopSpeaking(at:)` renvoie bien `true`, l'audio s'arrête, mais c'est `didFinish`
   qui est déclenché, environ 6 ms après l'appel. Toute logique de fin d'énoncé
   doit donc s'appuyer sur `didFinish` seul, sans distinguer fin normale et coupure.
   Un test automatisé qui attendrait `didCancel` resterait bloqué : c'est exactement
   le piège dans lequel le premier banc est tombé.

2. **Chauffer le moteur à l'ouverture de la session.** Le tout premier énoncé coûte
   450 ms au lieu de 120. Prononcer un énoncé très court, ou muet, au moment de la
   connexion, pour que le premier retour du PC soit immédiat.

3. **Un seul synthétiseur pour toute la session.** Dix cycles couper puis reprendre
   sur la même instance ont réussi sans dégradation. Inutile d'en recréer un.

4. **Correspondance avec les messages de NVDA :**
   - `cancel` → `stopSpeaking(at: .immediate)`.
   - `speak` avec `priority` 2 (immédiat) → couper, puis parler.
   - `speak` avec `priority` 0 ou 1 → mettre en file, `AVSpeechSynthesizer` enchaîne
     déjà sans blanc.
   - `pause_speech` → `pauseSpeaking` et `continueSpeaking`.

5. **Débit.** NVDA n'envoie pas de débit absolu : c'est un réglage local du Mac.
   Prévoir un curseur exprimé en mots par minute plutôt qu'en `rate`, plus parlant
   pour un utilisateur de lecteur d'écran, en appliquant la formule ci-dessus.
   Les commandes `RateCommand`, `PitchCommand` et `VolumeCommand` reçues dans une
   séquence sont relatives : elles s'appliquent par-dessus le réglage de base.

6. **`stopSpeaking(at: .word)` est à éviter.** Il laisse finir le mot en cours, soit
   environ 260 ms de plus dans la mesure. Toujours utiliser `.immediate`.

## Questions ouvertes

- Latence et débit maximum des voix premium et de Siri, non mesurés. À vérifier
  avant de les proposer par défaut : elles sont plus belles mais potentiellement
  plus lentes à démarrer, ce qui compte plus que la qualité sonore ici.
- `AVSpeechUtterance.prefersAssistiveTechnologySettings` n'a pas été testé. S'il
  permet d'hériter du débit réglé dans VoiceOver, cela éviterait à l'utilisateur
  de configurer deux fois son débit. À explorer.
- Le premier mot prononcé est repéré par le rappel `willSpeakRangeOfSpeechString`,
  qui est un indicateur proche du premier son mais pas le son lui-même. Les valeurs
  absolues sont donc à prendre comme des ordres de grandeur ; les comparaisons
  entre scénarios, elles, restent valables.

## Rejouer les mesures

```bash
cd spikes/speech-bench && swift run -c release SpeechBench
```

```bash
cd spikes/speech-bench && swift run -c release StopDiag
```

Les deux programmes parlent à voix haute, comptez une minute et demie chacun.
