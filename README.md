# פרויקט סיום – Student Portal

## תיאור הפרויקט

בפרויקט זה תבנו CI/CD pipeline מלא לאפליקציית **Student Portal** – API שמנהל רשימת סטודנטים.  
הפרויקט מחולק ל-3 שלבים שמתפתחים בהדרגה – מ-CI בסיסי ועד deploy אמיתי על VM עם Nginx.

קבצי האפליקציה כבר נמצאים ב-repo – תפקידכם הוא לכתוב את ה-workflows ולהגדיר את הסביבה.

---

## טופולוגיה

```
┌─────────────────────────────────────────────────────────┐
│                     GitHub                              │
│                                                         │
│   ┌──────────┐    push/PR    ┌─────────────────────┐   │
│   │  Student  │ ──────────► │   GitHub Actions     │   │
│   │  (Dev)   │              │   Workflow           │   │
│   └──────────┘              └──────────┬──────────┘   │
│                                        │               │
│                              ┌─────────▼──────────┐   │
│                              │  GitHub Runner      │   │
│                              │  (שלב א)           │   │
│                              └────────────────────┘   │
└────────────────────────────────────────────────────────┘
                                         │
                              (שלבים ב-ג)│
                                         ▼
                     ┌───────────────────────────────────┐
                     │           Linux VM                │
                     │                                   │
                     │  ┌─────────────────────────────┐ │
                     │  │  Self-Hosted Runner          │ │
                     │  └─────────────────────────────┘ │
                     │                                   │
                     │  ┌──────────┐   ┌─────────────┐  │
                     │  │  Nginx   │──►│  FastAPI    │  │
                     │  │  :80     │   │  :8000      │  │
                     │  └──────────┘   └──────┬──────┘  │
                     │                        │          │
                     │                 ┌──────▼──────┐  │
                     │                 │   MySQL DB  │  │
                     │                 └─────────────┘  │
                     └───────────────────────────────────┘
```

---

## Pipeline מלא (שלב ב)

```
push to main
     │
     ▼
┌─────────┐     ┌─────────┐     ┌──────────┐
│  test   │────►│  build  │────►│  deploy  │
│         │     │         │     │          │
│ pytest  │     │ uvicorn │     │ git pull │
│         │     │ + curl  │     │ restart  │
│         │     │ health  │     │ service  │
└─────────┘     └─────────┘     └──────────┘
```

---

## מבנה ה-Repo

```
04-project/
├── project.md          ← המסמך הזה
├── app/
│   ├── main.py         ← גרסת JSON (שלב א)
│   └── main_v2_mysql.py ← גרסת MySQL (שלב ב)
├── tests/
│   └── test_main.py    ← 9 טסטים
└── requirements.txt    ← תלויות Python
```

> **שימו לב:** `.github/workflows/` לא קיים ב-repo – **אתם יוצרים אותו** כחלק מהפרויקט.

---

## שלב א – CI על GitHub Runner (JSON)

### מה עושים?

מגדירים CI pipeline שרץ על GitHub runner. כל push ל-`main` מפעיל:
1. התקנת תלויות
2. הרצת טסטים
3. הרצת השרת ובדיקת health

### הוראות הגדרה

**1. Clone את ה-Repo**

```bash
git clone https://github.com/<your-username>/<repo-name>.git
cd <repo-name>/04-project
```

**2. צרו את תיקיית ה-workflow**

```bash
mkdir -p .github/workflows
```

**3. צרו את הקובץ `ci.yml`**

```bash
touch .github/workflows/ci.yml
```

**4. הכניסו את התוכן הבא ל-`ci.yml`:**

```yaml
name: Student Portal CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install dependencies
        run: |
          pip install -r 04-project/requirements.txt

      - name: Run tests
        run: |
          cd 04-project
          pytest tests/ -v

  build:
    runs-on: ubuntu-latest
    needs: test

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install dependencies
        run: |
          pip install -r 04-project/requirements.txt

      - name: Start server and health check
        run: |
          cd 04-project
          uvicorn app.main:app --host 0.0.0.0 --port 8000 &
          sleep 3
          curl -f http://localhost:8000/health
```

