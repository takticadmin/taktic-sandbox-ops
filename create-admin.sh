#!/usr/bin/env bash
# Taktic sandbox · crée le compte admin de test et affiche l'état du serveur.
# A lancer en root sur le serveur de test : bash create-admin.sh
set -euo pipefail
ADMIN_EMAIL="admin-sandbox@taktic.app"
ADMIN_FILE="/root/sandbox-admin.txt"
HOST="$(curl -4 -fsS https://api.ipify.org | tr . -).sslip.io"
[ -d /opt/taktic-sandbox ] || { echo "Pas un serveur sandbox. Arrêt."; exit 1; }

for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8000/api/auth/token -H 'content-type: application/json' -d '{}' || true)"
  [ "$code" != "000" ] && break; sleep 2
done

if [ ! -f "$ADMIN_FILE" ]; then
  ADMIN_PASS="$(openssl rand -hex 10)"
  curl -fsS -X POST http://127.0.0.1:8000/api/auth/register -H 'content-type: application/json' \
    -d "{\"first_name\":\"Admin\",\"last_name\":\"Sandbox\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" >/dev/null
  sudo -u postgres psql -d taktic -qc "UPDATE users SET role='admin' WHERE email='$ADMIN_EMAIL';"
  echo "Admin  https://$HOST/admin  identifiant: $ADMIN_EMAIL  mot de passe: $ADMIN_PASS" > "$ADMIN_FILE"
  chmod 600 "$ADMIN_FILE"
fi

echo
systemctl is-active --quiet taktic-api && echo "API          : OK" || echo "API          : EN PANNE"
systemctl is-active --quiet mailpit && echo "Mailpit      : OK" || echo "Mailpit      : EN PANNE"
systemctl is-active --quiet taktic-deploy.timer && echo "Mise à jour  : OK" || echo "Mise à jour  : EN PANNE"
curl -fsS -o /dev/null "https://$HOST/" && echo "Site HTTPS   : OK" || echo "Site HTTPS   : EN PANNE"
echo
echo "=================================================================="
echo " BAC A SABLE PRET : https://$HOST"
cat "$ADMIN_FILE"
cat /root/sandbox-mailpit.txt 2>/dev/null || true
echo "=================================================================="
