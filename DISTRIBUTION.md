# Installer Nabaztag IA

Cette version nécessite un **Mac Apple Silicon (M1 ou plus récent), macOS 14 ou plus récent**, et un Nabaztag déjà opérationnel sous **Pynab avec une carte TagTagTag**. Le Mac et le lapin doivent être sur le même réseau ; ils doivent rester allumés pendant l'utilisation. Le DMG n'installe pas Pynab.

## Installer l'application

1. Télécharger le DMG depuis les [Releases GitHub](https://github.com/guidouil/nabaztag_IA/releases).
2. Ouvrir le DMG et glisser **Nabaztag IA.app** vers **Applications**.
3. Éjecter le DMG, puis ouvrir l'application dans Applications. Son icône apparaît dans la barre de menus ; elle n'ouvre pas de fenêtre principale.

Un fichier portant le suffixe **non-notarise** est un essai local de fabrication, pas la version publique validée par Apple.

## Connecter son lapin

Dans **Réglages → Connexion**, remplacer l'adresse et le login proposés par ceux de son propre lapin. Choisir **Mot de passe** et saisir son mot de passe SSH ; une clé SSH personnelle déjà configurée peut aussi être utilisée.

Cliquer sur **Vérifier l'empreinte SSH** et comparer l'empreinte affichée avec celle obtenue depuis une console ou une connexion déjà de confiance sur le lapin :

```sh
ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub
```

Si elles correspondent, cliquer sur **Faire confiance à cette empreinte**, puis confirmer. Enregistrer les réglages. Si macOS demande l'accès au réseau local ou au Trousseau pour l'assistant SSH, l'autoriser pour cette utilisation.

## Installer le relais sur le lapin

Dans Terminal sur le Mac, exécuter cette commande en remplaçant **pi@MON-LAPIN.local** par son propre login et son propre hôte SSH :

```sh
/bin/zsh "/Applications/Nabaztag IA.app/Contents/Resources/setup-radio.command" "pi@MON-LAPIN.local"
```

Malgré son nom, ce script installe le relais complet pour la voix, le bouton et la radio. Utiliser son accès SSH habituel avec les droits d'administration du lapin. Le script sauvegarde un relais existant avant son premier remplacement et ajoute `curl` et `mpg123` si nécessaire. Il exige un accès `sudo -n` sur le lapin ; si celui-ci est refusé, faire installer le relais par l'administrateur du lapin.

Pynab, Python 3, `arecord`, `aplay` et la carte audio `tagtagtagsound` doivent déjà fonctionner sur le lapin. Le script n'installe pas ces prérequis. Ne pas lancer le script sans indiquer sa propre cible SSH.

## Choisir la voix et l'IA

- Dans **Réglages → Voix**, commencer par **Thomas · macOS**. Si cette voix est absente, la télécharger dans les réglages vocaux de macOS. La voix Kokoro est optionnelle et demande une installation séparée.
- Dans **Réglages → IA**, choisir son fournisseur. Les connecteurs API utilisent sa propre clé et la facturation de son compte. Les modes par abonnement nécessitent l'installation et la connexion du CLI officiel correspondant ; aucun CLI ni abonnement IA n'est fourni dans le DMG. Pour ChatGPT, l'application attend Codex dans `/opt/homebrew/bin/codex`.
- Les instructions détaillées des fournisseurs et de Kokoro figurent dans le [README du projet](https://github.com/guidouil/nabaztag_IA#readme).

L'application est gratuite ; les services IA choisis peuvent être payants. Les mots de passe SSH et les clés API saisis sont conservés dans le Trousseau macOS. Les questions et le contexte de conversation sont transmis au fournisseur IA choisi. L'audio est transcrit localement par Apple Speech ; la reconnaissance vocale locale en français doit être disponible sur le Mac.

## Vérifier le fonctionnement

Cliquer sur **Vérifier**, puis **Diagnostic → Tester la voix**. Essayer une question saisie dans **Conversation**, puis **Parler au lapin**. Accepter la demande macOS de reconnaissance vocale et attendre le bip avant de parler. Un second clic court sur le bouton du lapin arrête l'enregistrement.

Pour signaler un problème, utiliser les [issues GitHub](https://github.com/guidouil/nabaztag_IA/issues) avec la version de l'app, de macOS et le message d'erreur. Retirer les mots de passe, clés API et informations personnelles des diagnostics partagés.
