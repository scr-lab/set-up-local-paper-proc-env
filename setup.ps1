#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Open Notebook + Ollama ローカル論文処理環境 自動セットアップスクリプト
.DESCRIPTION
    git clone → setup.ps1 の 1 コマンドで環境構築を完了します。
    - Ollama のインストール & モデルダウンロード
    - Docker Desktop のインストール
    - Open Notebook (Docker Compose) の起動
    - arXiv 自動取り込みスクリプトの依存パッケージインストール
.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Model gemma3:12b -SkipDocker
    .\setup.ps1 -Unattended
#>

[CmdletBinding()]
param(
    # 使用する Chat モデル（VRAM に合わせて変更）
    [ValidateSet(
        "llama3.1:8b",
        "llama3.1:8b-instruct-q4_K_M",
        "gemma3:12b",
        "gemma3:1b",
        "qwen2.5:14b"
    )]
    [string]$Model = "llama3.1:8b",

    # Docker Desktop がインストール済みの場合はスキップ
    [switch]$SkipDocker,

    # Ollama がインストール済みの場合はスキップ
    [switch]$SkipOllama,

    # 対話プロンプトをすべてスキップ（CI / 無人インストール用）
    [switch]$Unattended,

    # Open Notebook のデータ保存先（デフォルト: $HOME\open-notebook）
    [string]$InstallDir = "$HOME\open-notebook"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ────────────────────── ユーティリティ関数 ──────────────────────

function Write-Step  { param($n, $msg) Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg)     Write-Host "  ✓  $msg"   -ForegroundColor Green }
function Write-Warn  { param($msg)     Write-Host "  ⚠  $msg"   -ForegroundColor Yellow }
function Write-Fail  { param($msg)     Write-Host "  ✗  $msg"   -ForegroundColor Red }
function Write-Info  { param($msg)     Write-Host "     $msg"   -ForegroundColor Gray }

function Confirm-Continue {
    param([string]$Prompt = "続行しますか？ [Y/n]")
    if ($Unattended) { return $true }
    $ans = Read-Host $Prompt
    return ($ans -eq "" -or $ans -match "^[Yy]")
}

function Test-Command {
    param([string]$Cmd)
    return [bool](Get-Command $Cmd -ErrorAction SilentlyContinue)
}

function Wait-ForPort {
    param([int]$Port, [int]$TimeoutSec = 120, [string]$ServiceName = "サービス")
    Write-Info "$ServiceName の起動を待機中 (最大 ${TimeoutSec}s)..."
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("localhost", $Port)
            $tcp.Close()
            Write-Ok "$ServiceName がポート $Port で応答しました"
            return $true
        } catch {
            Start-Sleep -Seconds 3
            Write-Host "." -NoNewline
        }
    }
    Write-Host ""
    Write-Warn "$ServiceName がタイムアウトしました。手動確認が必要です。"
    return $false
}

function Get-WingetInstalled {
    param([string]$Id)
    $result = winget list --id $Id 2>&1
    return ($LASTEXITCODE -eq 0 -and $result -match $Id)
}

# ────────────────────── バナー ──────────────────────

Clear-Host
Write-Host @"
╔══════════════════════════════════════════════════════════════╗
║       Open Notebook + Ollama  ローカル論文環境セットアップ         ║
║                        研究室配布版 v1.0                         ║
╚══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Host ""
Write-Info "インストール先  : $InstallDir"
Write-Info "Chat モデル    : $Model"
Write-Info "Embed モデル   : nomic-embed-text"
Write-Host ""

if (-not $Unattended) {
    if (-not (Confirm-Continue "この設定でセットアップを開始します。よろしいですか？ [Y/n]")) {
        Write-Warn "セットアップをキャンセルしました。"
        exit 0
    }
}

# ────────────────────── Step 0: 前提チェック ──────────────────────

Write-Step "0/6" "前提条件チェック"

# OS バージョン
$osVer = [System.Environment]::OSVersion.Version
if ($osVer.Major -lt 10 -or ($osVer.Major -eq 10 -and $osVer.Build -lt 19041)) {
    Write-Fail "Windows 10 20H1 (Build 19041) 以降が必要です。現在: $osVer"
    exit 1
}
Write-Ok "OS: Windows Build $($osVer.Build)"

# PowerShell バージョン
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail "PowerShell 5.0 以降が必要です。"
    exit 1
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

# winget の確認
if (-not (Test-Command "winget")) {
    Write-Fail "winget が見つかりません。Microsoft Store から 'アプリ インストーラー' を更新してください。"
    exit 1
}
Write-Ok "winget: $(winget --version)"

# VRAM チェック（参考情報）
try {
    $gpu = Get-WmiObject Win32_VideoController | Select-Object -First 1
    $vramMB = [math]::Round($gpu.AdapterRAM / 1MB)
    Write-Info "GPU: $($gpu.Name)  VRAM: ${vramMB} MB"
    if ($vramMB -lt 6144) {
        Write-Warn "VRAM が 6 GB 未満です。軽量モデルの使用を推奨します（gemma3:1b など）。"
    }
} catch {
    Write-Info "GPU 情報の取得をスキップしました（問題ありません）。"
}

