#!/usr/bin/env bash
set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─── Load Config ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}[ERROR]${NC} config.env not found. Copy config.env and fill in your credentials."
  exit 1
fi

source "$CONFIG_FILE"

# ─── Dependency Check ───────────────────────────────────────────────
check_dependencies() {
  local deps=("git" "curl" "jq")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      echo -e "${RED}[ERROR]${NC} Missing dependency: '$dep'. Please install it."
      exit 1
    fi
  done
  echo -e "${GREEN}[OK]${NC} All dependencies found."
}

# ─── Logging ────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_step()    { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ─── Fetch All GitLab Projects ──────────────────────────────────────
fetch_gitlab_projects() {
  log_step "Fetching all GitLab projects for user: $GITLAB_USERNAME"

  local projects=()
  local page=1
  local per_page=100

  while true; do
    local response
    response=$(curl --silent --fail \
      --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "${GITLAB_URL}/api/v4/projects?membership=true&per_page=${per_page}&page=${page}&order_by=id&sort=asc")

    if [[ -z "$response" || "$response" == "[]" ]]; then
      break
    fi

    local count
    count=$(echo "$response" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
      break
    fi

    # Filter based on config options
    local filter='. | .[]'
    if [[ "$MIRROR_ARCHIVED" == "false" ]]; then
      filter+=' | select(.archived == false)'
    fi
    if [[ "$MIRROR_PRIVATE" == "false" ]]; then
      filter+=' | select(.visibility != "private")'
    fi

    local page_projects
    page_projects=$(echo "$response" | jq -c "[${filter}]")
    projects+=("$page_projects")

    log_info "Fetched page $page ($count projects)"

    if [[ "$count" -lt "$per_page" ]]; then
      break
    fi

    ((page++))
  done

  # Merge all pages into one JSON array
  printf '%s\n' "${projects[@]}" | jq -s 'add // []'
}

project_has_recent_commit() {
  local project_id="$1"
  local encoded_since
  encoded_since=$(printf '%s' "$MIRROR_SINCE_DATE" | jq -sRr @uri)

  local response
  response=$(curl --silent --fail \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/repository/commits?since=${encoded_since}&per_page=1") || return 1

  [[ "$(echo "$response" | jq 'length')" -gt 0 ]]
}

# ─── Check if GitHub Repo Exists ────────────────────────────────────
github_repo_exists() {
  local repo_name="$1"
  local status_code
  status_code=$(curl --silent --output /dev/null --write-out "%{http_code}" \
    --header "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_USERNAME/$repo_name")
  [[ "$status_code" == "200" ]]
}

# ─── Create GitHub Repository ───────────────────────────────────────
create_github_repo() {
  local repo_name="$1"
  local description="$2"
  local is_private="$3"

  log_info "Creating GitHub repo: $repo_name (private=$is_private)"

  local response
  response=$(curl --silent \
    --header "Authorization: token $GITHUB_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{
      \"name\": \"$repo_name\",
      \"description\": $(echo "$description" | jq -R .),
      \"private\": $is_private,
      \"auto_init\": false
    }" \
    "https://api.github.com/user/repos")

  local errors
  errors=$(echo "$response" | jq -r '.errors // empty | .[].message // empty' 2>/dev/null || true)

  if [[ -n "$errors" ]]; then
    log_warning "GitHub repo creation issue: $errors"
  else
    log_success "Created GitHub repo: $repo_name"
  fi
}

# ─── Mirror Single Repository ───────────────────────────────────────
mirror_repository() {
  local gitlab_url="$1"
  local repo_name="$2"
  local description="$3"
  local is_private="$4"

  log_step "Mirroring: $repo_name"

  # Inject token into GitLab clone URL
  local auth_gitlab_url
  auth_gitlab_url=$(echo "$gitlab_url" | sed "s|https://|https://oauth2:${GITLAB_TOKEN}@|")

  # GitHub push URL with token
  local github_push_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${repo_name}.git"

  local repo_dir="${TEMP_DIR}/${repo_name}"

  # Clean up any previous attempt
  rm -rf "$repo_dir"

  # ── Step 1: Clone from GitLab (bare, all branches + tags) ──
  log_info "Cloning from GitLab (bare mirror)..."
  if ! git clone --mirror "$auth_gitlab_url" "$repo_dir"; then
    log_error "Failed to clone $repo_name from GitLab. Skipping."
    return 1
  fi

  # ── Step 2: Create GitHub repo if it doesn't exist ──
  if github_repo_exists "$repo_name"; then
    log_info "GitHub repo '$repo_name' already exists. Will update."
  else
    create_github_repo "$repo_name" "$description" "$is_private"
    sleep 1 # Give GitHub a moment
  fi

  # ── Step 3: Push everything to GitHub ──
  log_info "Pushing to GitHub (all branches, tags, history)..."
  cd "$repo_dir"

  git remote set-url origin "$github_push_url"

  if git push --mirror; then
    log_success "✔ Mirrored: $repo_name"
  else
    log_error "✘ Failed to push: $repo_name"
    cd "$SCRIPT_DIR"
    return 1
  fi

  cd "$SCRIPT_DIR"
  rm -rf "$repo_dir"
}

# ─── Main ────────────────────────────────────────────────────────────
main() {
  echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     GitLab → GitHub Mirror Tool          ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}\n"

  check_dependencies

  mkdir -p "$TEMP_DIR"

  # Fetch all projects from GitLab
  local projects
  projects=$(fetch_gitlab_projects)

  local total
  total=$(echo "$projects" | jq 'length')

  if [[ -n "${MIRROR_SINCE_DATE:-}" ]]; then
    if ! jq -nr --arg d "$MIRROR_SINCE_DATE" '$d | fromdateiso8601' >/dev/null 2>&1; then
      log_error "Invalid MIRROR_SINCE_DATE format in config.env. Use ISO-8601, e.g. 2026-01-01T00:00:00Z"
      exit 1
    fi

    log_step "Filtering projects with at least one commit since: $MIRROR_SINCE_DATE"
    local filtered_projects="[]"

    while IFS= read -r project; do
      local project_id
      project_id=$(echo "$project" | jq -r '.id')
      if project_has_recent_commit "$project_id"; then
        filtered_projects=$(jq -c --argjson item "$project" '. + [$item]' <<< "$filtered_projects")
      fi
    done < <(echo "$projects" | jq -c '.[]')

    projects="$filtered_projects"
    total=$(echo "$projects" | jq 'length')
  fi

  log_info "Found $total project(s) to mirror."

  if [[ "$total" -eq 0 ]]; then
    log_warning "No projects found. Check your GITLAB_TOKEN and GITLAB_USERNAME."
    exit 0
  fi

  # Stats
  local success=0
  local failed=0
  local failed_repos=()

  # Loop through each project
  while IFS= read -r project; do
    local name http_url description visibility is_private

    name=$(echo "$project"        | jq -r '.path')            # Use path (slug) as repo name
    http_url=$(echo "$project"    | jq -r '.http_url_to_repo')
    description=$(echo "$project" | jq -r '.description // ""')
    visibility=$(echo "$project"  | jq -r '.visibility')

    # Map GitLab visibility → GitHub private flag
    if [[ "$visibility" == "private" || "$visibility" == "internal" ]]; then
      is_private="true"
    else
      is_private="false"
    fi

    if mirror_repository "$http_url" "$name" "$description" "$is_private"; then
      ((success++))
    else
      ((failed++))
      failed_repos+=("$name")
    fi

  done < <(echo "$projects" | jq -c '.[]')

  # ── Summary ──
  echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  SUMMARY${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  ✔ Success: $success${NC}"
  echo -e "${RED}  ✘ Failed:  $failed${NC}"

  if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo -e "\n${RED}  Failed repositories:${NC}"
    for r in "${failed_repos[@]}"; do
      echo -e "    - $r"
    done
  fi

  echo ""
  rm -rf "$TEMP_DIR"
}

main "$@"