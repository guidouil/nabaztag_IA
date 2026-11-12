# Contrôle du Nabaztag — 11 novembre 2026

Contrôle effectué depuis le Mac, par SSH vers `pi@192.168.68.54`. Les heures sont celles de Paris.

## État observé

| Élément | Résultat |
| --- | --- |
| Pynab | Branche `release`, version `v1.0.2-53`, arbre Git propre |
| Révision Pynab | `9c5dc139038eb2fea1189232d9c56ad8e7c48ebd`, identique à `origin/release` vérifié avec `git ls-remote` |
| Système | Raspbian GNU/Linux 11 « bullseye » ; noyau `5.15.32+`, compilation de 2022 |
| Services | Services Nabaztag attendus actifs ; aucune unité systemd en échec |
| Interface web | Réponse HTTP 200 sur le port 80 |
| Température | 46 à 46,5 °C pendant le contrôle |
| Alimentation / limitation thermique | `vcgencmd get_throttled` : `0x0` |
| Stockage | Environ 51 Go libres sur la partition racine |
| Mémoire | 477 Mo de RAM ; environ 279 Mo de swap utilisés sur 355 Mo |
| Audio | Carte `tagtagtagsound` détectée pour l'entrée et la sortie |
| État matériel déclaré par Pynab | Oreilles gauche et droite `ok`, position `0` ; `rfid: true`, `sound_input: true` |

La révision de Pynab est à jour par rapport à la branche distante contrôlée. Cela ne signifie pas que tout le système Raspbian et son noyau sont récents. Aucune mise à niveau du système n'a été effectuée pendant ce contrôle.

L'utilisation du swap ne démontre pas une panne. Elle laisse toutefois peu de marge pour ajouter des traitements lourds sur le Pi ; le prototype exécute la transcription et l'agent IA sur le Mac.

## Journaux et essais

`mixerd` a redémarré huit fois au démarrage, avant que la carte son soit prête, puis est devenu actif à **13:53:21**. Ce démarrage transitoire ne justifie pas à lui seul un correctif ; aucune modification de ce service n'a été réalisée.

Une capture du microphone de trois secondes a produit un WAV de **96 044 octets**, conforme au format attendu de 16 kHz, mono, 16 bits. Un message de synthèse vocale a été envoyé et lu avec `aplay` sans erreur signalée. Cela valide les opérations logicielles de capture et de lecture ; une écoute humaine reste nécessaire pour confirmer le niveau sonore, l'intelligibilité et la qualité réelle du microphone.

La connexion Codex utilisant ChatGPT a répondu correctement à une question de contrôle (« deux plus deux »). Ce test confirme l'accès effectif de cette connexion à un modèle au moment de l'essai ; il ne mesure pas les quotas restants ni les performances sur une conversation prolongée.

Un essai acoustique a enregistré pendant six secondes une phrase synthétique diffusée par le haut-parleur du lapin. Le signal capté augmente nettement pendant la diffusion : les deux transducteurs répondent. Cet essai de proximité sature sur environ **6,36 %** des échantillons ; il ne permet donc pas de valider la qualité avec une voix humaine ni de conclure à un défaut du micro. L'enregistrement de test a été supprimé.

## Modifications effectuées

Installation du petit relais audio `/usr/local/lib/nabaztag-mac/bridge_remote.py` et ajout de la clé SSH dédiée à commandes limitées. Aucun service Pynab n'a été remplacé ou désactivé, et aucune mise à niveau du système n'a été lancée.

## Limites et confiance

Les tests matériels intégrés Pynab `ears` et `leds` ont ensuite renvoyé `status: ok`. Le test des oreilles effectue des mouvements et contrôle les capteurs de position ; le test LED exécute une séquence de couleurs sans capteur optique. Le résultat LED ne confirme donc pas visuellement chaque lumière. Le lecteur RFID est détecté, mais aucun badge n'a été présenté.

L'application Mac compilée s'ouvre, exécute son diagnostic et a traité une question écrite jusqu'à la lecture de la réponse sur le lapin. L'utilisateur a autorisé la reconnaissance vocale macOS. Une première connexion de l'application a échoué avec « No route to host », puis le diagnostic et la lecture ont fonctionné. La déclaration réseau local a été ajoutée à l'application.

Le premier essai parlé a renvoyé **« No speech detected »**. Un bip de début de capture a été ajouté pour rendre la fenêtre d'écoute explicite, sans changer les réglages du microphone. Au nouvel essai, avec la consigne de parler à 20–40 cm après le bip, l'utilisateur confirme que le lapin a répondu **« sept »**. L'interface affiche la transcription **« Combien font 4 + 3 »**, la réponse **« Quatre plus trois font sept »**, puis l'état **Prêt**. La chaîne microphone → transcription française locale → Codex connecté à ChatGPT → haut-parleur est donc validée sur cet essai court.