# インストール先ディレクトリ作成
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallDir\notebook_data" | Out-Null
Write-Ok "インストール先ディレクトリを確認: $InstallDir"

# ────────────────────── Step 1: Ollama ──────────────────────

Write-Step "1/6" "Ollama のインストール"

if ($SkipOllama) {
    Write-Warn "--SkipOllama が指定されました。インストールをスキップします。"
} elseif (Test-Command "ollama") {
    $ollamaVer = (ollama --version 2>&1) -replace "ollama version ", ""
    Write-Ok "Ollama は既にインストールされています: $ollamaVer"
} else {
    Write-Info "winget で Ollama をインストールしています..."
    winget install Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget でのインストールに失敗しました。手動でインストールしてください: https://ollama.com/download"
        exit 1
    }

    # PATH の再読み込み
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    Write-Ok "Ollama のインストールが完了しました。"
}

# Ollama サービス起動確認
$ollamaRunning = $false
try {
    $null = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
    $ollamaRunning = $true
    Write-Ok "Ollama は起動済みです (port 11434)"
} catch {
    Write-Info "Ollama を起動します..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5
        Write-Ok "Ollama が起動しました (port 11434)"
        $ollamaRunning = $true
    } catch {
        Write-Warn "Ollama の自動起動に失敗しました。タスクトレイから手動で起動してください。"
    }
}

# ────────────────────── Step 2: モデルのダウンロード ──────────────────────

Write-Step "2/6" "Ollama モデルのダウンロード"

if (-not $ollamaRunning) {
    Write-Warn "Ollama が起動していないためモデルのダウンロードをスキップします。"
    Write-Warn "後で手動実行: ollama pull $Model && ollama pull nomic-embed-text"
} else {
    $models = @($Model, "nomic-embed-text")
    $existing = (ollama list 2>&1) | Select-String -Pattern "NAME" -NotMatch

    foreach ($m in $models) {
        $shortName = $m -replace ":.*", ""
        if ($existing -match $shortName) {
            Write-Ok "モデル '$m' は取得済みです。スキップします。"
        } else {
            Write-Info "モデル '$m' をダウンロード中（サイズにより数分〜数十分かかります）..."
            ollama pull $m
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "モデル '$m' のダウンロード完了"
            } else {
                Write-Fail "モデル '$m' のダウンロードに失敗しました。"
                exit 1
            }
        }
    }
}

# ────────────────────── Step 3: Docker Desktop ──────────────────────

Write-Step "3/6" "Docker Desktop のインストール"

if ($SkipDocker) {
    Write-Warn "--SkipDocker が指定されました。インストールをスキップします。"
} elseif (Test-Command "docker") {
    $dockerVer = (docker --version) -replace "Docker version ", ""
    Write-Ok "Docker は既にインストールされています: $dockerVer"
} else {
    Write-Info "winget で Docker Desktop をインストールしています..."
    Write-Warn "Docker Desktop のインストール中は画面に GUI が表示されます。"
    winget install Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Docker Desktop のインストールに失敗しました。"
        Write-Info "手動インストール: https://www.docker.com/products/docker-desktop/"
        exit 1
    }

    # PATH 再読み込み
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    Write-Ok "Docker Desktop のインストールが完了しました。"
    Write-Warn "Docker Desktop を起動してからセットアップを続行します。"
    Write-Warn "タスクトレイの Docker アイコンが緑になるまでお待ちください..."

    if (-not $Unattended) {
        Read-Host "Docker Desktop が起動したら Enter を押してください"
    } else {
        Start-Sleep -Seconds 60
    }
}

# Docker 動作確認
Write-Info "Docker の動作確認中..."
$retry = 0
while ($retry -lt 5) {
    $result = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    $retry++
    Write-Info "Docker Engine の起動待ち... ($retry/5)"
    Start-Sleep -Seconds 10
}
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker が応答しません。Docker Desktop を起動してから再実行してください。"
    exit 1
}
Write-Ok "Docker Engine が起動しています。"

# ────────────────────── Step 4: docker-compose.yml の生成 ──────────────────────

Write-Step "4/6" "Open Notebook の設定ファイル生成"

$composeFile = "$InstallDir\docker-compose.yml"

# 暗号化キーの生成
$encKey = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
Write-Info "暗号化キーを生成しました。"

# docker-compose.yml を直接生成（curl 不要・確実）
$composeContent = @"
version: '3.8'

