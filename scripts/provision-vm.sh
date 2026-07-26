#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="student-portal"
APP_MODULE="app.main_v2_mysql:app"
PORT=8000
DB_NAME="student_portal"
DB_USER="student_user"
DB_PASSWORD="${DB_PASSWORD:-}"
RUNNER_DIR="$HOME/actions-runner"
RUNNER_USER="$(whoami)"
RUNNER_VERSION=""
REPO=""
WORKING_DIR=""
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
SKIP_MYSQL=false
SKIP_NGINX=false
SKIP_RUNNER=false
SKIP_VENV=false
SKIP_SERVICE=false
ASSUME_YES=false

usage() {
  cat <<USAGE
Usage: $0 [options]

Provisions a VM with the CI/CD topology: self-hosted runner + venv +
systemd app service + MySQL + Nginx reverse proxy. Reusable across
projects that share this topology - override the defaults per project.

Options:
  --service <name>        systemd service name (default: student-portal)
  --app-module <module>   uvicorn target, e.g. app.main:app (default: app.main_v2_mysql:app)
  --port <port>           app port behind Nginx (default: 8000)

  --db-name <name>        MySQL database name (default: student_portal)
  --db-user <name>        MySQL user (default: student_user)
  --db-password <pass>    MySQL password (or set DB_PASSWORD env var, or omit to be prompted)

  --repo <owner/name>     GitHub repo, e.g. eyalyehia/ci-cd-project (needed for runner + default working
                          dir; omit to be prompted, unless --skip-runner and --working-dir are both set)
  --runner-token <token>  runner registration token, freshly generated per run - omit to be prompted
                          (or set RUNNER_TOKEN env var). Get one with:
                          gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token
  --runner-dir <path>     runner install dir (default: \$HOME/actions-runner)
  --runner-version <ver>  runner release version, e.g. 2.336.0 (default: auto-detect latest)
  --working-dir <path>    override the systemd WorkingDirectory (default: derived from --repo)

  --skip-mysql            don't install/configure MySQL
  --skip-nginx            don't install/configure Nginx
  --skip-runner           don't install/register the self-hosted runner
  --skip-venv             don't (re)create the Python venv
  --skip-service          don't create the systemd service

  -y, --yes               don't ask for confirmation
  -h, --help              show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE_NAME="$2"; shift 2 ;;
    --app-module) APP_MODULE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --runner-token) RUNNER_TOKEN="$2"; shift 2 ;;
    --runner-dir) RUNNER_DIR="$2"; shift 2 ;;
    --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
    --working-dir) WORKING_DIR="$2"; shift 2 ;;
    --skip-mysql) SKIP_MYSQL=true; shift ;;
    --skip-nginx) SKIP_NGINX=true; shift ;;
    --skip-runner) SKIP_RUNNER=true; shift ;;
    --skip-venv) SKIP_VENV=true; shift ;;
    --skip-service) SKIP_SERVICE=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ( "$SKIP_RUNNER" == false || "$SKIP_SERVICE" == false ) && -z "$REPO" ]]; then
  read -rp "GitHub repo (owner/name), e.g. eyalyehia/ci-cd-project: " REPO
fi

if [[ "$SKIP_RUNNER" == false && -z "$RUNNER_TOKEN" ]]; then
  read -rsp "Runner registration token (Settings > Actions > Runners > New self-hosted runner, or: gh api -X POST repos/$REPO/actions/runners/registration-token --jq .token): " RUNNER_TOKEN
  echo
fi

if [[ -z "$WORKING_DIR" && -n "$REPO" ]]; then
  repo_name="${REPO##*/}"
  WORKING_DIR="$RUNNER_DIR/_work/$repo_name/$repo_name"
fi

if [[ "$SKIP_SERVICE" == false && -z "$WORKING_DIR" ]]; then
  echo "Error: need --repo (to derive WorkingDirectory) or --working-dir unless --skip-service." >&2
  exit 1
fi

if [[ ( "$SKIP_MYSQL" == false || "$SKIP_SERVICE" == false ) && -z "$DB_PASSWORD" ]]; then
  read -rsp "MySQL password for '$DB_USER': " DB_PASSWORD
  echo
fi

if [[ "$ASSUME_YES" == false ]]; then
  echo "This will provision on this VM:"
  [[ "$SKIP_MYSQL" == false ]] && echo "  - MySQL: database '$DB_NAME', user '$DB_USER', table 'students'"
  [[ "$SKIP_VENV" == false ]] && echo "  - Python venv at \$HOME/venvs/$SERVICE_NAME"
  [[ "$SKIP_RUNNER" == false ]] && echo "  - Self-hosted runner at '$RUNNER_DIR' registered to $REPO"
  [[ "$SKIP_SERVICE" == false ]] && echo "  - systemd service '$SERVICE_NAME' (WorkingDirectory=$WORKING_DIR) + NOPASSWD sudoers rule"
  [[ "$SKIP_NGINX" == false ]] && echo "  - Nginx reverse proxy :80 -> :$PORT"
  read -rp "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

