#!/usr/bin/env bash
#
# oddfusion.ai — one-time VPS setup. Run once, on the VPS, as `daniel`.
#
#   ssh vps
#   curl -fsSL https://raw.githubusercontent.com/inventor2607/oddfusionai/main/infra/setup-vps.sh -o /tmp/setup-vps.sh
#   less /tmp/setup-vps.sh     # read it first
#   bash /tmp/setup-vps.sh
#
# It will prompt for your sudo password. Everything it does is additive: it
# creates one user, two directories and three nginx files, and touches no
# existing site. It refuses to overwrite anything that already exists.
#
# This box also serves tenkif.com and tripplansai.com. The script validates the
# nginx config before every reload and aborts rather than reloading a broken
# config, so a mistake here cannot take those sites down.

set -euo pipefail

DEPLOY_USER="oddfusion-deploy"
WEBROOT="/var/www/oddfusion.ai"
ACME_ROOT="/var/www/certbot"
# Pinned to a commit, not a branch: raw.githubusercontent.com edge-caches branch
# URLs, and a stale copy silently installed the wrong nginx config once already.
# Bump this SHA deliberately when the configs change.
PIN="7462b4f"
RAW="https://raw.githubusercontent.com/inventor2607/oddfusionai/$PIN/infra/nginx"
CERT_NAME="oddfusion.ai"
DOMAINS=(oddfusion.ai www.oddfusion.ai oddfusionai.com www.oddfusionai.com)
CERTBOT_EMAIL="michal@oddfusion.ai"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
say "0. Preflight"
# --------------------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "run as daniel, not root"
command -v rrsync >/dev/null || die "rrsync missing; expected /usr/bin/rrsync"

