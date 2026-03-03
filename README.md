# GitLab → GitHub Mirror

> My wife told me: Github > GitLab!!!!
> I said: Why not use both baby 😄

Mirrors **all your GitLab repositories** (with full commit history, all branches and tags) to GitHub.
Available in both **Bash** (Linux/macOS) and **PowerShell** (Windows).

---

## Project Structure

\```
gitlab-github-mirror/
├── .gitignore
├── README.md
├── mirror.sh       ← Run this on Linux/macOS
├── config.env      ← Your secrets (bash)
└── mirror.ps1      ← Run this on Windows
├── config.ps1      ← Your secrets (PowerShell)
\```

---

## Requirements

### Bash
| Tool | Install (Ubuntu/Debian) | Install (macOS) |
|------|------------------------|-----------------|
| `git` | `sudo apt install git` | `brew install git` |
| `curl` | `sudo apt install curl` | `brew install curl` |
| `jq` | `sudo apt install jq` | `brew install jq` |

### PowerShell
- PowerShell 5.1+ (built into Windows) or [PowerShell 7+](https://github.com/PowerShell/PowerShell)
- `git` installed and in PATH
- No extra tools needed (`jq`, `curl` not required)

---

## Setup

### 1. Create your tokens

| Token | Where to create | Required scopes |
|-------|----------------|-----------------|
| **GitLab** | GitLab → Settings → Access Tokens | `read_api`, `read_repository` |
| **GitHub** | GitHub → Settings → Developer Settings → PAT | `repo` (full) |

### 2. Fill in your config

**Bash** → edit `config.env`
\```bash
nano config.env
\```

**PowerShell** → edit `powershell/config.ps1`
\```powershell
notepad config.ps1
\```

### 3. Run it!

**Bash (Linux/macOS):**
\```bash
chmod +x mirror.sh
./mirror.sh
\```

**PowerShell (Windows):**
\```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\mirror.ps1
\```

---

## What it does

1. Fetches **all your GitLab projects** (paginated, handles 100+ repos)
2. For each project:
   - Does a **bare `git clone --mirror`** (ALL branches, tags, full history)
   - Creates the GitHub repo if it doesn't exist
   - Pushes everything with **`git push --mirror`**
3. Prints a summary of successes and failures

## Re-running / Syncing

Run the script again anytime — it will **update** existing GitHub repos with new commits.

## Options in config files

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROR_PRIVATE` | `true` | Mirror private GitLab repos |
| `MIRROR_ARCHIVED` | `false` | Mirror archived repos |
| `TEMP_DIR` | `/tmp/gitlab-mirror` | Temp clone directory |

> 🔒 **Security:** Both `config.env` and `powershell/config.ps1` are in `.gitignore` — your tokens will never be committed.