Les seize tests Python du relais et les contrôles Swift des processus, de la transcription, des événements bouton, des réglages SSH, des empreintes, des préférences et des formats API ont réussi. L'application 0.2 a été compilée et sa signature locale vérifiée.

## Application configurable

Les réglages SSH et IA sont affichés et les modes clé/mot de passe ainsi que les cinq choix IA ont été vérifiés dans l'interface. Les secrets sont confiés au Trousseau macOS et les préférences sans secrets sont persistées. Le nom `nabaztag-609.local` a été résolu depuis le Mac vers `192.168.68.54`.

La souscription SSH aux événements du bouton a renvoyé `ready` sur ce lapin, et sa fermeture par EOF a terminé le relais proprement. L'application affiche **Bouton du lapin connecté**. Après le test physique, l'interface affiche la question **« Combien font 5 + 6 »**, la réponse **« Cinq plus six font onze »**, puis une seconde demande d'histoire avec sa réponse complète et l'état **Prêt**. Le déclenchement par bouton et la chaîne vocale sont donc validés sur ces essais.

L'utilisateur a ensuite signalé un plantage. L'application avait été fermée et relancée par l'agent pour installer la dernière version pendant la validation. Aucun rapport de crash Nabaztag n'a été trouvé ; le processus courant est vivant et un échantillon du thread principal montre une attente normale d'événements. L'interface a ensuite affiché les deux réponses et l'état Prêt. Aucune panne technique supplémentaire n'est établie et aucun correctif spéculatif n'a été ajouté. La stabilité sur une longue durée reste à vérifier.

Les connecteurs Claude, Grok, Gemini et Chat Completions compatible OpenAI sont vérifiés par requêtes et réponses de référence, sans appels réels ni clés API. L'authentification SSH par mot de passe, son stockage effectif et la première autorisation du Trousseau de l'assistant SSH n'ont pas encore été testés avec le compte réel. Le mode clé existant est conservé par défaut. Whisper est reporté à la demande de l'utilisateur : la transcription Apple actuelle est déjà locale et sans tokens.

## Version 0.3 : voix locale et icône

À la demande de l'utilisateur, Kokoro MLX a été installé dans un environnement Python 3.12 isolé, sous `~/Library/Application Support/NabaztagIA/Voice`. L'environnement occupe environ 551 Mio et les trois fichiers du modèle environ 313 Mio. Les 67 versions de dépendances sont épinglées ; aucun paquet global n'a été installé. Le modèle est `mlx-community/Kokoro-82M-bf16`, révision `a71e4d38b236d968966a2002c4c895dbd12b1c3c`, voix française féminine `ff_siwis`.

Une première génération hors ligne a produit 6,825 secondes de WAV PCM16 mono 24 kHz en 4,788 secondes, avec environ 2,20 Go de pic mémoire MLX. Le helper final embarqué a ensuite produit 7,38 secondes d'audio en environ 2,3 secondes. Les réponses vocales sont générées avec les téléchargements Hugging Face désactivés, puis converties en WAV 22 050 Hz mono pour le lapin. Cette synthèse n'utilise aucune API ni token ; les requêtes au fournisseur IA restent indépendantes.

Le choix `kokoro` a été enregistré dans les préférences de l'application. L'interface affiche Siwis dans les réglages et conserve Thomas comme autre choix. Le bouton **Tester la voix** a terminé son essai sur le lapin sans erreur, avec l'état **Test de la voix terminé — Bouton du lapin connecté**. La qualité subjective reste à juger à l'écoute.

L'image fournie par l'utilisateur a été convertie en icône macOS `.icns`, avec dix variantes de 16 à 1 024 pixels, sans recadrage ni retouche. Le fichier embarqué est identique à l'asset validé et référencé par `CFBundleIconFile`. Compilation, signature locale, contrôle plist, vingt-trois tests Python et contrôles Swift réussis. Le script de compilation refuse désormais toute modification si l'application est ouverte.

## Version 0.4 : oreilles, lumières et Dock

Les réponses et le test de voix utilisent désormais `play-animated` lorsque le réglage commun **Animer les oreilles et les lumières** est actif. Ce réglage est activé par défaut, y compris après lecture des anciennes préférences, et sa désactivation est persistée. Le mode `play` conserve la lecture sans chorégraphie ; le micro et le bip restent sans effets ajoutés.

