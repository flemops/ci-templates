#!/bin/bash
# Pose (ou remet à jour) le script générique + les unités template du
# déploiement continu. Ne touche à AUCUNE conf .conf existante, et n'active
# aucune app : l'activation par app se fait séparément
# (`systemctl enable --now app-pull@<app>.timer`), une fois sa
# /etc/app-deploy/<app>.conf en place.
#
#   sudo bash deploy/cd/install.sh
#
# Idempotent : relançable à chaque fois que app-pull.sh ou les unités
# changent dans ce dépôt.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
  echo "À lancer avec sudo." >&2
  exit 1
fi

echo "==> Script de déploiement générique"
# Passe par un fichier temporaire + rename (atomique, même filesystem) :
# app-pull.sh peut être en cours d'exécution (systemd, appelé par son
# propre timer) au moment d'un install.sh relancé pour une mise à jour ;
# bash relit son script par offset pendant l'exécution.
TMP_SCRIPT="$(mktemp /usr/local/bin/.app-pull.sh.XXXXXX)"
install -o root -g root -m 700 "$SRC/app-pull.sh" "$TMP_SCRIPT"
mv -f "$TMP_SCRIPT" /usr/local/bin/app-pull.sh

echo "==> Unités systemd (template)"
install -o root -g root -m 644 "$SRC/app-pull@.service" /etc/systemd/system/app-pull@.service
install -o root -g root -m 644 "$SRC/app-pull@.timer" /etc/systemd/system/app-pull@.timer
systemctl daemon-reload

echo "==> Répertoire de conf"
install -d -o root -g root -m 755 /etc/app-deploy

echo "==> Jeton Telegram partagé"
TOKEN_FILE=/etc/app-deploy/telegram_token
ANCIEN_TOKEN=/etc/portfolio-deploy/telegram_token
if [ -s "$TOKEN_FILE" ]; then
  echo "    déjà en place, inchangé"
elif [ -s "$ANCIEN_TOKEN" ]; then
  # Migration depuis l'installation portfolio-only : même bot, pas besoin de
  # le ré-extraire des credentials n8n une seconde fois.
  install -o root -g root -m 600 "$ANCIEN_TOKEN" "$TOKEN_FILE"
  echo "    repris de $ANCIEN_TOKEN"
else
  umask 077
  # trap ... EXIT : le fichier contient TOUS les credentials n8n déchiffrés,
  # pas seulement le jeton Telegram qu'on en extrait. Un docker exec
  # interrompu (Ctrl-C, timeout, conteneur redémarré) entre l'export et le
  # rm -f d'origine les aurait laissés en clair dans /tmp du conteneur
  # jusqu'au prochain redémarrage. Le trap garantit le nettoyage sur toute
  # sortie normale de ce sous-shell (pas un SIGKILL dur, mais couvre déjà
  # Ctrl-C/SIGTERM/fin de docker exec).
  docker exec n8n sh -c 'umask 077; trap "rm -f /tmp/c.json" EXIT; n8n export:credentials --decrypted --all --output=/tmp/c.json >/dev/null 2>&1; grep -oE "[0-9]{8,}:[A-Za-z0-9_-]{30,}" /tmp/c.json | head -1' \
    > "$TOKEN_FILE" || true
  chmod 600 "$TOKEN_FILE"
  if ! grep -qE '^[0-9]{8,}:[A-Za-z0-9_-]{30,}$' "$TOKEN_FILE"; then
    rm -f "$TOKEN_FILE"
    echo "    ÉCHEC : jeton introuvable dans les credentials n8n (conteneur n8n démarré ?)." >&2
    echo "    L'installation continue : le déploiement fonctionnera, mais un retour" >&2
    echo "    arrière ne sera pas notifié tant que ce fichier n'existe pas." >&2
  else
    echo "    extrait des credentials n8n (root, 600)"
  fi
fi

echo
echo "Installé. Pour activer une app :"
echo "  1. cp <app>.conf.exemple /etc/app-deploy/<app>.conf, puis l'éditer"
echo "  2. systemctl enable --now app-pull@<app>.timer"
echo "  3. journalctl -u app-pull@<app> -f"
