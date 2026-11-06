# Dossier – Durcissement du serveur Pixelia

Contexte A (agence web Pixelia), Debian 13. Références : guide ANSSI-BP-028 v2
« Recommandations de configuration d'un système GNU/Linux » (noté **BP-028 Rxx**),
guide ANSSI « Usage sécurisé d'(Open)SSH » (noté **ANSSI SSH**) et guide d'hygiène informatique
de l'ANSSI (noté **Hygiène n°**).

## 1. Tableau de conformité

| ID | Ce qui est fait | Test(s) de verifier.sh | ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv`, crée les groupes absents puis les comptes (`useradd`), ou les met à jour (`usermod`) s'ils existent déjà. Relancé, il ne crée rien en double. Les freelance reçoivent une date d'expiration (`chage -E`). | `test_C1_comptes`, `test_C1_doublons`, `test_C1_freelance` | BP-028 R30, R33 |
| C2 | `/srv/projets`, `/srv/projets/externe`, `/srv/maquettes`, `/srv/clients` en `root:root 770`, `other::---`, une ACL par groupe métier et la même ACL en ACL par défaut. Les droits sont décrits dans `config/droits.csv`, lu à la fois par `creer_comptes.sh` et `verifier.sh`. | `test_C2_proprietes`, `test_C2_autorise`, `test_C2_refuse`, `test_C2_acl_defaut` | BP-028 R50 |
| C3 | `config/sudoers.d/10-projet` : `%admins ALL=(ALL:ALL) ALL`, `support` uniquement sur `/usr/local/sbin/analyse_logs.sh`. Fichier validé par `visudo -cf` avant copie. Le compte créé à l'installation est retiré du groupe `sudo`. | `test_C3_admins`, `test_C3_support`, `test_C3_autres`, `test_C3_syntaxe` | BP-028 R38, R39, R40 |
| C4 | `passwd -l root` (seulement si un admin a un mot de passe, sinon on perd l'accès à la machine), répertoires personnels en 700, `HOME_MODE 0700` et `UMASK 027` dans `login.defs`. | `test_C4_root`, `test_C4_homes`, `test_C4_homes_reel` | BP-028 R33, R36, R50 |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`. Clés installées dans `~/.ssh/authorized_keys` (600). | `test_S1`, `test_S1_cles` | ANSSI SSH (authentification par clé) |
| S2 | `PermitRootLogin no` | `test_S2` | ANSSI SSH, BP-028 R33 |
| S3 | `AllowGroups acces_ssh`, aucun utilisateur métier dans ce groupe | `test_S3`, `test_S3_metier` | ANSSI SSH (contrôle d'accès) |
| S4 | `MaxAuthTries 3`, `ChannelTimeout session=10m`, `ClientAliveInterval 300` × 2, plus `TMOUT=600` pour les shells | `test_S4_essais`, `test_S4_inactivite` | BP-028 R32 |
| S5 | `config/ssh/sshd_config.d/10-durcissement.conf` copié dans `/etc/ssh/sshd_config.d/`, `sshd -t` avant `systemctl reload ssh`. En cas d'erreur le fichier est retiré et ssh n'est pas rechargé. | `test_S5`, `test_S5_service` | – |
| J1 | Prison `sshd` (backend systemd, mode aggressive), 5 échecs en 10 min → 15 min de bannissement, durée doublée en cas de récidive (max 1 jour). Action `nftables`. | `test_J1_actif`, `test_J1_reglages` | BP-028 R79 |
| J2 | `config/nftables.conf` : politique `drop` en entrée et en transit, acceptés : connexions établies, `lo`, découverte des voisins IPv6, `tcp/22`. Service `nftables` activé au démarrage. | `test_J2_politique`, `test_J2_regles`, `test_J2_persistant`, `test_J2_fail2ban` | BP-028 R80, Hygiène n°23 |
| J3 | `Storage=persistent` dans `/etc/systemd/journald.conf.d/persistant.conf`, création de `/var/log/journal` | `test_J3` | BP-028 R71 |
| J4 | `analyse_logs.sh` lit journald, compte les échecs par IP et par compte et les connexions réussies. Code 1 si une IP atteint le seuil (`-s`, 10 par défaut), 2 si erreur d'utilisation. | `test_J4_droits`, `test_J4_alerte`, `test_J4_rapport` | BP-028 R71 |
| B1 | `sauvegarde.sh` : `rsync -aAXH --link-dest` vers `/sauvegardes/versions/AAAA-MM-JJ_HHMMSS`, 14 versions gardées. Disque formaté par `installer.sh` seulement s'il est vide, monté par UUID. | `test_B1_versions`, `test_B1_incremental`, `test_B1_acl` | Hygiène n°37 |
| B2 | `sauvegarde.timer` tous les jours à 2 h 30 (`Persistent=true`), journal dans `/var/log/sauvegarde.log` et journald (`logger`), rotation par logrotate | `test_B2` | Hygiène n°37 |
| B3 | `/sauvegardes` en `root:admins 750`, monté `nodev,nosuid,noexec` | `test_B3` | BP-028 R50 |
| B4 | Restauration testée (voir §4) | `test_B4` | Hygiène n°37 |
| D1 | `unattended-upgrades` + `20auto-upgrades`, timers apt activés | `test_D1` | BP-028 R61, Hygiène n°34 |
| D2 | Seul `sshd` écoute sur le réseau (vérifié avec `ss -tulnH`) | `test_D2` | BP-028 R62, R80 |
| D3 | Recherche des fichiers modifiables par tous et des SUID, liste blanche dans `config/suid_autorises.txt` | `test_D3_ecriture`, `test_D3_suid` | BP-028 R54, R56, R57 |

`verifier.sh` compte 43 tests.

## 2. Choix techniques

**Contexte A.** Pour donner à `freelance` l'accès à `/srv/projets/externe` sans lui donner
`/srv/projets`, le groupe a seulement le droit `--x` (traverser) sur `/srv/projets`, sans ACL par
défaut pour que ce droit ne se propage pas aux nouveaux sous-dossiers. Un freelance peut donc
entrer dans `externe` mais pas lister `projets`. Les comptes freelance expirent le 31/01/2027
(fin du semestre), valeur dans `config/projet.conf`.

**Pourquoi `root:root 770` + ACL ?** Le groupe propriétaire n'a aucun droit (`g::---`) : tous les
accès passent par des ACL nommées, ce qui évite qu'un groupe « oublié » hérite de droits. Le
masque est remis à `rwx`. Les ACL par défaut s'appliquent aux nouveaux fichiers même si
l'utilisateur a un umask restrictif (vérifié par `test_C2_acl_defaut` qui crée un fichier avec
`umask 077`).

