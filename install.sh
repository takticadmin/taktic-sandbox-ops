#!/usr/bin/env bash
# Taktic · installation du serveur de TEST (bac à sable).
# A lancer en root sur un VPS Ubuntu 24.04 neuf :  bash install.sh
#
# Ce script ne contient aucun secret. Il :
#   - installe PostgreSQL, Python (uv), Node 22, Nginx, Mailpit ;
#   - génère sur le serveur une clé de LECTURE pour le dépôt sandbox ;
#   - déploie takticadmin/taktic-platform-sandbox avec une base VIDE ;
#   - coupe tout lien avec la prod : aucun e-mail réel (Mailpit), aucune clé
#     Firebase, aucune connexion Odoo ;
#   - installe une mise à jour automatique toutes les 5 min depuis la branche main.
set -euo pipefail

REPO_SSH="git@github.com:takticadmin/taktic-platform-sandbox.git"
BRANCH="main"
APP_USER="taktic"
BASE="/opt/taktic-sandbox"
SRC="$BASE/platform"
OPS_RAW="https://raw.githubusercontent.com/takticadmin/taktic-sandbox-ops/main"
ADMIN_EMAIL="admin-sandbox@taktic.app"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "lancer en root (sudo -i)"
grep -q '24.04' /etc/os-release || die "Ubuntu 24.04 attendu"

# Garde-fou : ce script refuse de tourner sur un serveur qui ressemble à la prod.
if [ -d /opt/taktic ] || [ -e /etc/nginx/sites-enabled/platform.taktic.app ]; then
  die "ce serveur contient /opt/taktic (prod ?). Arrêt, rien n'a été modifié."
fi

PUBLIC_IP="$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')"
HOST="${PUBLIC_IP//./-}.sslip.io"

log "Système et paquets"
hostnamectl set-hostname taktic-sandbox
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq git curl ca-certificates build-essential nginx postgresql \
  ufw unattended-upgrades certbot python3-certbot-nginx apache2-utils openssl
dpkg-reconfigure -f noninteractive unattended-upgrades

log "Pare-feu (SSH, HTTP, HTTPS uniquement)"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable

log "Node 22"
if ! command -v node >/dev/null || ! node -v | grep -q '^v22'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -yq nodejs
fi

