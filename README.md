# ci-templates

Pièces réutilisables du déploiement continu pull-based, généralisé depuis le
portfolio (voir `flemops/portfolio.hamdy-tabsissi.com`, PR #6/#7) à toutes les
applications de la VM Oracle.

## `.github/workflows/valider-et-taguer.yml`

Workflow réutilisable (`workflow_call`). Chaque dépôt applicatif l'appelle
depuis son propre `.github/workflows/prod-tag.yml` :

```yaml
name: Validation + tag prod

on:
  push:
    branches: [master]
  workflow_dispatch:
    inputs:
      tag_prod:
        type: boolean
        default: false

permissions:
  contents: write

jobs:
  ci:
    uses: flemops/ci-templates/.github/workflows/valider-et-taguer.yml@master
    with:
      runtime: python        # ou node
      version: "3.10"
      install_cmd: pip install -r requirements.txt
      test_cmd: pytest
      tag_prod: ${{ inputs.tag_prod }}
```

Aucun secret : le `GITHUB_TOKEN` par défaut suffit à pousser le tag
(`permissions: contents: write`). La VM ne reçoit jamais d'identifiant côté
GitHub — c'est elle qui vient chercher le tag (voir `deploy/cd/`).

## `deploy/cd/` — moitié « pull » côté VM

Généralisation de `portfolio-pull.sh` : un seul script, une conf par
application.

- `app-pull.sh` — installé en `/usr/local/bin/app-pull.sh` (root, 700). Prend
  le nom de l'app en argument (`app-pull.sh eventmap`), lit
  `/etc/app-deploy/<app>.conf`, compare le tag distant au HEAD local, tire,
  construit, redémarre, healthcheck, et **rollback automatique** + quarantaine
  + notification Telegram en cas d'échec. Verrou et quarantaine sont
  **par application** : l'échec d'une app ne bloque jamais les autres.
- `app-pull@.service` / `app-pull@.timer` — unités systemd **template**
  (`%i` = nom de l'app). Une instance par app :
  `systemctl enable --now app-pull@eventmap.timer`.
- `install.sh` — pose le script + les unités template (idempotent, ne touche
  pas aux `.conf` existants).
- `<app>.conf.exemple` — gabarit de configuration par app.

Quatre règles reprises à l'identique du portfolio (non négociables) :
1. Ne jamais toucher à `/etc/nginx` — la conf se synchronise séparément.
2. Ne jamais `git clean` — `checkout --force --detach` suffit.
3. Aucun secret en argument de commande (stdin uniquement).
4. Le HEAD reste toujours détaché.

## Périmètre volontairement exclu

`mission-control` (port 3010) tourne depuis un fork d'un dépôt tiers
(`builderz-labs/mission-control`) : impossible d'y ajouter un workflow sans
risquer un conflit avec le upstream. Non implémenté ici — voir
`ETAT-CHANTIERS.md` du dépôt `atelier-claude` pour la décision.
