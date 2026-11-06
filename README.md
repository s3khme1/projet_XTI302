# Projet XTI302-CYB – Durcissement d'un serveur Debian 13

Groupe : Charles Seny Yao, Kahina Alouache--Sainz, Gianni Laurent.

Contexte choisi : **A – Agence web Pixelia**.

| Groupe | Membres (comptes.csv) |
|---|---|
| admins | glaurent, cyao, kalouache |
| support | support |
| dev | jdupont, mpetit |
| design | lbernard, cmoreau |
| commercial | nrobert, sdurand |
| freelance | klambert, efontaine (expiration le 31/01/2027, pas de sudo) |

## Contenu du dépôt

```
installer.sh        reconstruit toute la configuration sur la VM vierge
creer_comptes.sh    comptes, groupes, /srv, ACL, clés SSH (lit comptes.csv)
analyse_logs.sh     rapport des connexions SSH, code de sortie 1 si alerte
sauvegarde.sh       sauvegarde incrémentale de /srv et /etc (versions datées)
verifier.sh         teste toutes les exigences, code 0 si tout est conforme
comptes.csv         comptes à créer
config/
  projet.conf               paramètres (disque de sauvegarde, date d'expiration...)
  droits.csv                droits des groupes métier sur /srv
  cles/*.pub                clés publiques des comptes de acces_ssh
  ssh/sshd_config.d/        durcissement SSH
  sudoers.d/                règles sudo
  fail2ban/jail.d/          prison sshd
  nftables.conf             pare-feu
  journald.conf.d/          journal persistant
  apt/apt.conf.d/           mises à jour automatiques
  systemd/                  service + timer de sauvegarde
  suid_autorises.txt        fichiers SUID attendus (D3)
DOSSIER.md          tableau de conformité, choix techniques, défense, restauration
```

## Prérequis

- VM Debian 13 minimale (sans interface graphique) avec le serveur SSH.
- Un second disque virtuel de 1 à 2 Go **vide** pour les sauvegardes. Vérifier son nom avec
  `lsblk` et l'indiquer dans `config/projet.conf` (`DISQUE_SAUVEGARDE`, `/dev/sdb` par défaut).
  `installer.sh` ne le formate que s'il ne contient aucun système de fichiers.
- La clé publique de chaque administrateur dans `config/cles/<login>.pub`.
  Pour `support`, une paire de clés de test a été générée : seule la clé publique est dans le dépôt.
- Accès console ou un compte avec sudo pour lancer l'installation la première fois.

## Installation

Depuis la VM (en root ou avec le compte créé à l'installation de Debian) :

```bash
apt install -y git
git clone <url du dépôt> projet && cd projet
sudo ./installer.sh
```

Le script demande un mot de passe pour chaque administrateur qui n'en a pas encore
(il ne sert qu'à sudo : la connexion SSH se fait uniquement par clé). Ensuite il verrouille root
et retire de sudo le compte créé à l'installation.

> Garder une session SSH ouverte pendant l'installation et tester la connexion
> `ssh glaurent@<ip>` dans un second terminal avant de fermer la première.

## Vérification

```bash
sudo ./verifier.sh
```

Chaque test affiche `[OK]` ou `[KO]` avec l'identifiant de l'exigence. Le code de sortie vaut 0
si tout est conforme. Le test incrémental (B1) a besoin d'au moins deux versions : lancer
`sudo systemctl start sauvegarde.service` une seconde fois si besoin.

## Utilisation courante

```bash
sudo /usr/local/sbin/analyse_logs.sh              # rapport des dernières 24 h, seuil 10
sudo /usr/local/sbin/analyse_logs.sh -s 5 -H 48   # seuil 5 échecs, 48 h
sudo fail2ban-client status sshd                  # IP bannies
sudo fail2ban-client set sshd unbanip <ip>        # débannir
sudo systemctl start sauvegarde.service           # sauvegarde manuelle
ls /sauvegardes/versions                          # versions disponibles
```

Tests depuis l'hôte :

```bash
ssh root@<ip>                                     # refusé
ssh -o PubkeyAuthentication=no glaurent@<ip>      # refusé (mot de passe interdit)
ssh -i ~/.ssh/projet-xti302/support support@<ip> sudo /usr/local/sbin/analyse_logs.sh
nmap -Pn <ip>                                     # seul 22/tcp ouvert
```
