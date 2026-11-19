# publish.ps1 — 一条命令完成「提交 → 推送 → 验证远程一致」
#
#   .\publish.ps1 -Message "fix: 说明改了什么"
#   .\publish.ps1 -CheckOnly        只检查同步状态，不提交不推送
#
# 为什么要有这个脚本：
#   改完只在本地、忘了 push，手机上装到的还是旧版 —— 这次踩过一次（CDN 缓存那轮）。
#   脚本在 push 之后会核对远程 HEAD 是否等于本地 HEAD，不一致直接报错退出。
param(
  [string]$Message = "update",
  [switch]$CheckOnly
)

# git 往 stderr 写进度，Stop 模式会把 stderr 当异常抛出，这里统一用 $LASTEXITCODE 判断
$ErrorActionPreference = 'Continue'
$repo = $PSScriptRoot
Push-Location $repo

function GitOk {
  param([string[]]$GitArgs, [string]$What)
  $out = & git @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "   ✗ $What 失败" -ForegroundColor Red
    $out | Select-Object -First 6 | ForEach-Object { Write-Host "     $_" }
    Pop-Location
    exit 1
  }
  return $out
}

try {
  Write-Host "== 1. 工作区 ==" -ForegroundColor Cyan
  $st = (& git status --porcelain) -join "`n"
  if ([string]::IsNullOrWhiteSpace($st)) {
    Write-Host "   干净"
  } else {
    $n = ($st -split "`n" | Where-Object { $_ -ne '' }).Count
    Write-Host "   待提交 $n 个文件"
    ($st -split "`n" | Where-Object { $_ -ne '' } | Select-Object -First 12) |
      ForEach-Object { Write-Host "     $_" }
  }

  if ($CheckOnly) {
    Write-Host "`n== 2. 与远程的差异 ==" -ForegroundColor Cyan
    $un = (& git log origin/main..HEAD --oneline) -join "`n"
    if ([string]::IsNullOrWhiteSpace($un)) { Write-Host "   无未推送提交" }
    else { Write-Host "   未推送：`n$un" -ForegroundColor Yellow }
    $l = (& git rev-parse HEAD).Trim()
    $r = (& git ls-remote origin refs/heads/main) -split "\s+" | Select-Object -First 1
    Write-Host "   本地 $($l.Substring(0,7))  /  远程 $($r.Substring(0,7))"
    return
  }

  Write-Host "`n== 2. 提交 ==" -ForegroundColor Cyan
  if ([string]::IsNullOrWhiteSpace($st)) {
    Write-Host "   没有改动，跳过"
  } else {
    & git add -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git add 失败" }
    & git -c core.autocrlf=false commit -m $Message 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git commit 失败" }
    Write-Host "   已提交：$((& git log -1 --format='%h %s'))"
  }

  Write-Host "`n== 3. 推送 ==" -ForegroundColor Cyan
  $env:GIT_TERMINAL_PROMPT = '0'
  $ok = $false
  for ($i = 1; $i -le 3; $i++) {
    & git push origin main 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Write-Host "   第 $i 次失败，5 秒后重试" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
  if (-not $ok) {
    Write-Host "   ✗ 推送失败（网络或凭据问题）" -ForegroundColor Red
    exit 1
  }
  Write-Host "   推送成功"

  Write-Host "`n== 4. 核对远程 ==" -ForegroundColor Cyan
  $l = (& git rev-parse HEAD).Trim()
  $r = ((& git ls-remote origin refs/heads/main) -split "\s+" | Select-Object -First 1)
  if ($l -ne $r) {
    Write-Host "   ✗ 远程与本地不一致" -ForegroundColor Red
    Write-Host "     本地 $l"
    Write-Host "     远程 $r"
    exit 1
  }
  Write-Host "   ✓ 一致：$($l.Substring(0,7))"

  Write-Host "`n== 5. 抽查 raw 可达性 ==" -ForegroundColor Cyan
  $base = 'https://raw.githubusercontent.com/zwg1097551433/phone-armor/main'
  $failed = $false
  foreach ($f in @('deploy.sh', 'armor.sh', 'preflight/lib/index.js', 'payload/prompt-inject.md')) {
    try {
      $resp = Invoke-WebRequest "$base/$f" -UseBasicParsing -TimeoutSec 25
      Write-Host "   ✓ $f ($($resp.RawContentLength) 字节)"
    } catch {
      Write-Host "   ✗ $f 拉不到：$($_.Exception.Message)" -ForegroundColor Red
      $failed = $true
    }
  }
  if ($failed) { exit 1 }

  Write-Host "`n全部同步完成。" -ForegroundColor Green
}
finally {
  Pop-Location
}
