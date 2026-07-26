#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="student-portal"
RUNNER_DIR="$HOME/actions-runner"
REMOVE_TOKEN=""
DB_NAME=""
DB_USER=""
SKIP_MYSQL=false
SKIP_NGINX=false
SKIP_RUNNER=false
ASSUME_YES=false

usage() {
  cat <<USAGE
Usage: $0 --token <RUNNER_REMOVE_TOKEN> [options]

Resets a VM back to a bare state after a CI/CD self-hosted-runner exercise
(self-hosted runner + systemd app service + venv + MySQL + Nginx).
Reusable across projects that share this topology - adjust --service
and --runner-dir per project, and always pass a fresh --token.

Required (unless --skip-runner):
  --token <TOKEN>       GitHub Actions runner removal token. Get one with:
                         gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token
                         (or GitHub UI: Settings -> Actions -> Runners -> runner -> Remove)

Options:
  --service <name>      systemd service name (default: student-portal)
  --runner-dir <path>   self-hosted runner install dir (default: \$HOME/actions-runner)
  --db-name <name>      MySQL database to drop before purging MySQL
  --db-user <name>      MySQL user to drop before purging MySQL
  --skip-mysql          don't touch MySQL
  --skip-nginx          don't touch Nginx
  --skip-runner         don't touch the self-hosted runner (--token not required)
  -y, --yes             don't ask for confirmation
  -h, --help            show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) REMOVE_TOKEN="$2"; shift 2 ;;
    --service) SERVICE_NAME="$2"; shift 2 ;;
    --runner-dir) RUNNER_DIR="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --skip-mysql) SKIP_MYSQL=true; shift ;;
    --skip-nginx) SKIP_NGINX=true; shift ;;
    --skip-runner) SKIP_RUNNER=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$SKIP_RUNNER" == false && -z "$REMOVE_TOKEN" ]]; then
  echo "Error: --token is required unless --skip-runner is set." >&2
  usage
  exit 1
fi

if [[ "$ASSUME_YES" == false ]]; then
  echo "This will remove:"
  echo "  - systemd service '$SERVICE_NAME', its sudoers rule, its venv"
  [[ "$SKIP_RUNNER" == false ]] && echo "  - self-hosted runner at '$RUNNER_DIR' (local + deregistered from GitHub)"
  [[ "$SKIP_MYSQL" == false ]] && echo "  - MySQL server (full purge)"
  [[ "$SKIP_NGINX" == false ]] && echo "  - Nginx (full purge)"
  read -rp "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "==> Removing systemd service: $SERVICE_NAME"
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/$SERVICE_NAME.service"
sudo rm -f "/etc/sudoers.d/$SERVICE_NAME"
sudo systemctl daemon-reload

echo "==> Removing venv: $HOME/venvs/$SERVICE_NAME"
rm -rf "$HOME/venvs/$SERVICE_NAME"

if [[ "$SKIP_RUNNER" == false ]]; then
  echo "==> Removing self-hosted runner at $RUNNER_DIR"
  if [[ -d "$RUNNER_DIR" ]]; then
    (cd "$RUNNER_DIR" && sudo ./svc.sh stop) 2>/dev/null || true
    (cd "$RUNNER_DIR" && sudo ./svc.sh uninstall) 2>/dev/null || true
    (cd "$RUNNER_DIR" && ./config.sh remove --token "$REMOVE_TOKEN")
    rm -rf "$RUNNER_DIR"
  else
    echo "    $RUNNER_DIR not found, skipping."
  fi
else
  echo "==> Skipping runner removal (--skip-runner)"
fi

if [[ "$SKIP_MYSQL" == false ]]; then
  echo "==> Removing MySQL"
  if [[ -n "$DB_NAME" || -n "$DB_USER" ]] && command -v mysql >/dev/null 2>&1; then
    sql=""
    [[ -n "$DB_NAME" ]] && sql+="DROP DATABASE IF EXISTS \`$DB_NAME\`; "
    [[ -n "$DB_USER" ]] && sql+="DROP USER IF EXISTS '$DB_USER'@'localhost'; "
    sql+="FLUSH PRIVILEGES;"
    sudo mysql -e "$sql" 2>/dev/null || true
  fi
  sudo apt purge -y 'mysql-server*' 'mysql-client*' mysql-common 2>/dev/null || true
  sudo rm -rf /etc/mysql /var/lib/mysql /var/log/mysql
else
  echo "==> Skipping MySQL removal (--skip-mysql)"
fi

if [[ "$SKIP_NGINX" == false ]]; then
  echo "==> Removing Nginx"
  sudo systemctl stop nginx 2>/dev/null || true
  sudo systemctl disable nginx 2>/dev/null || true
  sudo apt purge -y nginx nginx-common nginx-core 2>/dev/null || true
  sudo rm -rf /etc/nginx /var/log/nginx
else
  echo "==> Skipping Nginx removal (--skip-nginx)"
fi

sudo apt autoremove -y

echo "==> Done. VM reset to bare state."
