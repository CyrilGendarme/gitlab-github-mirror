#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Colors / Logging ───────────────────────────────────────────────
function Write-Header {
    Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     GitLab → GitHub Mirror Tool          ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝`n" -ForegroundColor Cyan
}

function Write-Step    ($msg) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}
function Write-Info    ($msg) { Write-Host "[INFO]    $msg" -ForegroundColor Blue    }
function Write-Success ($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green   }
function Write-Warn    ($msg) { Write-Host "[WARNING] $msg" -ForegroundColor Yellow  }
function Write-Err     ($msg) { Write-Host "[ERROR]   $msg" -ForegroundColor Red     }

# ─── Load Config ────────────────────────────────────────────────────
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.ps1"

if (-not (Test-Path $ConfigFile)) {
    Write-Err "config.ps1 not found. Please create it with your credentials."
    exit 1
}

. $ConfigFile   # Dot-source the config (imports all variables)

# ─── Dependency Check ───────────────────────────────────────────────
function Test-Dependencies {
    $deps = @("git", "curl")
    foreach ($dep in $deps) {
        if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
            Write-Err "Missing dependency: '$dep'. Please install it."
            exit 1
        }
    }
    # PowerShell 5.1+ has Invoke-RestMethod / ConvertFrom-Json natively — no jq needed!
    Write-Host "[OK] All dependencies found." -ForegroundColor Green
}

# ─── GitLab API Helper ──────────────────────────────────────────────
function Invoke-GitLabApi {
    param([string]$Endpoint)

    $headers = @{ "PRIVATE-TOKEN" = $GITLAB_TOKEN }
    try {
        return Invoke-RestMethod -Uri "${GITLAB_URL}${Endpoint}" `
                                 -Headers $headers `
                                 -Method Get
    }
    catch {
        Write-Err "GitLab API call failed: $_"
        return $null
    }
}

# ─── GitHub API Helper ──────────────────────────────────────────────
function Invoke-GitHubApi {
    param(
        [string]$Endpoint,
        [string]$Method   = "Get",
        [hashtable]$Body  = $null
    )

    $headers = @{
        "Authorization" = "token $GITHUB_TOKEN"
        "Content-Type"  = "application/json"
        "User-Agent"    = "GitLab-Mirror-Script"
    }

    $params = @{
        Uri     = "https://api.github.com${Endpoint}"
        Headers = $headers
        Method  = $Method
    }

    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 5)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        # Return the error response instead of throwing
        $statusCode = $_.Exception.Response.StatusCode.value__
        return @{ error = $true; status = $statusCode; message = $_.ToString() }
    }
}

# ─── Fetch All GitLab Projects ──────────────────────────────────────
function Get-GitLabProjects {
    Write-Step "Fetching all GitLab projects for user: $GITLAB_USERNAME"

    $allProjects = @()
    $page        = 1
    $perPage     = 100

    do {
        $endpoint = "/api/v4/projects?membership=true&per_page=${perPage}&page=${page}&order_by=id&sort=asc"
        $response = Invoke-GitLabApi -Endpoint $endpoint

        if (-not $response -or $response.Count -eq 0) { break }

        Write-Info "Fetched page $page ($($response.Count) projects)"

        foreach ($project in $response) {
            # Filter archived
            if (-not $MIRROR_ARCHIVED -and $project.archived -eq $true) { continue }

            # Filter private
            if (-not $MIRROR_PRIVATE -and $project.visibility -eq "private") { continue }

            $allProjects += $project
        }

        if ($response.Count -lt $perPage) { break }
        $page++

    } while ($true)

    return $allProjects
}

# ─── Check if GitHub Repo Exists ────────────────────────────────────
function Test-GitHubRepo {
    param([string]$RepoName)

    $headers = @{
        "Authorization" = "token $GITHUB_TOKEN"
        "User-Agent"    = "GitLab-Mirror-Script"
    }

    try {
        $response = Invoke-WebRequest `
            -Uri "https://api.github.com/repos/$GITHUB_USERNAME/$RepoName" `
            -Headers $headers `
            -Method Get `
            -ErrorAction Stop
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

# ─── Create GitHub Repository ───────────────────────────────────────
function New-GitHubRepo {
    param(
        [string]$RepoName,
        [string]$Description,
        [bool]$IsPrivate
    )

    Write-Info "Creating GitHub repo: $RepoName (private=$IsPrivate)"

    $body = @{
        name        = $RepoName
        description = $Description
        private     = $IsPrivate
        auto_init   = $false
    }

    $response = Invoke-GitHubApi -Endpoint "/user/repos" -Method "Post" -Body $body

    if ($response.full_name) {
        Write-Success "Created GitHub repo: $($response.full_name)"
        return $true
    }
    else {
        Write-Warn "Could not confirm creation of $RepoName — it may already exist or there was an issue."
        return $false
    }
}

# ─── Mirror Single Repository ───────────────────────────────────────
function Invoke-MirrorRepository {
    param(
        [string]$GitLabUrl,
        [string]$RepoName,
        [string]$Description,
        [bool]$IsPrivate
    )

    Write-Step "Mirroring: $RepoName"

    # Inject token into GitLab clone URL
    $authGitLabUrl  = $GitLabUrl -replace "https://", "https://oauth2:${GITLAB_TOKEN}@"

    # GitHub push URL with token
    $githubPushUrl  = "https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${RepoName}.git"

    $repoDir = Join-Path $TEMP_DIR $RepoName

    # Clean up any previous attempt
    if (Test-Path $repoDir) {
        Remove-Item -Recurse -Force $repoDir
    }

    # ── Step 1: Clone from GitLab (bare mirror) ──
    Write-Info "Cloning from GitLab (bare mirror)..."
    git clone --mirror $authGitLabUrl $repoDir 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to clone $RepoName from GitLab. Skipping."
        return $false
    }

    # ── Step 2: Create GitHub repo if it doesn't exist ──
    if (Test-GitHubRepo -RepoName $RepoName) {
        Write-Info "GitHub repo '$RepoName' already exists. Will update."
    }
    else {
        New-GitHubRepo -RepoName $RepoName -Description $Description -IsPrivate $IsPrivate
        Start-Sleep -Seconds 1   # Give GitHub a moment
    }

    # ── Step 3: Push everything to GitHub ──
    Write-Info "Pushing to GitHub (all branches, tags, history)..."

    Push-Location $repoDir
    try {
        git remote set-url origin $githubPushUrl 2>&1
        git push --mirror 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Err "✘ Failed to push: $RepoName"
            return $false
        }

        Write-Success "✔ Mirrored: $RepoName"
        return $true
    }
    finally {
        Pop-Location
        # Clean up the temp clone
        if (Test-Path $repoDir) {
            Remove-Item -Recurse -Force $repoDir
        }
    }
}

# ─── Main ────────────────────────────────────────────────────────────
function Main {
    Write-Header
    Test-Dependencies

    # Ensure temp directory exists
    if (-not (Test-Path $TEMP_DIR)) {
        New-Item -ItemType Directory -Path $TEMP_DIR | Out-Null
    }

    # Fetch all GitLab projects
    $projects = Get-GitLabProjects
    $total    = $projects.Count

    Write-Info "Found $total project(s) to mirror."

    if ($total -eq 0) {
        Write-Warn "No projects found. Check your GITLAB_TOKEN and GITLAB_USERNAME."
        exit 0
    }

    # Stats
    $successCount = 0
    $failedCount  = 0
    $failedRepos  = @()

    foreach ($project in $projects) {
        $name        = $project.path                      # Use path/slug as repo name
        $httpUrl     = $project.http_url_to_repo
        $description = if ($project.description) { $project.description } else { "" }
        $visibility  = $project.visibility

        # Map GitLab visibility → GitHub private flag
        $isPrivate = ($visibility -eq "private" -or $visibility -eq "internal")

        $result = Invoke-MirrorRepository `
            -GitLabUrl   $httpUrl `
            -RepoName    $name `
            -Description $description `
            -IsPrivate   $isPrivate

        if ($result) {
            $successCount++
        }
        else {
            $failedCount++
            $failedRepos += $name
        }
    }

    # ── Summary ──
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  SUMMARY"                                   -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  ✔ Success: $successCount"                  -ForegroundColor Green
    Write-Host "  ✘ Failed:  $failedCount"                   -ForegroundColor Red

    if ($failedRepos.Count -gt 0) {
        Write-Host "`n  Failed repositories:" -ForegroundColor Red
        foreach ($r in $failedRepos) {
            Write-Host "    - $r" -ForegroundColor Red
        }
    }

    Write-Host ""

    # Final cleanup
    if (Test-Path $TEMP_DIR) {
        Remove-Item -Recurse -Force $TEMP_DIR
    }
}

# ── Entry Point ──
Main