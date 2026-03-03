# GitLab → GitHub Mirror

> My wife told me: Github > GitLab!!!!
> I said: Why not use both baby 😄

Mirrors **all your GitLab repositories** (with full commit history, all branches and tags) to GitHub.

## Requirements

- `bash` 4+
- `git`
- `curl`
- `jq`

Install on Ubuntu/Debian:
\```bash
sudo apt install git curl jq
\```

Install on macOS:
\```bash
brew install git curl jq
\```

## Setup

### 1. Clone this repo
\```bash
git clone https://github.com/YOUR_USERNAME/gitlab-github-mirror.git
cd gitlab-github-mirror
\```

### 2. Create your tokens

| Token | Where to create | Required scopes |
|-------|----------------|-----------------|
| **GitLab** | GitLab → Settings → Access Tokens | `read_api`, `read_repository` |
| **GitHub** | GitHub → Settings → Developer Settings → PAT | `repo` (full) |

### 3. Fill in config.env
\```bash
cp config.env config.env   # already exists, just edit it
nano config.env
\```

### 4. Make the script executable
\```bash
chmod +x mirror.sh
\```

### 5. Run it!
\```bash
./mirror.sh
\```

## What it does

1. Fetches **all your GitLab projects** (paginated, handles 100+ repos)
2. For each project:
   - Does a **bare `git clone --mirror`** (captures ALL branches, tags, and full history)
   - Creates the GitHub repo if it doesn't exist
   - Pushes everything with **`git push --mirror`**
3. Prints a summary of successes and failures

## Re-running / Syncing

Just run `./mirror.sh` again anytime — it will **update** existing GitHub repos with new commits.

## Options in config.env

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRROR_PRIVATE` | `true` | Mirror private GitLab repos |
| `MIRROR_ARCHIVED` | `false` | Mirror archived repos |
| `TEMP_DIR` | `/tmp/gitlab-mirror` | Temp clone directory |