log "Mailpit (capte tous les e-mails, rien ne sort)"
if ! command -v mailpit >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/axllent/mailpit/develop/install.sh | bash
fi
cat >/etc/systemd/system/mailpit.service <<EOF
[Unit]
Description=Mailpit (capteur d'e-mails du bac à sable)
After=network.target
[Service]
ExecStart=/usr/local/bin/mailpit --listen 127.0.0.1:8025 --smtp 127.0.0.1:1025 --webroot /mailpit/
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mailpit

log "Utilisateur applicatif"
id "$APP_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$APP_USER"
mkdir -p "$BASE" && chown "$APP_USER:$APP_USER" "$BASE"
sudo -u "$APP_USER" bash -c 'command -v ~/.local/bin/uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh'

log "Clé de lecture GitHub (générée ici, ne quitte jamais le serveur)"
KEY="/home/$APP_USER/.ssh/sandbox_deploy"
sudo -u "$APP_USER" mkdir -p "/home/$APP_USER/.ssh"
[ -f "$KEY" ] || sudo -u "$APP_USER" ssh-keygen -t ed25519 -N '' -C 'taktic-sandbox-vps' -f "$KEY" -q
sudo -u "$APP_USER" bash -c "ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null"
sudo -u "$APP_USER" tee "/home/$APP_USER/.ssh/config" >/dev/null <<EOF
Host github.com
  IdentityFile $KEY
  IdentitiesOnly yes
EOF

until sudo -u "$APP_USER" git ls-remote "$REPO_SSH" >/dev/null 2>&1; do
  clear
  echo "=================================================================="
  echo " CLE PUBLIQUE A AJOUTER (lecture seule) DANS LE DEPOT SANDBOX :"
  echo "=================================================================="
  cat "$KEY.pub"
  echo "=================================================================="
  echo " En attente de l'accès au dépôt... (nouvel essai toutes les 15 s)"
  sleep 15
done
log "Accès au dépôt OK"

[ -d "$SRC/.git" ] || sudo -u "$APP_USER" git clone --branch "$BRANCH" "$REPO_SSH" "$SRC"
# Sécurité : ce clone ne peut rien pousser.
sudo -u "$APP_USER" git -C "$SRC" remote set-url --push origin DISABLED

log "Base PostgreSQL vide"
DB_PASS_FILE="/home/$APP_USER/.db_pass"
if [ ! -f "$DB_PASS_FILE" ]; then
  openssl rand -hex 24 > "$DB_PASS_FILE"
  chown "$APP_USER:$APP_USER" "$DB_PASS_FILE"; chmod 600 "$DB_PASS_FILE"
fi
DB_PASS="$(cat "$DB_PASS_FILE")"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='taktic'" | grep -q 1 \
  || sudo -u postgres psql -qc "CREATE ROLE taktic LOGIN CREATEDB PASSWORD '$DB_PASS';"

log "Fichier .env (valeurs locales, aucun accès prod)"
if [ ! -f "$SRC/.env" ]; then
  AUTH_SECRET="$(openssl rand -hex 32)"
  sed -e "s#^BASE_URL=.*#BASE_URL=https://$HOST/api#" \
      -e "s#^BASE_URL_APP=.*#BASE_URL_APP=https://$HOST#" \
      -e "s#^DATABASE_URL=.*#DATABASE_URL=postgresql+asyncpg://taktic:$DB_PASS@localhost:5432/taktic#" \
      -e "s#^AUTH_SECRET_KEY=.*#AUTH_SECRET_KEY=$AUTH_SECRET#" \
      -e "s#^DATA_PATH=.*#DATA_PATH=$BASE/data#" \
      -e "s#^HTTP_WORKERS=.*#HTTP_WORKERS=2#" \
      -e "s#^SMTP_HOST=.*#SMTP_HOST=127.0.0.1#" -e "s#^SMTP_PORT=.*#SMTP_PORT=1025#" \
      -e "s#^SMTP_USE_TLS=.*#SMTP_USE_TLS=False#" -e "s#^SMTP_USERNAME=.*#SMTP_USERNAME=#" \
      -e "s#^SMTP_PASSWORD=.*#SMTP_PASSWORD=#" \
      -e "s#^FIREBASE_CREDENTIALS_PATH=.*#FIREBASE_CREDENTIALS_PATH=#" \
      -e "s#^GOOGLE_PLACES_API=.*#GOOGLE_PLACES_API=#" \
      -e '/^ODOO_API_/d' \
      "$SRC/.env.tpl" > "$SRC/.env"
  chown "$APP_USER:$APP_USER" "$SRC/.env"; chmod 600 "$SRC/.env"
fi
mkdir -p "$BASE/data" && chown "$APP_USER:$APP_USER" "$BASE/data"
# Contrôle : aucune adresse de prod ne doit rester active.
if grep -E '^[A-Z_]+=.*(platform\.taktic\.app|odoo\.taktic\.app|krafter)' "$SRC/.env"; then
  die ".env contient une adresse de prod"
fi

log "Backend : dépendances, migrations, données de base"
sudo -u "$APP_USER" bash -c "cd $SRC && ~/.local/bin/uv sync --no-dev -q"
sudo -u "$APP_USER" bash -c "cd $SRC && .venv/bin/kt db createdb || true"
sudo -u "$APP_USER" bash -c "cd $SRC && .venv/bin/kt db migrate && .venv/bin/kt db init-data"

cat >/etc/systemd/system/taktic-api.service <<EOF
[Unit]
Description=Taktic API (bac à sable)
After=network.target postgresql.service
[Service]
User=$APP_USER
WorkingDirectory=$SRC
ExecStart=$SRC/.venv/bin/kt serve --host 127.0.0.1 --port 8000 --no-reload
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now taktic-api

log "Front : build"
sudo -u "$APP_USER" bash -c "cd $SRC && npm ci --no-audit --no-fund -s && npm run build -s"

log "Nginx"
MAILPIT_PASS_FILE="/root/sandbox-mailpit.txt"
if [ ! -f /etc/nginx/.mailpit_htpasswd ]; then
  MP="$(openssl rand -hex 8)"
  htpasswd -bc /etc/nginx/.mailpit_htpasswd admin "$MP" >/dev/null
  echo "Mailpit https://$HOST/mailpit/  utilisateur: admin  mot de passe: $MP" > "$MAILPIT_PASS_FILE"
  chmod 600 "$MAILPIT_PASS_FILE"
fi
cat >/etc/nginx/sites-available/taktic-sandbox <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $HOST _;
    root $SRC/app/dist;
    client_max_body_size 50m;
    add_header X-Robots-Tag "noindex, nofollow" always;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /mailpit/ {
        auth_basic "Bac a sable";
        auth_basic_user_file /etc/nginx/.mailpit_htpasswd;
        proxy_pass http://127.0.0.1:8025;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location = /robots.txt { return 200 "User-agent: *\nDisallow: /\n"; }
    location /admin { try_files \$uri /admin.html; }
    location /commercial { try_files \$uri /agent.html; }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/taktic-sandbox /etc/nginx/sites-enabled/taktic-sandbox
chmod o+x /home/$APP_USER 2>/dev/null || true
nginx -t && systemctl reload nginx

log "HTTPS ($HOST)"
certbot --nginx -d "$HOST" --non-interactive --agree-tos --register-unsafely-without-email --redirect \
  || echo "HTTPS non obtenu pour l'instant : le site reste en HTTP. Relancer : certbot --nginx -d $HOST"

log "Mise à jour automatique (toutes les 5 min)"
curl -fsSL "$OPS_RAW/deploy.sh" -o "$BASE/deploy.sh"
chmod 755 "$BASE/deploy.sh"
cat >/etc/sudoers.d/taktic-sandbox <<EOF
$APP_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart taktic-api
EOF
chmod 440 /etc/sudoers.d/taktic-sandbox
cat >/etc/systemd/system/taktic-deploy.service <<EOF
[Unit]
Description=Taktic sandbox : déploiement depuis GitHub
[Service]
Type=oneshot
User=$APP_USER
ExecStart=$BASE/deploy.sh
EOF
cat >/etc/systemd/system/taktic-deploy.timer <<EOF
[Unit]
Description=Taktic sandbox : vérifie GitHub toutes les 5 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now taktic-deploy.timer

log "Compte administrateur de test"
ADMIN_FILE="/root/sandbox-admin.txt"
if [ ! -f "$ADMIN_FILE" ]; then
  for i in $(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:8000/api/auth/token -X POST -H 'content-type: application/json' -d '{}' 2>/dev/null; code=$?; [ $code -ne 7 ] && break; sleep 2; done
  ADMIN_PASS="$(openssl rand -hex 10)"
  curl -fsS -X POST http://127.0.0.1:8000/api/auth/register -H 'content-type: application/json' \
    -d "{\"first_name\":\"Admin\",\"last_name\":\"Sandbox\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" >/dev/null
  sudo -u postgres psql -d taktic -qc "UPDATE users SET role='admin' WHERE email='$ADMIN_EMAIL';"
  echo "Admin  https://$HOST/admin  identifiant: $ADMIN_EMAIL  mot de passe: $ADMIN_PASS" > "$ADMIN_FILE"
  chmod 600 "$ADMIN_FILE"
fi

log "Vérifications"
sleep 3
systemctl is-active --quiet taktic-api && echo "API      : OK" || echo "API      : EN PANNE (journalctl -u taktic-api)"
systemctl is-active --quiet mailpit && echo "Mailpit  : OK" || echo "Mailpit  : EN PANNE"
curl -fsS -o /dev/null "http://127.0.0.1/" && echo "Site web : OK" || echo "Site web : EN PANNE"
echo
echo "=================================================================="
echo " BAC A SABLE PRET : https://$HOST"
echo " API pour l'app mobile : https://$HOST/api"
echo " Identifiants de test : cat $ADMIN_FILE ; cat $MAILPIT_PASS_FILE"
echo "=================================================================="