**Répertoires personnels en 700.** Avec 750, un dev pourrait lire le répertoire d'un autre dev
puisqu'ils ont le même groupe principal.

**Mots de passe.** Aucun dans le dépôt. Les admins en définissent un pendant `installer.sh`, il
sert uniquement à sudo (on garde une authentification pour l'élévation de privilèges). Les
autres comptes n'ont pas de mot de passe : ils ne peuvent pas se connecter, ils servent à tester
les droits. Root n'est verrouillé qu'une fois qu'un admin a un mot de passe et une clé, sinon il
n'y aurait plus aucun moyen d'administrer la machine.

**sudo pour support.** La règle donne le chemin complet du script, en `NOPASSWD` car support n'a
pas de mot de passe. Le script est copié dans `/usr/local/sbin`, appartient à root et n'est pas
modifiable par un autre utilisateur : si support pouvait le modifier, il pourrait y mettre
n'importe quelle commande et l'exécuter en root. Dans le script : `PATH` fixé, options vérifiées
par expression régulière, aucun argument libre, et `journalctl --no-pager` (sinon `less` serait
ouvert en root et `!sh` donnerait un shell root, cf. GTFOBins). L'option `-i` lit l'entrée standard :
cela ne donne rien de plus à support que ce qu'il fournit lui-même. `Defaults use_pty` et un
journal `/var/log/sudo.log` complètent.

**SSH.** Fichier nommé `10-…` car sshd garde la première valeur lue : il passe avant d'éventuels
fichiers ajoutés par d'autres paquets. `MaxAuthTries 3` : avec des clés, un client légitime n'en
utilise qu'une ; 3 laisse de la marge si l'agent propose plusieurs clés. Pour l'inactivité,
`ClientAliveInterval` ne suffit pas (il détecte un client mort, pas un utilisateur inactif) :
on utilise `ChannelTimeout session=10m` (OpenSSH ≥ 9.2), plus `TMOUT=600` en lecture seule pour
les shells. 10 min laisse de la marge sous la limite de 15. Redirections et X11 désactivés :
inutiles sur ce serveur et utilisables pour contourner le pare-feu. `LogLevel VERBOSE` journalise
l'empreinte des clés utilisées.

**fail2ban.** 5 échecs en 10 min : une erreur de manipulation ne bannit pas, une attaque
automatisée oui. 15 min de bannissement au départ pour ne pas se bloquer trop longtemps soi-même
(débannir : `fail2ban-client set sshd unbanip <ip>`), puis `bantime.increment` double la durée à
chaque récidive. Backend `systemd` car Debian 13 n'a pas de `/var/log/auth.log`. Mode `aggressive`
pour compter aussi les comptes refusés par `AllowGroups` et les échecs de clé.

**nftables et fail2ban.** Le fichier ne contient pas `flush ruleset`, qui supprimerait aussi la
table `f2b-table` de fail2ban : on ne supprime que notre table (`table inet filtrage` puis
`delete table inet filtrage`). `installer.sh` utilise `reload` et pas `restart` (le `ExecStop` du
service fait un `flush ruleset`). Un drop-in `PartOf=nftables.service` redémarre fail2ban si
nftables est redémarré, pour qu'il recrée ses règles. Sont autorisés en plus de SSH : `lo`
(services locaux) et la découverte des voisins IPv6 (sinon IPv6 ne fonctionne pas). Le DHCP passe
par une socket brute qui n'est pas filtrée par nftables. La sortie reste ouverte (mises à jour, DNS).

**Journal.** `SystemMaxUse=300M`, `MaxRetentionSec=3month` : 3 mois couvrent une analyse
d'incident découvert tardivement sans remplir le disque système.

**Seuil d'alerte (analyse_logs.sh).** 10 échecs par IP sur 24 h : fail2ban bannit à 5, donc
dépasser 10 veut dire que l'IP est revenue après un bannissement, ce qui mérite qu'on regarde.
Modifiable par `-s` et `-H`.

**Sauvegarde.** `rsync -aAXH --numeric-ids` conserve droits, ACL, attributs étendus et liens
physiques. `--link-dest` vers la version précédente : un fichier inchangé est un lien physique,
il ne prend pas de place et n'est pas recopié. La version est écrite dans `.encours` puis renommée,
donc une sauvegarde interrompue ne devient jamais « la dernière ». 14 versions quotidiennes
(au moins 7 demandées) = deux semaines pour s'apercevoir d'une suppression ou d'un chiffrement.
`flock` empêche deux exécutions simultanées, et le script refuse de tourner si le disque n'est
pas monté (sinon il remplirait le disque système). Le disque est monté `nodev,nosuid,noexec` :
une copie d'un binaire SUID n'y est pas utilisable. `installer.sh` ne formate le disque que s'il
n'a aucun système de fichiers, et refuse un disque inconnu : le relancer ne détruit pas les
sauvegardes. Timer systemd plutôt que cron : `Persistent=true` rattrape une sauvegarde manquée si
la VM était éteinte, et la sortie va dans journald.

**D2.** Sur une Debian minimale, `ss -tulpn` montre `sshd` (22/tcp) et éventuellement le client
DHCP (68/udp, 546/udp en IPv6) : c'est un client, pas un service joignable, et nftables bloque
toute connexion entrante non sollicitée. Les écoutes sur `127.0.0.1` / `::1` ne sont pas
joignables depuis le réseau.

**D3.** La recherche exclut `/proc`, `/sys`, `/dev`, `/run` (systèmes de fichiers virtuels),
`/tmp` et `/var/tmp` (temporaires, avec sticky bit), et le disque de sauvegarde. `find` ne suit
pas les liens symboliques par défaut et on ne garde que les fichiers et dossiers réels. Fichiers
SUID présents :

| Fichier | Rôle |
|---|---|
| `passwd`, `chfn`, `chsh` | modifier son mot de passe / ses infos dans `/etc/shadow` et `/etc/passwd` |
| `gpasswd`, `newgrp` | gestion des groupes et changement de groupe courant |
| `su`, `sudo` | changement d'identité, nécessaire à l'administration |
| `mount`, `umount` | montage par un utilisateur des volumes marqués `user` dans fstab |
| `ssh-keysign` | authentification par hôte (non utilisée ici, installé avec openssh-client) |
| `dbus-daemon-launch-helper` | lancement de services D-Bus système |

Tout autre fichier SUID fait échouer `test_D3_suid`.

## 3. Défense

| Attaque | Ce qui la rend plus difficile |
|---|---|
| Force brute SSH | Mot de passe refusé : il faudrait deviner une clé. 3 essais par connexion, bannissement après 5 échecs, durée croissante. `analyse_logs.sh` signale les IP insistantes. |
| Vol du mot de passe d'un admin | Inutile seul : SSH n'accepte que les clés. Il faut la clé privée **et** le mot de passe pour devenir root. |
| Connexion directe en root | Root verrouillé et `PermitRootLogin no` : chaque action d'administration est faite par un compte nominatif et tracée (`/var/log/sudo.log`, journald). |
| Utilisateur curieux (ex : commercial) | ACL : il n'accède qu'à `/srv/clients` et en lecture à `/srv/maquettes`. Répertoires personnels en 700, sauvegardes réservées aux admins. |
| Compte support compromis | Il ne peut lancer que `analyse_logs.sh` en root, script non modifiable, sans pager ni argument libre. |
| Compte freelance après la mission | Expire automatiquement, pas de sudo, pas de SSH. |
| Suppression ou chiffrement de fichiers | 14 versions datées : on revient à l'état d'avant. |

**Ce qui n'est pas couvert :**

- la sauvegarde est sur la même machine : vol, panne de l'hôte ou rançongiciel avec accès root
  emportent aussi les sauvegardes (il faudrait une copie externe, règle 3-2-1) ;
- vol de la clé privée d'un admin non protégée par une phrase de passe (pas de MFA) ;
- une faille dans sshd lui-même, ou une mise à jour non encore publiée ;
- un admin malveillant : il a tous les droits ;
- la sortie réseau n'est pas filtrée (un logiciel malveillant pourrait exfiltrer des données) ;
- pas de détection d'intrusion ni de contrôle d'intégrité des fichiers (AIDE, auditd).

## 4. Procédure de restauration

Les sauvegardes sont dans `/sauvegardes/versions/<date>/` ; `/sauvegardes/derniere` pointe vers
la plus récente. Chaque version contient `srv/` et `etc/` complets.

1. Se connecter avec un compte admin et repérer les versions :
   ```bash
   sudo ls /sauvegardes/versions/
   ```
2. Trouver dans quelle version le fichier existe encore :
   ```bash
   sudo ls -l /sauvegardes/versions/*/srv/projets/site/index.html
   ```
3. Le restaurer en gardant droits et ACL (`-aAX`) :
   ```bash
   sudo rsync -aAX /sauvegardes/versions/2026-11-10_023012/srv/projets/site/index.html /srv/projets/site/
   ```
   Pour un dossier entier, mettre un `/` final aux deux chemins. Pour restaurer à côté sans écraser :
   indiquer une autre destination, par exemple `/srv/projets/site/index.html.restaure`.
4. Vérifier :
   ```bash
   getfacl /srv/projets/site/index.html
   sudo -u jdupont cat /srv/projets/site/index.html
   ```

Test réalisé : création de `/srv/projets/test_restauration.txt`, sauvegarde, suppression du
fichier, nouvelle sauvegarde (le fichier n'y est plus), puis restauration depuis la version
précédente avec la commande ci-dessus : contenu, propriétaire et ACL identiques à l'original.
`test_B4` refait automatiquement une restauration depuis la plus ancienne version dans un
dossier temporaire et vérifie que les ACL sont présentes.
