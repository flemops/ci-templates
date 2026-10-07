# Changelog

Versionnage : [SemVer](https://semver.org/lang/fr/). Un consommateur référence une release par son **SHA complet**
(`@<sha>  # vX.Y.Z`), jamais `@master`.

## 1.0.0 — 07/10/2026
- Première release référencée. Contenu inchangé par rapport à `master` au 13/09/2026, sauf :
  - les actions `checkout`, `setup-node` et `setup-python` sont épinglées par SHA (tags officiels v7.0.1 / v7.0.0 / v7.0.0) ;
  - `app.conf.exemple` : identifiant Telegram remplacé par un gabarit.
- Entrées (`inputs`) : `runtime`, `version`, `install_cmd`, `test_cmd` (obligatoires) ; `lint_cmd`, `tag_name` (défaut `prod`), `tag_prod`, `prod_install_cmd`, `prod_check_cmd` (optionnels).

## Avant 1.0.0
Voir l'historique Git (`4a48712` : actions v7 ; `ee83ba4` : vérification des dépendances de production).

## Note de publication (07/10/2026)
Le dépôt a été rendu public sous cette forme ; l'historique antérieur à la publication a été assaini (identifiant de messagerie personnel retiré de `app.conf.exemple`). Les SHA des releases ont changé à cette occasion : les consommateurs ont été réépinglés.