for d in "${DOMAINS[@]}"; do
  ip=$(dig +short A "$d" | tail -1)
  here=$(curl -fsS --max-time 10 https://api.ipify.org || true)
  printf '  %-24s -> %s\n' "$d" "${ip:-NO RECORD}"
  [[ -n "$ip" ]] || die "$d has no A record; certbot would fail and burn rate limit"
  if [[ -n "$here" && "$ip" != "$here" ]]; then
    die "$d resolves to $ip but this host is $here"
  fi
done
echo "  DNS OK — safe to request certificates"

# --------------------------------------------------------------------------
say "1. Deploy user (no sudo, confined to the web root)"
# --------------------------------------------------------------------------
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "  $DEPLOY_USER already exists — leaving it alone"
else
  sudo useradd --system --create-home --shell /bin/bash \
       --home-dir "/home/$DEPLOY_USER" "$DEPLOY_USER"
  echo "  created $DEPLOY_USER"
fi
sudo test ! -e "/home/$DEPLOY_USER/.ssh/id_ed25519" || \
  die "/home/$DEPLOY_USER/.ssh/id_ed25519 already exists; refusing to replace a key in use"

sudo -u "$DEPLOY_USER" mkdir -p "/home/$DEPLOY_USER/.ssh"
sudo -u "$DEPLOY_USER" chmod 700 "/home/$DEPLOY_USER/.ssh"
# Key is generated here and never leaves this box except as the value you paste
# into GitHub secrets below.
sudo -u "$DEPLOY_USER" ssh-keygen -q -t ed25519 -N '' \
     -f "/home/$DEPLOY_USER/.ssh/id_ed25519" -C 'github-actions@oddfusionai'

# rrsync confines this key to WEBROOT; `restrict` removes pty, port/agent/X11
# forwarding. A leaked deploy key can replace the marketing page and nothing
# else on a box that also runs two other production sites.
sudo -u "$DEPLOY_USER" bash -c "
  printf 'command=\"/usr/bin/rrsync %s\",restrict %s\n' \
    '$WEBROOT' \"\$(cat /home/$DEPLOY_USER/.ssh/id_ed25519.pub)\" \
    > /home/$DEPLOY_USER/.ssh/authorized_keys
  chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
"
echo "  deploy key generated and restricted to $WEBROOT"

# --------------------------------------------------------------------------
say "2. Directories"
# --------------------------------------------------------------------------
sudo mkdir -p "$WEBROOT" "$ACME_ROOT"
sudo chown -R "$DEPLOY_USER:$DEPLOY_USER" "$WEBROOT"
sudo chmod 755 "$WEBROOT"
sudo chown -R root:root "$ACME_ROOT"
# Placeholder so the bootstrap block serves something rather than 404ing.
sudo -u "$DEPLOY_USER" tee "$WEBROOT/index.html" >/dev/null <<'PLACEHOLDER'
<!doctype html><meta charset="utf-8"><title>oddfusion.ai</title>
<p>Deploying.</p>
PLACEHOLDER
echo "  $WEBROOT (owned by $DEPLOY_USER) and $ACME_ROOT ready"

# --------------------------------------------------------------------------
say "3. Bootstrap nginx block (HTTP only, so certbot can answer)"
# --------------------------------------------------------------------------
[[ ! -e /etc/nginx/sites-available/oddfusion.ai ]] || \
  die "/etc/nginx/sites-available/oddfusion.ai already exists; refusing to overwrite"

sudo curl -fsSL "$RAW/oddfusion-acme-bootstrap.conf" \
     -o /etc/nginx/sites-available/oddfusion.ai
sudo ln -sfn /etc/nginx/sites-available/oddfusion.ai \
     /etc/nginx/sites-enabled/oddfusion.ai
sudo nginx -t || die "nginx config invalid — NOT reloading; existing sites untouched"
sudo systemctl reload nginx
echo "  bootstrap block live; oddfusion.ai answers on port 80"

# --------------------------------------------------------------------------
say "4. Certificate for all four names (certonly --webroot)"
# --------------------------------------------------------------------------
if sudo certbot certificates 2>/dev/null | grep -q "Certificate Name: $CERT_NAME"; then
  echo "  certificate '$CERT_NAME' already exists — skipping issuance"
else
  args=(); for d in "${DOMAINS[@]}"; do args+=(-d "$d"); done
  sudo certbot certonly --webroot -w "$ACME_ROOT" \
       --cert-name "$CERT_NAME" "${args[@]}" \
       --non-interactive --agree-tos --email "$CERTBOT_EMAIL" \
       --keep-until-expiring
  echo "  certificate issued"
fi

# --------------------------------------------------------------------------
say "5. Final nginx config + 443 default-server fix"
# --------------------------------------------------------------------------
sudo curl -fsSL "$RAW/oddfusion.conf" -o /etc/nginx/sites-available/oddfusion.ai

if [[ -e /etc/nginx/sites-available/000-default-tls-reject ]]; then
  echo "  443 default block already present — leaving it alone"
else
  sudo curl -fsSL "$RAW/default-tls-reject.conf" \
       -o /etc/nginx/sites-available/000-default-tls-reject
  sudo ln -sfn /etc/nginx/sites-available/000-default-tls-reject \
       /etc/nginx/sites-enabled/000-default-tls-reject
  echo "  443 default block installed (unmatched SNI now rejected, not served tenkif's cert)"
fi

sudo nginx -t || die "nginx config invalid — NOT reloading; previous config still serving"
sudo systemctl reload nginx
echo "  final config live"

# --------------------------------------------------------------------------
say "6. GitHub repository secrets — copy these into the repo settings"
# --------------------------------------------------------------------------
cat <<INFO

  Settings -> Secrets and variables -> Actions -> New repository secret

  DEPLOY_USER        $DEPLOY_USER
  DEPLOY_HOST        $(curl -fsS --max-time 10 https://api.ipify.org || echo '<this VPS IP>')
  DEPLOY_PORT        22
  DEPLOY_PATH        /
      ^ intentionally just "/" — rrsync roots the deploy key at $WEBROOT,
        so "/" over that connection already means $WEBROOT.

  DEPLOY_KNOWN_HOSTS
$(ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | sed "s#^127.0.0.1#$(curl -fsS --max-time 10 https://api.ipify.org || echo HOST)#" | sed 's/^/    /')

  DEPLOY_SSH_KEY  (private key — paste the whole block, then it is never needed again)

INFO
sudo cat "/home/$DEPLOY_USER/.ssh/id_ed25519"
cat <<'INFO'

Done. Nothing else on this box was modified.
INFO
