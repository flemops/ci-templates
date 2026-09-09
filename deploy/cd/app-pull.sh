#!/bin/bash
# Déploiement continu générique — moitié VM du dispositif, pour toute
# application dont la conf existe dans /etc/app-deploy/<app>.conf.
#
# Généralisé depuis portfolio-pull.sh (flemops/portfolio.hamdy-tabsissi.com,
# PR #6/#7). GitHub Actions valide un commit puis déplace un tag ; ce script,
# lancé par app-pull@<app>.timer toutes les 2 minutes, compare ce tag distant
# au HEAD local et ne fait rien tant qu'ils sont identiques. C'est la VM qui
# va chercher : aucun port entrant n'est ouvert et aucun identifiant d'accès
# à la VM n'existe chez GitHub.
#
# Usage : app-pull.sh <nom-app>   (nom-app = <nom-app>.conf dans /etc/app-deploy)
#
# Installé par deploy/cd/install.sh en /usr/local/bin/app-pull.sh (root, 700).
#
# Quatre règles non négociables, reprises à l'identique du portfolio :
#
#   1. Ne JAMAIS toucher à /etc/nginx. La conf nginx se synchronise
#      séparément, à la main, par nginx-sync.sh de chaque dépôt applicatif.
#      Ce script n'en parle même pas.
#
#   2. Ne JAMAIS lancer « git clean ». Des fichiers non suivis (bases
#      locales, sauvegardes .bak, .ssh) existent dans certains REPO_DIR : un
#      clean les effacerait. « checkout --force --detach » suffit et ne
#      touche qu'aux fichiers suivis.
#
#   3. Un secret (jeton Telegram) ne passe jamais en argument de commande :
#      /proc/<pid>/cmdline est lisible par tout utilisateur local. Il
#      transite par stdin (curl --config -).
#
#   4. Le HEAD local reste détaché. Déplacer une branche locale sous les
#      pieds de git rendrait le prochain « git status » sur la VM
#      incompréhensible.
#
# Un échec sur une app ne bloque jamais les autres : verrou, quarantaine et
# unité systemd sont tous les trois par application (suffixés par APP_NAME).

set -euo pipefail

APP_NAME="${1:?usage: app-pull.sh <nom-app> (lit /etc/app-deploy/<nom-app>.conf)}"
CONF="/etc/app-deploy/${APP_NAME}.conf"

if [ ! -r "$CONF" ]; then
  echo "conf introuvable ou illisible : $CONF" >&2
  exit 1
fi