**5. Push ל-GitHub**

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI workflow - stage A"
git push origin main
```

**6. בדקו ב-GitHub Actions שהפרויקט עובר ✅**

### API Endpoints

| Method | Path | תיאור |
|--------|------|--------|
| GET | `/` | הודעת ברוכים הבאים |
| GET | `/health` | בדיקת תקינות השרת |
| GET | `/students` | קבלת כל הסטודנטים |
| POST | `/students` | הוספת סטודנט |
| PUT | `/students/{id}` | עדכון סטודנט |
| DELETE | `/students/{id}` | מחיקת סטודנט |

---

## שלב ב – MySQL + Self-Hosted Runner + Deploy

### מה עושים?

מעבירים את האפליקציה לעבוד מול MySQL, מגדירים self-hosted runner על ה-VM שלכם, ומוסיפים `deploy` job שמעדכן את הקוד ומפעיל מחדש את השרת.

### דרישות מוקדמות

- VM עם Linux (Ubuntu 20.04+)
- Python 3.11+ מותקן על ה-VM
- MySQL מותקן ופועל על ה-VM

### הוראות הגדרה

**1. הגדרת MySQL על ה-VM**

```bash
# התחברות ל-MySQL
mysql -u root -p

# יצירת DB ומשתמש
CREATE DATABASE student_portal;
CREATE USER 'student_user'@'localhost' IDENTIFIED BY 'your_password';
GRANT ALL PRIVILEGES ON student_portal.* TO 'student_user'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

**2. יצירת טבלת הסטודנטים**

```sql
USE student_portal;

CREATE TABLE students (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    grade VARCHAR(10)
);
```

**3. התקנת Self-Hosted Runner**

ב-GitHub repo שלכם: `Settings → Actions → Runners → New self-hosted runner`  
בחרו **Linux** ועקבו אחר ההוראות שמופיעות, לדוגמה:

```bash
# הורדה
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64-2.319.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.319.0/actions-runner-linux-x64-2.319.0.tar.gz
tar xzf ./actions-runner-linux-x64-2.319.0.tar.gz

# הגדרה (הכניסו את הטוקן שמופיע ב-GitHub)
./config.sh --url https://github.com/<your-username>/<repo-name> --token <YOUR_TOKEN>

# הרצה כ-service
sudo ./svc.sh install
sudo ./svc.sh start
```

**4. הגדרת Secrets ב-GitHub**

ב-GitHub repo: `Settings → Secrets and variables → Actions → New repository secret`

הוסיפו את ה-secrets הבאים:

| Secret Name | ערך לדוגמה |
|-------------|------------|
| `DB_HOST` | `localhost` |
| `DB_USER` | `student_user` |
| `DB_PASSWORD` | `your_password` |
| `DB_NAME` | `student_portal` |

**5. יצירת systemd service על ה-VM**

```bash
sudo nano /etc/systemd/system/student-portal.service
```

הכניסו את התוכן הבא:

```ini
[Unit]
Description=Student Portal FastAPI
After=network.target mysql.service

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/<repo-name>/04-project
Environment="DB_HOST=localhost"
Environment="DB_USER=student_user"
Environment="DB_PASSWORD=your_password"
Environment="DB_NAME=student_portal"
ExecStart=/usr/bin/python3 -m uvicorn app.main_v2_mysql:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable student-portal
sudo systemctl start student-portal

# בדיקה
sudo systemctl status student-portal
curl http://localhost:8000/health
```

**6. הרשאת sudo ללא סיסמה ל-deploy job**

ה-self-hosted runner רץ כ-service ברקע, ללא terminal אינטראקטיבי. לכן כשה-`deploy` job מריץ `sudo systemctl restart student-portal`, אם `sudo` דורש סיסמה – ה-step ייתקע או ייכשל. יש להרשות למשתמש שמריץ את ה-runner (למשל `ubuntu`) להריץ את הפקודה הספציפית הזו בלי סיסמה:

```bash
sudo visudo -f /etc/sudoers.d/student-portal
```

הכניסו שורה אחת בדיוק (התאימו את שם המשתמש לפי מי שמריץ את ה-runner):

```
ubuntu ALL=(ALL) NOPASSWD: /bin/systemctl restart student-portal
```

בדיקה שזה עבד:

```bash
sudo -n systemctl restart student-portal && echo "עובד בלי סיסמה"
```

**7. עדכון `ci.yml` לשלב ב:**