Une chorégraphie Pynab finie alterne des mouvements relatifs d'un pas vers l'arrière, compensés par le retour d'un pas vers l'avant. Les trois LED du ventre sont allumées en cyan faible, RGB 0/40/56. En fin de lecture, l'annulation et la réponse terminale sont attendues avant libération de la réservation ; les erreurs ALSA restent propagées.

Le test réel de lecture a montré les positions gauche/droite alterner entre 0 et 16 (16 représente ici le pas précédent dans le cycle de 17 positions), puis revenir à **0/0** en état **idle**. L'interface a affiché **Test de la voix terminé — Bouton du lapin connecté** et aucun nouveau message d'erreur nabd n'a été journalisé. Trente tests Python et les contrôles Swift ont réussi. L'affichage exact des LED n'a pas été mesuré par capteur optique ; le pilotage a été vérifié dans la séquence et sans erreur du démon.

Pour le Dock, le paquet possédait la bonne icône mais son enregistrement LaunchServices conservait une date ancienne. La compilation actualise maintenant la date du paquet et le réenregistre ; l'application charge aussi explicitement son icône au démarrage. L'utilisateur a confirmé **« Oui, c'est la bonne icône »** après le redémarrage.

Limites : animation à rythme fixe, sans synchronisation syllabique ; pas de test d'endurance. En cas de rupture de la connexion locale au démon pendant une animation déjà lancée, Pynab peut continuer sa séquence finie avant de s'arrêter. Aucun changement de calibrage ni du démon Pynab n'a été effectué.

## Version 0.5 : réglages indépendants des animations

Les oreilles proposent **Aucun / Petits / Grands**, avec des amplitudes relatives d'un ou trois pas. Les lumières proposent **Éteintes / Couleur fixe / Multicolore aléatoire**. La couleur fixe passe par le sélecteur natif macOS ; le mode aléatoire renouvelle trois couleurs distinctes d'une palette de six teintes environ toutes les 1,2 seconde. Le canal RGB le plus élevé est limité à 64/255 en préservant les proportions. Les anciennes préférences restent compatibles : une désactivation commune conserve les deux effets désactivés ; sinon les choix initiaux restent Petits et cyan fixe.

La commande SSH paramétrée accepte uniquement les trois modes d'oreilles, les trois modes de lumière et six chiffres hexadécimaux ASCII. Les anciennes commandes restent acceptées. Les neuf combinaisons et les migrations ont été vérifiées ; Aucun/Éteintes n'envoie aucune chorégraphie, et chacun des modes désactivés n'ajoute aucun opcode de son type.

La relecture a identifié qu'une annulation au milieu d'un mouvement pouvait provoquer un éclairage cyan de repositionnement par Pynab, même avec les effets lumineux désactivés. Après une lecture réussie, le relais attend maintenant la réponse terminale naturelle de la séquence compensée avant de libérer la réservation. L'annulation reste utilisée après une erreur audio. Cela peut prolonger brièvement l'opération après la parole. Le voyant de statut normal de Pynab reste indépendant de ces réglages.

L'application compilée a affiché les menus et conservé Grands/Multicolore aléatoire après enregistrement puis réouverture des réglages. Le test de voix a terminé sans erreur ; les positions observées des deux oreilles ont atteint 14 (trois pas derrière 0), puis sont revenues à 0/0 en état idle. Un second essai réel, avec le relais corrigé, Grands/Éteintes et une connexion par la clé restreinte, a confirmé un retour naturel à 0/0 et un code de sortie nul. Un essai Aucun/Couleur fixe orange a aussi terminé sans erreur. Aucun avertissement ni erreur nabd n'a été journalisé pendant ces essais.

Trente-six tests Python, les six contrôles Swift et le contrôle du contexte ont réussi. La signature locale et le plist de l'application ont été vérifiés. L'utilisateur a confirmé l'ouverture du sélecteur natif et la possibilité de choisir une couleur ; le choix vert RGB 0/250/146 a été enregistré avec les grands mouvements. Le rendu visuel exact des LED n'a pas été mesuré. Aucun test d'endurance n'a été effectué.

**Confiance élevée** sur l'accès réseau, les services, les mesures système, Pynab et la chaîne vocale sur une question courte. La qualité à distance, dans le bruit, lors d'une conversation prolongée, le RFID avec un vrai badge et le contrôle visuel de chaque LED restent à vérifier. Aucun changement de version du système n'est justifié par les seuls résultats observés ici.

## Version 0.6 : Claude Code par abonnement

