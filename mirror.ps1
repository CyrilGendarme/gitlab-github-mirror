#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Logging ---------------------------------------------------------------
function Write-Header {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "     GitLab -> GitHub Mirror Tool           " -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step    ($msg) {
    Write-Host ""
    Write-Host "--------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $msg"                                        -ForegroundColor Cyan
    Write-Host "--------------------------------------------" -ForegroundColor Cyan
}
function Write-Info    ($msg) { Write-Host "[INFO]    $msg" -ForegroundColor Blue    }
function Write-Success ($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green   }
function Write-Warn    ($msg) { Write-Host "[WARNING] $msg" -ForegroundColor Yellow  }
function Write-Err     ($msg) { Write-Host "[ERROR]   $msg" -ForegroundColor Red     }

# --- Load Config -----------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.ps1"

if (-not (Test-Path $ConfigFile)) {
    Write-Err "config.ps1 not found. Please create it with your credentials."
    exit 1
}

. $ConfigFile   # Dot-source the config (imports all variables)

# --- Git Wrapper (suppresses stderr-as-error false positives) ---------------
function Invoke-Git {
    # Temporarily suspend Stop-on-error so git's stderr info messages
    # (e.g. "Cloning into...") are not treated as terminating errors.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git @args 2>&1 | ForEach-Object { Write-Host $_.ToString() }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git exited with code $LASTEXITCODE"
    }
}

# --- Dependency Check ------------------------------------------------------
function Test-Dependencies {
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        Write-Err "Missing dependency: 'git'. Please install it and ensure it is in PATH."
        exit 1
    }
    Write-Host "[OK] All dependencies found." -ForegroundColor Green
}

# --- GitLab API Helper -----------------------------------------------------
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

# --- GitHub API Helper -----------------------------------------------------
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
        return @{ error = $true; status = $_.Exception.Response.StatusCode.value__; message = $_.ToString() }
    }
}

# --- Fetch All GitLab Projects ---------------------------------------------
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
            if (-not $MIRROR_ARCHIVED -and $project.archived -eq $true)      { continue }
            if (-not $MIRROR_PRIVATE  -and $project.visibility -eq "private") { continue }

            $allProjects += $project
        }

        if ($response.Count -lt $perPage) { break }
        $page++

    } while ($true)

    return $allProjects
}

# --- Check if GitHub Repo Exists -------------------------------------------
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

# --- Create GitHub Repository ----------------------------------------------
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
        Write-Warn "Could not confirm creation of $RepoName."
        return $false
    }
}

# --- Mirror Single Repository ----------------------------------------------
function Invoke-MirrorRepository {
    param(
        [string]$GitLabUrl,
        [string]$RepoName,
        [string]$Description,
        [bool]$IsPrivate
    )

    Write-Step "Mirroring: $RepoName"

    $authGitLabUrl = $GitLabUrl -replace "https://", "https://oauth2:${GITLAB_TOKEN}@"
    $githubPushUrl = "https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${RepoName}.git"

    $repoDir = Join-Path $TEMP_DIR $RepoName

    # Clean up any previous attempt
    if (Test-Path $repoDir) {
        Remove-Item -Recurse -Force $repoDir
    }

    # Step 1: Clone bare from GitLab
    Write-Info "Cloning from GitLab (bare mirror)..."
    try {
        Invoke-Git clone --mirror $authGitLabUrl $repoDir
    } catch {
        Write-Err "Failed to clone $RepoName from GitLab. Skipping."
        return $false
    }

    # Step 2: Create GitHub repo if needed
    if (Test-GitHubRepo -RepoName $RepoName) {
        Write-Info "GitHub repo '$RepoName' already exists. Will update."
    }
    else {
        New-GitHubRepo -RepoName $RepoName -Description $Description -IsPrivate $IsPrivate
        Start-Sleep -Seconds 1
    }

    # Step 3: Push to GitHub
    Write-Info "Pushing to GitHub (all branches, tags, history)..."

    Push-Location $repoDir
    try {
        Invoke-Git remote set-url origin $githubPushUrl
        Invoke-Git push --mirror
        Write-Success "OK Mirrored: $RepoName"
        return $true
    } catch {
        Write-Err "FAILED to push: $RepoName"
        return $false
    } finally {
        Pop-Location
        if (Test-Path $repoDir) {
            Remove-Item -Recurse -Force $repoDir
        }
    }
}

# --- Main ------------------------------------------------------------------
function Main {
    Write-Header
    Test-Dependencies

    # Ensure temp directory exists
    if (-not (Test-Path $TEMP_DIR)) {
        New-Item -ItemType Directory -Path $TEMP_DIR | Out-Null
    }

    $projects = Get-GitLabProjects
    $total    = $projects.Count

    Write-Info "Found $total project(s) to mirror."

    if ($total -eq 0) {
        Write-Warn "No projects found. Check your GITLAB_TOKEN and GITLAB_USERNAME."
        exit 0
    }

    $successCount = 0
    $failedCount  = 0
    $failedRepos  = @()

    foreach ($project in $projects) {
        $name        = $project.path
        $httpUrl     = $project.http_url_to_repo
        $description = if ($project.description) { $project.description } else { "" }
        $visibility  = $project.visibility
        $isPrivate   = ($visibility -eq "private" -or $visibility -eq "internal")

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

    # Summary
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  SUMMARY"                                   -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  OK  Success: $successCount"                -ForegroundColor Green
    Write-Host "  !!  Failed:  $failedCount"                 -ForegroundColor Red

    if ($failedRepos.Count -gt 0) {
        Write-Host ""
        Write-Host "  Failed repositories:" -ForegroundColor Red
        foreach ($r in $failedRepos) {
            Write-Host "    - $r" -ForegroundColor Red
        }
    }

    Write-Host ""

    if (Test-Path $TEMP_DIR) {
        Remove-Item -Recurse -Force $TEMP_DIR
    }
}

# Entry Point
Main