# La conf est "source"-ée telle quelle juste après : n'importe qui pourrait
# y écrire du shell arbitraire exécuté en root. "Racine 600" n'est qu'une
# convention documentée ailleurs (app.conf.exemple) tant qu'elle n'est pas
# vérifiée ici.
conf_proprio_mode=$(stat -c '%U %a' "$CONF") || { echo "métadonnées illisibles : $CONF" >&2; exit 1; }
conf_proprio=${conf_proprio_mode%% *}
conf_mode=${conf_proprio_mode##* }
if [ "$conf_proprio" != root ] || [ $((8#$conf_mode & 8#077)) -ne 0 ]; then
  echo "conf refusée : $CONF doit appartenir à root et n'être accessible qu'à lui (trouvé : $conf_proprio $conf_mode)" >&2
  exit 1
fi

# Valeurs par défaut avant la conf : APP_USER n'a pas besoin d'être répété
# quand il est identique au nom du service systemd (le cas des 4 apps
# actuelles). La conf peut le surcharger si un jour ça change.
APP_USER=""
NOTIF_CHAT=""
TAG=prod

# shellcheck source=/dev/null
source "$CONF"

: "${REPO_DIR:?REPO_DIR manquant dans $CONF}"
: "${SERVICE:?SERVICE manquant dans $CONF}"
: "${BUILD_CMD:?BUILD_CMD manquant dans $CONF}"
: "${HEALTH_URL:?HEALTH_URL manquant dans $CONF}"
: "${DEPLOY_KEY:?DEPLOY_KEY manquant dans $CONF}"
APP_USER="${APP_USER:-$SERVICE}"

HEALTH_ESSAIS="${HEALTH_ESSAIS:-30}"
HEALTH_ATTENTE="${HEALTH_ATTENTE:-1}"

TOKEN_FILE=/etc/app-deploy/telegram_token

VERROU="/run/app-pull-${APP_NAME}.lock"
QUARANTAINE="/var/lib/app-deploy/${APP_NAME}/echec"

# Clé de déploiement du dépôt (une par dépôt, voir /home/ubuntu/.ssh ou le
# home du compte applicatif selon les cas). IdentitiesOnly évite que ssh
# propose une autre clé et se fasse refuser avant d'arriver à la bonne.
export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o BatchMode=yes"

# .git appartient à l'utilisateur applicatif, ce script tourne en root sous
# systemd sans SUDO_UID : depuis git 2.35.2, toute commande git refuserait
# "dubious ownership" et le CD ne déploierait plus jamais, en silence
# (l'erreur est avalée par les 2>/dev/null de sha_distant). On l'autorise
# explicitement, borné à ce dépôt, sans toucher à /root/.gitconfig.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$REPO_DIR"

journal() { printf '[%s] %s\n' "$APP_NAME" "$*"; }

# Un déploiement peut durer plus de 2 minutes (npm ci / pip install). Sans
# verrou par app, le timer suivant démarrerait un second déploiement au
# milieu du premier — mais deux apps différentes ne se gênent jamais.
mkdir -p "$(dirname "$VERROU")"
exec 9>"$VERROU"
if ! flock -n 9; then
  journal "déploiement déjà en cours, on passe notre tour"
  exit 0
fi

notifier() {
  local texte="$1"
  if [ ! -r "$TOKEN_FILE" ] || [ -z "$NOTIF_CHAT" ]; then
    journal "ALERTE non transmise : jeton ou chat_id absent"
    return 0
  fi
  # Le jeton entre par stdin, pas par argv (règle 3).
  if ! printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(cat "$TOKEN_FILE")" \
    | curl --silent --show-error --fail --max-time 20 --output /dev/null --config - \
           --data-urlencode "chat_id=${NOTIF_CHAT}" \
           --data-urlencode "text=${texte}"; then
    journal "ALERTE non transmise : appel Telegram en échec"
  fi
  return 0
}

# Le tag peut être annoté (objet) ou léger (commit direct). ^{} donne le
# commit dans les deux cas ; on retombe sur le sha brut si la déref échoue.
sha_distant() {
  local sha
  sha=$(git -C "$REPO_DIR" ls-remote origin "refs/tags/${TAG}^{}" | awk 'NR==1{print $1}') || return 1
  if [ -z "$sha" ]; then
    sha=$(git -C "$REPO_DIR" ls-remote origin "refs/tags/${TAG}" | awk 'NR==1{print $1}') || return 1
  fi
  printf '%s' "$sha"
}

# Installe un commit précis et redémarre. Chaque commande échoue
# explicitement : appelée depuis un « if », la fonction ne bénéficie plus de
# set -e.
appliquer() {
  local sha="$1"
  # checkout --force --detach fait en une commande ce que « reset --hard »
  # ferait en deux, sans jamais déplacer de branche locale (règle 4).
  git -C "$REPO_DIR" checkout --force --detach --quiet "$sha" || return 1
  # Budget interne < TimeoutStartSec du service : un rollback enchaîne DEUX
  # appliquer() + DEUX sain(). Sans ce plafond, un build anormalement lent
  # se ferait tuer sec par systemd avant la quarantaine/notification (le
  # flock est relâché, rien n'est écrit, le tick suivant recommence à
  # l'identique, en boucle et en silence).
  timeout 300 bash -c 'cd "$1" && eval "$2"' _ "$REPO_DIR" "$BUILD_CMD" || return 1
  # git et la construction ont écrit en root ; le service tourne en
  # APP_USER. Mais .git et un éventuel .venv ne doivent JAMAIS appartenir à
  # APP_USER : ce sont des chemins que ROOT réexécute au tick suivant (hooks
  # git, .git/config qui accepte des chemins de commande comme
  # core.fsmonitor/core.pager, binaires du venv). Un compte applicatif qui
  # obtiendrait une primitive d'écriture (RCE web, dépendance compromise)
  # deviendrait root au prochain déploiement — NoNewPrivileges ne protège
  # pas ici, le service qui exécute est déjà root.
  chown -R "$APP_USER:$APP_USER" "$REPO_DIR" || return 1
  chown -R root:root "$REPO_DIR/.git" || return 1
  if [ -d "$REPO_DIR/.venv" ]; then
    chown -R root:root "$REPO_DIR/.venv" || return 1
  fi
  systemctl restart "$SERVICE" || return 1
  return 0
}

sain() {
  local i
  for ((i = 1; i <= HEALTH_ESSAIS; i++)); do
    if curl --silent --show-error --fail --max-time 3 --output /dev/null "$HEALTH_URL" 2>/dev/null; then
      journal "healthcheck OK après ${i} essai(s)"
      return 0
    fi
    sleep "$HEALTH_ATTENTE"
  done
  journal "healthcheck KO après ${HEALTH_ESSAIS} essais sur ${HEALTH_URL}"
  return 1
}

retour_arriere() {
  local precedent="$1" raison="$2" cible="$3" etat
  journal "ÉCHEC (${raison}) — retour à ${precedent}"
  if appliquer "$precedent"; then
    if sain; then
      etat="site RÉTABLI (healthcheck OK)"
    else
      etat="site TOUJOURS KO après le retour arrière"
    fi
  else
    etat="RETOUR ARRIÈRE EN ÉCHEC (réinstallation impossible)"
  fi
  journal "résultat du retour arrière : $etat"
  # Quarantaine par app : sans elle, le tag distant reste sur $cible et le
  # tick suivant (2 min) le redéploie à l'identique, indéfiniment, jusqu'à
  # intervention humaine (service dégradé + rafale Telegram en boucle).
  mkdir -p "$(dirname "$QUARANTAINE")" && printf '%s' "$cible" > "$QUARANTAINE"
  notifier "[${APP_NAME}] déploiement échoué
commit refusé : ${cible}
raison        : ${raison}
rétabli sur   : ${precedent}
état          : ${etat}
journal       : journalctl -u app-pull@${APP_NAME} -n 80"
  exit 1
}

cible=$(sha_distant) || { journal "impossible d'interroger le dépôt distant"; exit 1; }
if [ -z "$cible" ]; then
  journal "aucun tag ${TAG} sur le dépôt distant, rien à déployer"
  exit 0
fi

actuel=$(git -C "$REPO_DIR" rev-parse HEAD)
if [ "$cible" = "$actuel" ]; then
  exit 0
fi

if [ "$cible" = "$(cat "$QUARANTAINE" 2>/dev/null)" ]; then
  journal "commit ${cible} déjà refusé (quarantaine), on attend un nouveau tag"
  exit 0
fi

journal "tag ${TAG} = ${cible}, HEAD = ${actuel} — déploiement"

if ! git -C "$REPO_DIR" fetch --tags --force --prune --quiet origin; then
  journal "git fetch en échec, déploiement abandonné (rien n'a été modifié)"
  exit 1
fi

if ! appliquer "$cible"; then
  retour_arriere "$actuel" "installation impossible" "$cible"
fi

if ! sain; then
  retour_arriere "$actuel" "healthcheck KO" "$cible"
fi

journal "déploiement OK : ${actuel} -> ${cible}"