Le fournisseur **Claude · abonnement Claude Code** utilise le CLI officiel, indépendamment de **Claude · API**. La connexion reste gérée par Claude Code ; le relais de l'application exige un statut `loggedIn: true` et `authMethod: claude.ai`, sans lire ses fichiers d'identifiants. L'environnement hérité exclut les clés API et fournisseurs cloud ; le mode sûr désactive les personnalisations utilisateur et projet, tout en respectant l'éventuelle politique gérée du CLI. La requête passe par stdin dans un répertoire temporaire privé, avec outils et MCP désactivés et sans conservation de session demandée au CLI. Les erreurs JSON sont traitées même avec un code de sortie non nul, et aucun repli vers notre connecteur API n'est effectué. Les éventuels crédits ou dépassements activés sur le compte Claude restent régis par ce compte.

Claude Code **2.1.311** a été installé avec le cask officiel Homebrew, à `/opt/homebrew/bin/claude`. Ses options ont été comparées à l'aide du binaire installé. Le contrôle réel d'authentification isolé a renvoyé `loggedIn: false`, `authMethod: none` ; le diagnostic de l'application indique la connexion à effectuer dans Terminal. Aucun appel au modèle Claude n'a donc été réalisé pendant cette validation.

Les trente-six tests Python et les sept contrôles Swift ont réussi, dont un faux CLI local qui exerce le vrai sous-processus, le refus d'une authentification API avant la requête, le transport littéral de stdin, les erreurs et le nettoyage des fichiers temporaires. Les compilations Xcode Debug et Release ainsi que build.command ont réussi. Les trois paquets 0.6 ont passé la vérification de signature, des six ressources et de l'autocontrôle du contexte. L'interface montre le choix Claude par abonnement, le statut installé et les instructions de connexion, sans champs de clé API. Après vérification, l'app est prête avec son bouton connecté.

La recherche officielle xAI distingue **Grok Build**, CLI scriptable compatible avec une connexion par abonnement, de **Grok Bot**, produit cloud dont le webhook de routine démarre une tâche et rend le résultat dans son chat. Aucune API publique de réponse conversationnelle synchrone de Grok Bot n'a été trouvée dans les documents contrôlés. Le connecteur Grok API existant est conservé ; aucun connecteur Build ou Bot supplémentaire n'a été installé. Les sources et les limites sont consignées dans README.md.

Confiance élevée sur l'intégration et les contrôles locaux. La réponse réelle avec un compte Claude éligible, ses quotas et les éventuels crédits supplémentaires restent à vérifier après connexion de l'utilisateur.

## Version 0.7 : SuperGrok, icône transparente et audio progressif

Le choix **Grok · abonnement Grok Build** est ajouté, séparément de Grok API. Le CLI officiel 1.0.77 est installé dans `~/.grok/bin/grok`. L'application emploie une configuration temporaire, refuse l'authentification API et vérifie son isolation avant de lancer une requête. Le CLI officiel conserve et renouvelle ses propres identifiants ; Swift ne lit ni ne copie les jetons. Le symbole `@` reste refusé pour éviter l'expansion implicite de fichiers du CLI. Les tests avec un faux CLI et le diagnostic réel de configuration ont réussi. L'utilisateur a reporté son essai Claude ; aucun compte Claude ou SuperGrok connecté n'a été utilisé pour une réponse réelle.

Le blanc extérieur de l'icône a été remplacé par de la transparence avec ImageGen, puis les dix tailles ICNS ont été générées avec sips/iconutil. Les coins et milieux des bords ont un alpha nul ; le lapin blanc intérieur reste présent. Le dessin est conservé visuellement, sans garantie d'identité pixel par pixel après retouche générative. Les trois paquets compilés embarquent le même ICNS.

Pour Kokoro, un worker Python lié à l'application charge le modèle une fois et effectue une courte synthèse silencieuse avant son signal ready. Les phrases sont générées puis envoyées progressivement en PCM signé 16 bits little-endian, mono 24 kHz, dans une seule session SSH. Le Pi lit via aplay avant EOF, sous une réservation Pynab unique ; les effets suivent des cycles courts compensés. Le SSH démarre au premier fragment disponible, ce qui évite de réserver le lapin pendant le chargement du modèle. Thomas/macOS conserve la voie WAV complète.

Les limites restent 2 000 caractères et 90 secondes. Le worker et le transport appliquent contrepression, délais et annulation ; l'arrêt de l'app termine les processus audio. Les tests ont notamment révélé puis couvert un blocage de lecture de Pipe, un lecteur SSH vivant qui n'absorbe plus de données et une fermeture concurrente des handles. Les écritures sont maintenant non bloquantes et bornées, SIGPIPE est neutralisé sur le Pipe, et les lecteurs conservent leur handle jusqu'à leur retour.