```yaml
name: Student Portal CI/CD

on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install dependencies
        run: |
          pip install -r 04-project/requirements.txt

      - name: Run tests
        run: |
          cd 04-project
          pytest tests/ -v

  build:
    runs-on: ubuntu-latest
    needs: test

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install dependencies
        run: |
          pip install -r 04-project/requirements.txt

      - name: Start server and health check
        run: |
          cd 04-project
          uvicorn app.main:app --host 0.0.0.0 --port 8000 &
          sleep 3
          curl -f http://localhost:8000/health

  deploy:
    runs-on: self-hosted
    needs: build

    env:
      DB_HOST: ${{ secrets.DB_HOST }}
      DB_USER: ${{ secrets.DB_USER }}
      DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
      DB_NAME: ${{ secrets.DB_NAME }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          pip3 install -r 04-project/requirements.txt
          pip3 install mysql-connector-python

      - name: Restart service
        run: |
          sudo systemctl restart student-portal

      - name: Health check
        run: |
          sleep 3
          curl -f http://localhost:8000/health
```

**8. Push ובדיקה**

```bash
git add .github/workflows/ci.yml
git commit -m "Add deploy job - stage B"
git push origin main
```

בדקו ב-GitHub Actions שה-`deploy` job רץ על ה-runner שלכם ✅

---

## שלב ג – Nginx Reverse Proxy

### מה עושים?

מוסיפים Nginx שיעביר תעבורה מפורט 80 לאפליקציה בפורט 8000. בסוף שלב זה האפליקציה נגישה דרך `http://<VM-IP>/` בלי לציין פורט.

### הוראות הגדרה

**1. התקנת Nginx**

```bash
sudo apt update
sudo apt install nginx -y
```

**2. הגדרת Nginx כ-reverse proxy**

```bash
sudo nano /etc/nginx/sites-available/student-portal
```

הכניסו את התוכן הבא:

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

**3. הפעלת ה-site**

```bash
# הפעלת ה-site
sudo ln -s /etc/nginx/sites-available/student-portal /etc/nginx/sites-enabled/

# מחיקת ה-default site
sudo rm /etc/nginx/sites-enabled/default

# בדיקת תקינות
sudo nginx -t

# הפעלה מחדש
sudo systemctl restart nginx
sudo systemctl enable nginx
```

**4. בדיקה שהכל עובד**

```bash
# בדיקה דרך פורט 80
curl http://localhost/health

# בדיקה חיצונית (מהמחשב שלכם)
curl http://<VM-IP>/health
```

**5. עדכון ה-workflow – הוספת health check דרך פורט 80**

עדכנו את ה-`deploy` job ב-`ci.yml`, שנו את ה-Health check step:

```yaml
      - name: Health check via Nginx
        run: |
          sleep 3
          curl -f http://localhost/health
```

**6. Push ובדיקה סופית**

```bash
git add .github/workflows/ci.yml
git commit -m "Update health check via Nginx - stage C"
git push origin main
```

פתחו בדפדפן: `http://<VM-IP>/students` ✅

---

## טבלת בדיקות – Checklist לסיום

| שלב | בדיקה | עובר? |
|-----|--------|-------|
| א | `pytest` עובר בכל הטסטים | ☐ |
| א | `build` job מצליח עם curl לפורט 8000 | ☐ |
| א | ה-workflow מופעל אוטומטית על push | ☐ |
| ב | `deploy` job רץ על self-hosted runner | ☐ |
| ב | ה-service קם מחדש אחרי deploy | ☐ |
| ב | Secrets לא מופיעים ב-logs | ☐ |
| ב | `POST /students` שומר ב-MySQL | ☐ |
| ג | `curl http://localhost/health` עובר דרך פורט 80 | ☐ |
| ג | הגישה ל-API עובדת מהדפדפן ללא פורט | ☐ |

---

## פקודות שימושיות

```bash
# בדיקת סטטוס ה-service
sudo systemctl status student-portal

# צפייה ב-logs של ה-service
sudo journalctl -u student-portal -f

# בדיקת סטטוס Nginx
sudo systemctl status nginx

# בדיקת logs של Nginx
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# בדיקת self-hosted runner
cd ~/actions-runner
./svc.sh status
```

---

## הגשה

העלו לינק ל-GitHub repo שמכיל:
1. קובץ `.github/workflows/ci.yml` עם כל ה-jobs
2. Screenshot של GitHub Actions – כל ה-jobs ירוקים ✅
3. Screenshot של הדפדפן עם `http://<VM-IP>/students`
