# ci-templates

Workflow GitHub Actions réutilisable et script de déploiement **pull-based** utilisés pour livrer les applications d'une même machine virtuelle. Catégorie : support DevOps · état : actif, utilisé en production par 4 dépôts (dont [`eventmap`](https://github.com/flemops/eventmap), public).

## Problème

Livrer plusieurs petites applications sans donner à GitHub un accès SSH à la machine, sans copier-coller le même pipeline dans chaque dépôt, et sans qu'une mauvaise version reste en ligne.

## Ce que Hamdy a fait

Conception et écriture des deux moitiés : le workflow de validation/tag et le script de déploiement côté VM, généralisés à partir d'une première installation sur un seul site.

## Architecture

```
dépôt applicatif ──push master──▶ valider-et-taguer.yml (ce dépôt, workflow_call)
                                   install → lint → tests → vérif. des dépendances de production seules
                                   └─ si vert : déplace le tag `prod` sur le commit validé
VM ◀── app-pull@<app>.timer (toutes les 2 min) compare le tag distant au HEAD local
       └─ différent ? tire, construit, redémarre, healthcheck
          └─ échec ? retour arrière automatique + quarantaine du commit + alerte Telegram
```

Aucun port entrant n'est nécessaire pour le déploiement et GitHub ne détient aucun identifiant d'accès à la VM : c'est la VM qui vient chercher.

### `.github/workflows/valider-et-taguer.yml` (workflow_call)

Entrées obligatoires : `runtime` (`node` | `python`), `version`, `install_cmd`, `test_cmd`. Facultatives : `lint_cmd`, `tag_name` (défaut `prod`), `tag_prod`, `prod_install_cmd` + `prod_check_cmd` (prouvent que les seules dépendances de production suffisent, dans un venv isolé). Permissions : `contents: write` (pour pousser le tag), plafond de 15 min, concurrence bornée par dépôt appelant. Aucun secret.

Exemple d'appel (référence immuable, voir plus bas) :

```yaml
jobs:
  ci:
    uses: flemops/ci-templates/.github/workflows/valider-et-taguer.yml@<SHA-complet>  # v1.0.0
    with:
      runtime: python
      version: "3.12"
      install_cmd: pip install -r requirements-dev.txt
      test_cmd: python -m pytest
```


### `.github/workflows/automation-baseline.yml` (workflow_call)

Socle CI générique à faible coût pour les dépôts qui n'ont pas besoin du mécanisme de tag `prod`. Il accepte `node`, `python` ou `docs`, valide strictement les entrées, permet de configurer/désactiver le cache Node, puis exécute uniquement les commandes demandées (installation, lint, tests, build, audit). Les scans de secrets restent volontairement dans les dépôts consommateurs : leurs permissions et leur politique diffèrent selon le dépôt.

### `deploy/cd/` (côté VM)

- `app-pull.sh` — un script, une configuration par application (`/etc/app-deploy/<app>.conf`) ; verrou, quarantaine et unité systemd sont **par application** : l'échec d'une application ne bloque jamais les autres.
- `app-pull@.service` / `app-pull@.timer` — unités systemd *template* (`systemctl enable --now app-pull@<app>.timer`).
- `install.sh` — installation idempotente ; `app.conf.exemple` — gabarit de configuration (sans valeur réelle).

Règles non négociables du script : ne jamais toucher à la configuration nginx, ne jamais `git clean`, aucun secret en argument de commande (stdin uniquement), HEAD toujours détaché.

## Preuve

- Les workflows des dépôts appelants (`prod-tag.yml`) et leurs exécutions sont publics pour `eventmap` : [exécutions « Prod gate »](https://github.com/flemops/eventmap/actions/workflows/prod-tag.yml).
- Un retour arrière a été exercé en réel lors de la mise en place (journal interne ; non reproduit ici).

## Versionnage, compatibilité et mises à jour

- **Référence immuable** : un appel pointe sur le SHA complet d'une release (`@<sha>  # v1.0.0`), jamais `@master` — le workflow déplace le tag `prod`, qui commande un déploiement.
- **Compatibilité** : dans une version `1.x`, les entrées existantes ne sont ni renommées ni retirées ; une entrée ajoutée est facultative avec un défaut. Tout changement incompatible = version majeure, décrit dans [CHANGELOG.md](CHANGELOG.md).
- **Mettre à jour un consommateur** : branche, remplacer le SHA, déclencher le workflow sur la branche, merger si vert, contrôler le déploiement réel. Un dépôt à la fois.
- **Actions tierces** : épinglées par SHA vérifié sur le tag de release officiel (commentaire `# vX.Y.Z`). Dependabot propose mensuellement les mises à jour ; chaque PR reste à relire et tester avant fusion.

## Limites

- Conçu pour une VM unique et des applications Node ou Python ; pas de multi-environnement ni de déploiement progressif.
- Les notifications d'échec passent par Telegram ; sans jeton configuré, le déploiement fonctionne mais un retour arrière n'est pas notifié.
- Le dépôt valide automatiquement la syntaxe/ShellCheck des scripts de déploiement et scanne les secrets ; le comportement de déploiement complet reste validé depuis les consommateurs et la VM.
- `install.sh` peut extraire le jeton Telegram des identifiants d'une instance n8n locale (chemin de migration propre à cette installation) : à adapter ailleurs.

## Licence

[MIT](LICENSE).