Mesures locales du 11 novembre 2026, même texte de trois phrases : ancien processus, 2,400 s avant disponibilité du WAV complet (9,875 s d'audio). Nouveau worker prêt en 1,129 s, synthèse silencieuse comprise ; premier fragment disponible en 0,194 / 0,166 / 0,169 s sur trois requêtes, totalité générée en 0,710 / 0,663 / 0,658 s, pour 10,825 s d'audio. Le découpage modifie aussi les pauses et donc la durée. Ces délais excluent l'attente de l'IA, SSH et l'acoustique. Le texte IA complet est encore attendu avant le démarrage de cette synthèse audio : il ne s'agit pas d'un streaming des tokens IA.

Deux essais complets sur le Pi ont terminé en 17,57 s puis 15,14 s, lecture de 10,825 s incluse. Un premier essai avait atteint son délai de fin SSH ; des retransmissions TCP et un RTO temporaire de 10,2 s ont été observés, puis le RTO est revenu à 230 ms. Le Pi était peu chargé, sans limitation électrique, et le signal Wi-Fi fort. La comparaison avec IPQoS=none ne permet pas d'attribuer causalement l'écart à ce réglage ; aucun changement permanent de QoS, MTU ou réseau n'a été appliqué.

La chaîne réelle depuis l'application a ensuite traité des questions de l'utilisateur, lu les réponses et retrouvé l'état **Prêt — Bouton du lapin connecté**. Pendant cette lecture progressive, les oreilles ont atteint la position 14 puis sont revenues à 0/0 en état idle ; aucun avertissement nabd n'a été journalisé sur ce contrôle. Le processus Kokoro reste unique et chargé entre les demandes.

Quarante-neuf tests Python, dix contrôles Swift et l'autocontrôle du contexte ont réussi. Les compilations classiques et Xcode Debug/Release 0.7, les signatures et la présence des six ressources ont été vérifiées. Le nouveau relais a été déployé atomiquement et sa syntaxe vérifiée par Python 3.9 sur le Pi ; empreinte SHA256 `f4fba24db2e182bb2f4ae23149ca9163207e3c6032421d16340d4b3ec694ada8`.

Confiance élevée sur le fonctionnement et les mesures observés. La stabilité longue durée, les comptes Claude/SuperGrok réels et la cause exacte des irrégularités SSH restent à vérifier.

## Version 0.8 : conversation masquée et réflexion légère

La transcription et les réponses sont dans un panneau **Afficher la conversation**, fermé par défaut à chaque lancement. Le panneau n'est pas ouvert automatiquement par une nouvelle question. L'historique interne et le contexte des six derniers échanges sont conservés pendant la session.

Le mode ChatGPT fixe `gpt-6-luna`, `model_reasoning_effort = "low"` et une réponse concise. Le catalogue local de Codex 0.165.0 annonce `low` comme effort minimal pour Luna ; il n'annonce pas `none`. Le service standard et la désactivation de Fast sont explicites. L'application conserve la connexion ChatGPT et ses gardes d'isolation ; aucun changement global du CLI ni accès API n'est ajouté.

Deux contrôles courts via l'abonnement ont renvoyé une réponse correcte : GPT-6 Luna/low en 3,346 s et GPT-6.1 Terra/low en 3,175 s, avec zéro token de raisonnement déclaré sur ces requêtes. La vérification de connexion séparée a pris 0,135 s. Un seul échantillon de chaque modèle ne permet pas de classer leur vitesse ; Luna est retenu pour son positionnement efficient et les questions orales simples. Zéro token observé sur ces questions ne garantit pas zéro raisonnement sur les suivantes.

Claude Code et Grok Build demandent l'effort `low`, sans changer leur modèle natif. Les paramètres API sont limités aux identifiants par défaut connus : Haiku 5.5, réflexion désactivée et effort low ; Grok 4.7, low ; Gemini 3.8 Flash, low. Les modèles personnalisés conservent leurs paramètres propres. Les documentations officielles liées dans README.md ont été vérifiées ; Grok 4.7 et Gemini 3.8 Flash ne proposent pas de mode complètement sans réflexion.

La capture fixe de six secondes, la transcription, l'attente du texte complet et SSH restent des étapes distinctes. Ces changements ne justifient donc pas de promettre une réponse instantanée ni un délai total constant.

Validation : quarante-neuf tests Python, dix contrôles Swift et l'autocontrôle du contexte passent. Les compilations classique, Xcode Debug et Release, leurs signatures, versions 0.8, six ressources et icônes identiques sont vérifiées. Une inspection native de Grok Build 1.0.77 accepte les nouvelles politiques avec effort low et valide leur isolation, sans appel au modèle ; l'effort effectif n'est pas exposé par ce diagnostic.

Dans l'application 0.8, une question saisie « Combien font huit plus neuf ? » a produit « Huit plus neuf font dix-sept. » et terminé la lecture sur le lapin sans erreur. La conversation est restée fermée pendant l'opération ; elle affiche correctement la réponse après ouverture manuelle. Après fermeture du panneau, les textes des échanges disparaissent aussi de l'arbre d'accessibilité. L'application est laissée en état Prêt avec bouton connecté et conversation masquée. Aucun chronométrage acoustique ni nouvel essai du micro n'a été effectué sur cette version.

Confiance élevée sur le masquage, la sélection de modèle et les paramètres transmis. Les comptes Claude/SuperGrok et les API externes restent non testés par une réponse réelle ; le délai complet micro vers haut-parleur dépend encore du réseau et de la question.

## Version 0.9 : texte à lire directement

Le champ **Faire dire au lapin** et le bouton **Lire** appellent directement `Bridge.speak`, sans requête IA et sans insertion dans l'historique. Ils réutilisent la voix et les effets configurés. Le texte reste disponible après lecture et en cas d'erreur. Le bouton est désactivé pour un champ vide ou composé d'espaces ; toutes les commandes vocales utilisent le verrou d'opération existant.

Les compilations classique et Xcode Debug/Release ont réussi ; leurs versions, signatures, README, icônes et autocontrôles du contexte ont été vérifiés. Aucun nouveau moteur ni protocole n'est ajouté. L'interface native affiche le nouveau champ et garde Lire désactivé avec trois espaces. La phrase « Bonjour ! Je lis directement le texte que tu écris. » a été saisie avec ses accents puis envoyée par ce bouton : les commandes sont désactivées pendant la lecture, l'application retrouve Prêt avec bouton connecté sans erreur, et le texte est conservé. Le panneau de conversation reste fermé.

Confiance élevée sur le chemin de lecture directe. Pas de nouveau test de longue durée ni d'écoute acoustique indépendante ; les limites existantes de Kokoro restent 2 000 scalaires Unicode et 90 secondes d'audio. La suite backend complète de la version 0.8 n'a pas été relancée, ces sources étant inchangées.

## Version 0.10 : file audio, bouton à deux appuis et réflexion

Kokoro transmet désormais des segments PCM précédés d'une longueur de quatre octets. Le relais `play-queue` reçoit chaque segment en entier, précharge deux segments (ou attend l'EOF pour une réponse d'un seul segment), puis fournit toute la file dans l'ordre à un unique lecteur. La réception continue pendant la lecture, avec des bornes de 90 secondes de PCM et de 2 000 segments. Les longues phrases privilégient les ponctuations de proposition avant une coupure entre mots ; la borne de 200 caractères reste nécessaire pour Kokoro. L'ancien `play-stream` brut reste accepté.

Le premier appui court ou le bouton **Parler** démarre la capture. Le second appui est traité directement par le relais du lapin et termine l'enregistrement ; **Arrêter l’enregistrement** envoie la même demande depuis le Mac. La capture possède un plafond de sécurité de 90 secondes. L'EOF sans commande d'arrêt annule la capture. Les WAV, erreurs ALSA et nettoyages restent contrôlés, y compris le code de sortie 1 normal d'`arecord -q` après SIGINT.

Pendant l'attente du fournisseur IA, `think forward|backward` fait tourner les deux oreilles en sens opposés par cycles finis d'un tour de 17 pas relatifs. Le sens initial s'inverse à chaque question pendant la session. Le relais attend la fin du tour avant de libérer la réservation et de commencer la parole. La chaîne opcode → déplacement relatif a été vérifiée dans les sources Pynab à la révision installée et le pilote officiel ; ce déplacement relatif ne réduit pas 17 à zéro.

Validation locale : 59 tests Python, dix contrôles Swift et l'autocontrôle du contexte passent. La compilation complète, le plist 0.10, la signature et les ressources du paquet installé sont vérifiés. Le relais a été installé par l'utilisateur avec son accès SSH administrateur, après contrôle syntaxique et avec sauvegarde ; empreinte SHA256 `c1f0df687ed7d7cac9b446ae1df86f844457767e6a7652f3337d28993867d0ab`.

Essais matériels des commandes : une capture arrêtée par commande a renvoyé 8 044 octets de WAV mono 16 kHz valide, soit 0,25 seconde, et l'audio n'a pas été conservé. Les deux sens de réflexion ont terminé sans erreur. Après fermeture de l'entrée, la fin du mouvement et de la commande a pris 4,233 s puis 3,575 s ; ces délais incluent le transport et ne mesurent pas uniquement la rotation physique.

Le transport reste un point distinct : quatre lectures de 6,825 s ont terminé en 10,48 à 26,14 s, mais plusieurs transferts du même audio de 15,325 s ont expiré avec « server not responding ». Le bridage à 64 Kio/s, la suppression des effets et un essai sans marquage QoS n'ont pas corrigé ces expirations. Aucun réglage réseau permanent, pacing ou changement de QoS n'a donc été ajouté. Des pings ont montré des retours en 2,9 à 5,4 secondes et des pertes. Après redémarrage effectué par l'utilisateur, le relevé à deux minutes de démarrage indique une charge moyenne système de 9,17 / 4,88 / 1,92 ; il ne suffit pas à identifier la cause du problème réseau. Un nouvel essai du même texte de trois phrases depuis l'application 0.10 a ensuite terminé sans erreur et retrouvé **Prêt — Bouton du lapin connecté**. Cela confirme une lecture complète sur cet essai, pas la stabilité du réseau dans la durée.

L'utilisateur a ensuite répondu **« oui »** à la validation de l'arrêt au second appui, des mouvements opposés avec inversion à la demande suivante et de la lecture. L'application est laissée en état **Prêt — Bouton du lapin connecté**, conversation masquée. Confiance élevée sur les comportements vérifiés ; aucun test d'endurance ni identification de la cause réseau n'a été réalisé.

## Version 0.11 : météo mondiale

Les demandes météo utilisent désormais un protocole JSON commun aux fournisseurs IA. Le modèle indique uniquement le lieu, éventuellement son pays, et un jour relatif ; le Mac consulte les endpoints HTTPS fixes Open-Meteo de géocodage puis de prévision. Les réponses ordinaires restent à un seul appel IA. La réponse météo est formulée directement à partir des données reçues, avec le lieu résolu, les unités et l'heure locale, sans second appel au modèle ni accès général au Web. Les oreilles restent actives pendant la consultation.

Le service fournit les conditions actuelles modélisées et sept journées de prévisions, aujourd'hui compris. Il contrôle les coordonnées, unités, données nulles, fraîcheur et dates locales, y compris un changement d'heure de 25 heures. Les homonymes comparables donnent une demande de précision ; le choix des homonymes célèbres utilise le classement du géocodeur et un seuil de population documenté. Aucun GPS implicite n'est employé ; la conversation et l'audio ne sont pas envoyés au fournisseur météo. Open-Meteo, GeoNames et CC BY 4.0 sont attribués par des liens dans les réponses affichées et dans README.md. Aucune dépendance ni modification du relais Pi n'a été nécessaire.

Validation : 59 tests Python, onze contrôles Swift et l'autocontrôle du contexte passent. Le projet Xcode Debug compile, et le paquet 0.11 installé passe les contrôles de signature et de plist. Les tests météo emploient des réponses HTTP simulées et vérifient les erreurs ; six consultations réelles, actuel et lendemain pour New York, Tokyo et Sydney, ont également réussi. Les réponses machine météo mal formées sont rejetées plutôt que prononcées.

Dans l'application avec ChatGPT, **« Quelle est la météo à New York maintenant ? »** a produit des conditions Open-Meteo à l'heure locale, avec température, ressenti et vent, puis achevé la lecture. Une demande vocale de région imprécise a donné une demande de clarification ; la précision **« Quel temps fera-t-il demain à Tours »** a ensuite obtenu une prévision pour Tours, Centre-Val de Loire, France, jeudi 12 novembre, avec minimum, maximum et probabilité de précipitations. L'application est revenue à **Prêt — Bouton du lapin connecté** sans erreur. La conversation a été ouverte pour contrôler les réponses et les liens de source.

Confiance élevée sur le parcours ChatGPT testé et sur les contrôles locaux du service. Les autres fournisseurs n'ont pas été essayés en réel pour leur respect du protocole météo ; la disponibilité du fournisseur, la précision des modèles météo et la stabilité longue durée du réseau restent externes à ces essais.

## Version 0.12 : actualités France, internationales et haute technologie

Le protocole JSON commun aux fournisseurs accepte désormais `news`, avec les catégories `france`, `international`, `technology` et `all`. Le Mac consulte les flux HTTPS fixes France 24 — France, Le Monde — International et Le Monde — Technologies. Une rubrique lit jusqu'à trois titres ; le bulletin général lit un titre par rubrique. Les titres sont formulés directement à partir des flux, sans second appel IA, sans recherche Web générale et sans téléchargement des articles. Aucune clé supplémentaire, dépendance ou modification du relais Pi n'est ajoutée.

La source et la date de publication de chaque titre sont annoncées dans le fuseau du Mac. Seuls les articles datés de moins de 72 heures sont retenus, avec une tolérance de cinq minutes dans le futur. Le service trie et dédoublonne les titres, borne leur longueur pour la voix, refuse les redirections et les déclarations XML d'entités, et désactive leur résolution externe. Les erreurs et l'absence de titres récents sont annoncées ; une rubrique indisponible ne supprime pas les autres rubriques du bulletin général. Les requêtes n'envoient ni conversation ni audio aux éditeurs.

Validation : 59 tests Python, douze contrôles Swift et l'autocontrôle du contexte passent. Les contrôles couvrent notamment le routage des deux services, les catégories inconnues et commandes mal formées, les dates RSS GMT et numériques, la fraîcheur, l'ordre, les doublons, les réponses invalides et les pannes partielles. Quatre bulletins réels ont réussi via URLSession : France, international, technologie et général. Les compilations classique et Xcode Debug ont réussi ; la version 0.12 du paquet principal, sa signature et son autocontrôle ont été vérifiés.

Dans l'application avec ChatGPT, la demande saisie « Donne-moi les dernières nouvelles en France, à l'international et en haute technologie » a obtenu les trois rubriques avec leurs sources et dates, puis terminé la lecture sans erreur et retrouvé **Prêt — Bouton du lapin connecté**. Le titre technologique datait explicitement de la veille, sans être présenté comme publié le jour même. Confiance élevée sur ce parcours et les contrôles du service. Les autres fournisseurs, un nouvel essai au microphone, l'écoute acoustique indépendante et l'endurance restent non vérifiés ; l'actualisation et la disponibilité des flux dépendent des éditeurs.

## Mouvements natifs pendant les réponses — 12 novembre 2026

Le menu Aucun/Petits/Grands est remplacé par un interrupteur. Les anciennes valeurs Petits et Grands sont décodées comme activé, sans modifier les autres préférences. Le relais accepte `on` et conserve `small` et `large` comme alias de compatibilité du même mouvement.

La référence est `ChoreographyInterpreter.play_streaming` de Pynab à la révision `9c5dc139038eb2fea1189232d9c56ad8e7c48ebd`, toujours déclarée par le lapin. Les messages natifs emploient cette animation par défaut dans `NabIO.play_message`. Elle choisit initialement `(0,10)` ou `(10,0)`, puis des positions absolues parmi `0,5,10,14`, toujours en sens avant. Les décisions suivantes utilisent une probabilité cyclique et les durées des quatre chorégraphies streaming : `70,45,72,63` ticks, tempo de 160 à 250 ms, 3 à 20 boucles. Une réponse courte garde normalement sa pose initiale. Il ne s'agit donc pas d'un demi-tour alterné à rythme fixe. Sources : [interpréteur natif](https://github.com/nabaztag2018/pynab/blob/9c5dc139038eb2fea1189232d9c56ad8e7c48ebd/nabd/choreography.py#L350), [lecture des messages](https://github.com/nabaztag2018/pynab/blob/9c5dc139038eb2fea1189232d9c56ad8e7c48ebd/nabd/nabio.py#L241).

Le relais reprend cette logique avec l'opcode MTL 8 et conserve son état entre les cycles courts du flux audio. Les lumières restent indépendantes ; l'URN natif complet aurait imposé aussi son animation lumineuse. La précision temporelle est de 10 ms, avec un petit délai entre les commandes de streaming ; les durées de référence devront être revérifiées si Pynab les modifie. La restauration finale est confiée à Pynab.

Validation : les 60 tests Python, les douze contrôles Swift et l'autocontrôle du contexte passent. La compilation et la signature du paquet installé sont vérifiées. L'interface affiche un seul interrupteur actif et conserve les lumières multicolores ; l'enregistrement persiste `earMotion: on`. Le relais a été installé par l'utilisateur avec son accès SSH d'administration : ses empreintes SHA-256 locale et distante correspondent (`5eea9466aa234f936c825f0c2fc4974ca6e65b63c0df68003243c620c5e24a7d`). Le test de voix depuis l'application s'est terminé sans erreur, bouton connecté ; le diagnostic suivant a retrouvé l'état idle et les deux oreilles à zéro.

Un essai matériel supplémentaire de huit secondes avec oreilles activées et effets lumineux désactivés a observé la pose gauche/droite `10/0` pendant la lecture, puis `0/0` en état idle après sa fin, sans erreur de transport. Confiance élevée sur la logique et ces contrôles ; le rendu visuel par l'utilisateur, les changements aléatoires d'une réponse longue et l'endurance restent non évalués sur le matériel.
