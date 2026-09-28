## NVDA Remote 1.0 bêta 1 (build 5) — 28 septembre 2026

Voici la première bêta publique de NVDA Remote pour Mac, en route vers la version 1.0. Elle vous permet de contrôler un PC Windows équipé de NVDA directement depuis votre Mac : vous tapez sur le clavier du Mac, et vous entendez NVDA parler sur le Mac, avec ses bips et ses sons. L'application a été pensée d'abord pour les utilisateurs de VoiceOver, et elle s'utilise tout aussi bien à la vue.

Tout ce qui est décrit ci-dessous fonctionne, mais comme c'est une bêta, vous pouvez encore tomber sur quelques imperfections. Signalez-les-moi avec Aide, puis Contacter le développeur.

### Ce que vous pouvez faire

- **Vous connecter en un instant.** Cliquez sur le lien que NVDA vous donne avec « Copier le lien », ou tapez la clé vous-même. Le serveur public nvdaremote.com fonctionne sans rien régler, et vos connexions récentes sont gardées pour la prochaine fois.
- **Entendre le PC sur votre Mac.** La parole de NVDA sort du Mac, dans la voix et la langue demandées par NVDA, et s'arrête dès que NVDA s'interrompt. Vous réglez le débit dans les Réglages.
- **Passer le clavier d'un raccourci.** Contrôle-Commande-R pour taper sur le PC, et encore une fois pour revenir au Mac. Un bip aigu signifie que le PC a le clavier, un bip grave que c'est le Mac. Pendant que vous contrôlez le PC, toutes les touches y partent, commandes VoiceOver comprises.
- **Partager le presse-papiers.** Le texte copié sur le PC arrive dans le presse-papiers du Mac. Contrôle-Commande-C envoie au PC ce que vous avez copié sur le Mac.
- **Lire NVDA en braille.** Si votre plage braille est un modèle HID, comme une Brailliant BI X, NVDA la prend pendant que vous contrôlez le PC, touches de routage et clavier braille compris. VoiceOver la récupère quand vous revenez au Mac.
- **Rester discrète.** L'application peut vivre dans la barre des menus, dans le Dock, ou les deux.

### Nouveau depuis la version de test 0.1

- **Mises à jour automatiques.** L'application cherche elle-même les nouvelles versions et les installe avec votre accord. Vous pouvez aussi vérifier à tout moment depuis le menu de l'application ou l'icône de la barre des menus. Comme c'est une bêta, l'application vous propose aussi les bêtas suivantes ; vous pouvez le désactiver dans Réglages, Général.
- **Contacter le développeur depuis l'application.** Aide, puis Contacter le développeur, pour signaler un problème, proposer une idée ou poser une question. Un signalement de problème joint quelques détails techniques pour aider, mais jamais votre clé de canal ni l'adresse de votre propre serveur.
- **Une icône bien à elle**, et une lecture plus facile pour tout le monde : les textes trop pâles sont plus foncés, les explications que seul VoiceOver lisait s'affichent maintenant à l'écran, et les raccourcis sont présentés à la manière habituelle du Mac.

### Avant de commencer

- Un Mac sous macOS 14 Sonoma ou plus récent, et NVDA 2025.1 ou plus récent sur le PC, avec l'Accès à distance activé.
- Pour contrôler le PC, autorisez NVDA Remote à la fois dans Accessibilité et dans Surveillance de l'entrée, dans Réglages Système, Confidentialité et sécurité. L'application vous les demande depuis ses réglages Clavier.

### Bon à savoir

- Certaines finesses de la parole de NVDA ne sont pas encore suivies : les changements de hauteur ou de volume au milieu d'une phrase, et l'épellation des caractères.
- Le braille fonctionne pour l'instant avec les plages HID uniquement.

### Téléchargement

[NVDA-Remote-1.0-beta.1-5.zip](https://github.com/math65/nvdaremote-mac/releases/download/v1.0-beta.1/NVDA-Remote-1.0-beta.1-5.zip)

Décompressez-le et placez NVDA Remote dans votre dossier Applications. L'application est signée et vérifiée par Apple. Désormais, elle vous préviendra elle-même de la prochaine bêta, puis de la version 1.0.