services:
  surrealdb:
    image: surrealdb/surrealdb:v2
    restart: unless-stopped
    command: start --user root --pass root memory
    ports:
      - "8000:8000"

  open_notebook:
    image: lfnovo/open_notebook:v1-latest
    restart: unless-stopped
    ports:
      - "8502:8502"
    environment:
      - OPEN_NOTEBOOK_ENCRYPTION_KEY=$encKey
      - SURREAL_URL=ws://surrealdb:8000/rpc
      - SURREAL_USER=root
      - SURREAL_PASSWORD=root
      - SURREAL_NAMESPACE=open_notebook
      - SURREAL_DATABASE=open_notebook
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
    volumes:
      - ./notebook_data:/app/data
    depends_on:
      - surrealdb
    extra_hosts:
      - "host.docker.internal:host-gateway"
"@

# 既存ファイルがある場合はバックアップ
if (Test-Path $composeFile) {
    $backup = "$composeFile.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $composeFile $backup
    Write-Warn "既存の docker-compose.yml をバックアップしました: $backup"
}

$composeContent | Set-Content -Path $composeFile -Encoding UTF8
Write-Ok "docker-compose.yml を生成しました: $composeFile"

# arXiv スクリプトと設定ファイルをコピー
$scriptSrc = Join-Path $PSScriptRoot "scripts\arxiv_fetcher.py"
$promptSrc = Join-Path $PSScriptRoot "prompts"

if (Test-Path $scriptSrc) {
    Copy-Item $scriptSrc "$InstallDir\arxiv_fetcher.py" -Force
    Write-Ok "arxiv_fetcher.py をコピーしました。"
}
if (Test-Path $promptSrc) {
    Copy-Item $promptSrc "$InstallDir\prompts" -Recurse -Force
    Write-Ok "プロンプトテンプレートをコピーしました。"
}

# ────────────────────── Step 5: Docker Compose 起動 ──────────────────────

Write-Step "5/6" "Open Notebook (Docker Compose) の起動"

Set-Location $InstallDir

Write-Info "最新イメージを取得しています..."
docker compose pull
if ($LASTEXITCODE -ne 0) {
    Write-Warn "イメージの取得でエラーが発生しましたが、続行します。"
}

Write-Info "コンテナを起動しています..."
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Fail "docker compose up に失敗しました。ログを確認してください:"
    Write-Info "  docker compose logs"
    exit 1
}

# ポート 8502 の起動待ち
$started = Wait-ForPort -Port 8502 -TimeoutSec 120 -ServiceName "Open Notebook"

# ────────────────────── Step 6: Python 依存関係（任意） ──────────────────────

Write-Step "6/6" "arXiv 取り込みスクリプトの依存パッケージ（任意）"

if (Test-Command "python") {
    Write-Info "Python が見つかりました。依存パッケージをインストールします..."
    python -m pip install --upgrade arxiv requests schedule --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "arxiv, requests, schedule をインストールしました。"
    } else {
        Write-Warn "pip install に失敗しました。後で手動実行: pip install arxiv requests schedule"
    }
} else {
    Write-Warn "Python が見つかりません。arXiv 自動取り込みを使う場合は Python をインストールしてください。"
    Write-Info "  winget install Python.Python.3.11"
}

# ────────────────────── 完了メッセージ ──────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                  🎉  セットアップ完了！                        ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  📂 インストール先      : $InstallDir" -ForegroundColor White
Write-Host "  🌐 Open Notebook URL  : http://localhost:8502" -ForegroundColor White
Write-Host "  🤖 Chat モデル        : $Model" -ForegroundColor White
Write-Host "  📐 Embed モデル       : nomic-embed-text" -ForegroundColor White
Write-Host ""
Write-Host "  ── 次のステップ ───────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  1. ブラウザで http://localhost:8502 を開く" -ForegroundColor White
Write-Host "  2. 左ペイン「モデル」→ Ollama を追加" -ForegroundColor White
Write-Host "     URL: http://host.docker.internal:11434" -ForegroundColor Gray
Write-Host "  3. Language モデル: $Model" -ForegroundColor Gray
Write-Host "     Embedding モデル: nomic-embed-text:latest" -ForegroundColor Gray
Write-Host "  4. 論文 PDF をアップロードしてチャット開始！" -ForegroundColor White
Write-Host ""
Write-Host "  ── arXiv 自動取り込み ──────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  cd $InstallDir" -ForegroundColor Gray
Write-Host "  python arxiv_fetcher.py --dry-run   # 動作確認" -ForegroundColor Gray
Write-Host "  python arxiv_fetcher.py             # 実際に取り込み" -ForegroundColor Gray
Write-Host ""
Write-Host "  ── 停止・再起動 ────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  cd $InstallDir && docker compose stop" -ForegroundColor Gray
Write-Host "  cd $InstallDir && docker compose up -d" -ForegroundColor Gray
Write-Host ""

if ($started) {
    # ブラウザを自動で開く
    if (Confirm-Continue "ブラウザで Open Notebook を開きますか？ [Y/n]") {
        Start-Process "http://localhost:8502"
    }
}

Write-Host "  詳しいドキュメント: リポジトリ内の docs/setup-guide.md を参照してください。" -ForegroundColor DarkGray
Write-Host ""
