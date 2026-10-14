# taktic-sandbox-ops

Scripts d'installation du **serveur de test** Taktic (bac à sable). Aucun secret ici : mots de passe et clés sont générés sur le serveur et n'en sortent pas.

- `install.sh` : installe un VPS Ubuntu 24.04 neuf (PostgreSQL vide, API, front, Nginx, HTTPS, Mailpit) à partir de `takticadmin/taktic-platform-sandbox`. Refuse de tourner sur un serveur contenant `/opt/taktic` (prod).
- `deploy.sh` : mise à jour automatique toutes les 5 min depuis la branche `main` du dépôt sandbox.

Ne pointe jamais vers la prod : aucun e-mail réel (Mailpit), aucune clé Firebase, aucune connexion Odoo.