if [[ "$SKIP_MYSQL" == false ]]; then
  echo "==> MySQL"
  if ! command -v mysql >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y mysql-server
    sudo systemctl enable --now mysql
  fi
  sudo mysql -e "
    CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
    CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
    GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
    FLUSH PRIVILEGES;
    USE \`$DB_NAME\`;
    CREATE TABLE IF NOT EXISTS students (
      id INT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      email VARCHAR(100) UNIQUE NOT NULL,
      grade VARCHAR(10)
    );
  "
else
  echo "==> Skipping MySQL (--skip-mysql)"
fi

if [[ "$SKIP_VENV" == false ]]; then
  echo "==> Python venv"
  sudo apt-get update
  if ! sudo apt-get install -y python3-venv; then
    py_minor="$(python3 -c 'import sys; print(sys.version_info[1])')"
    sudo apt-get install -y "python3.${py_minor}-venv"
  fi
  python3 -m venv "$HOME/venvs/$SERVICE_NAME"
  if [[ -n "$WORKING_DIR" && -f "$WORKING_DIR/requirements.txt" ]]; then
    "$HOME/venvs/$SERVICE_NAME/bin/pip" install -r "$WORKING_DIR/requirements.txt"
    "$HOME/venvs/$SERVICE_NAME/bin/pip" install mysql-connector-python
  fi
else
  echo "==> Skipping venv (--skip-venv)"
fi

if [[ "$SKIP_RUNNER" == false ]]; then
  echo "==> Self-hosted runner"
  case "$(uname -m)" in
    x86_64) runner_arch="x64" ;;
    aarch64|arm64) runner_arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  if [[ -z "$RUNNER_VERSION" ]]; then
    RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
      | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')"
    if [[ -z "$RUNNER_VERSION" ]]; then
      echo "Error: couldn't auto-detect the latest runner version; pass --runner-version explicitly." >&2
      exit 1
    fi
    echo "    Using latest runner version: $RUNNER_VERSION"
  fi
  mkdir -p "$RUNNER_DIR"
  if [[ ! -f "$RUNNER_DIR/config.sh" ]]; then
    tarball="actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz"
    curl -o "$RUNNER_DIR/$tarball" -L \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"
    tar xzf "$RUNNER_DIR/$tarball" -C "$RUNNER_DIR"
  fi
  (cd "$RUNNER_DIR" && ./config.sh --url "https://github.com/$REPO" --token "$RUNNER_TOKEN" --unattended --replace)
  (cd "$RUNNER_DIR" && sudo ./svc.sh install && sudo ./svc.sh start)
else
  echo "==> Skipping runner (--skip-runner)"
fi

if [[ "$SKIP_SERVICE" == false ]]; then
  echo "==> systemd service: $SERVICE_NAME"
  sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null <<EOF
[Unit]
Description=$SERVICE_NAME
After=network.target mysql.service

[Service]
User=$RUNNER_USER
WorkingDirectory=$WORKING_DIR
Environment="DB_HOST=localhost"
Environment="DB_USER=$DB_USER"
Environment="DB_PASSWORD=$DB_PASSWORD"
Environment="DB_NAME=$DB_NAME"
ExecStart=$HOME/venvs/$SERVICE_NAME/bin/python -m uvicorn $APP_MODULE --host 0.0.0.0 --port $PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  sudoers_tmp="$(mktemp)"
  echo "$RUNNER_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $SERVICE_NAME" > "$sudoers_tmp"
  if sudo visudo -cf "$sudoers_tmp"; then
    sudo install -m 440 -o root -g root "$sudoers_tmp" "/etc/sudoers.d/$SERVICE_NAME"
  else
    echo "sudoers syntax check failed, not installing NOPASSWD rule" >&2
  fi
  rm -f "$sudoers_tmp"

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  if [[ -d "$WORKING_DIR" ]]; then
    sudo systemctl restart "$SERVICE_NAME"
  else
    echo "Note: $WORKING_DIR doesn't exist yet, so the service was enabled but not started."
    echo "It will come up once the deploy job checks out the repo and restarts it."
  fi
else
  echo "==> Skipping systemd service (--skip-service)"
fi

if [[ "$SKIP_NGINX" == false ]]; then
  echo "==> Nginx"
  sudo apt-get update
  sudo apt-get install -y nginx
  sudo tee "/etc/nginx/sites-available/$SERVICE_NAME" > /dev/null <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
  sudo ln -sf "/etc/nginx/sites-available/$SERVICE_NAME" "/etc/nginx/sites-enabled/$SERVICE_NAME"
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
  sudo systemctl restart nginx
  sudo systemctl enable nginx
else
  echo "==> Skipping Nginx (--skip-nginx)"
fi

echo "==> Done."
