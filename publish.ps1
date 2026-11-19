# publish.ps1 — 一条命令完成「提交 → 推送 → 验证远程一致」
#
#   .\publish.ps1 -Message "fix: 说明改了什么"
#   .\publish.ps1 -Message "docs: ..." -CheckOnly    只检查，不提交
#
# 为什么要有这个脚本：
#   改完只在本地、忘了 push，手机上装到的还是旧版 —— 这次踩过一次（CDN 缓存那轮）。
#   脚本在 push 之后会核对远程 HEAD 是否等于本地 HEAD，不一致直接报错退出。
param(
  [string]$Message = "update",
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
Push-Location $repo
try {
  Write-Host "== 1. 工作区 ==" -ForegroundColor Cyan
  $st = git status --porcelain
  if ([string]::IsNullOrWhiteSpace($st)) {
    Write-Host "   干净"
  } else {
    Write-Host "   待提交 $((($st -split "`n").Where({$_ -ne ''})).Count) 个文件"
    $st | Select-Object -First 12 | ForEach-Object { Write-Host "     $_" }
  }

  if ($CheckOnly) {
    Write-Host "`n== 2. 与远程的差异 ==" -ForegroundColor Cyan
    $un = git log origin/main..HEAD --oneline
    if ([string]::IsNullOrWhiteSpace($un)) { Write-Host "   无未推送提交" }
    else { Write-Host "   未推送：`n$un" -ForegroundColor Yellow }
    $local = (git rev-parse HEAD).Trim()
    $remote = ((git ls-remote origin refs/heads/main) -split "\s+")[0]
    Write-Host "   本地 $($local.Substring(0,7))  /  远程 $($remote.Substring(0,7))"
    return
  }

  Write-Host "`n== 2. 提交 ==" -ForegroundColor Cyan
  if ([string]::IsNullOrWhiteSpace($st)) {
    Write-Host "   没有改动，跳过"
  } else {
    git add -A
    git -c core.autocrlf=false commit -m $Message | Out-Null
    Write-Host "   已提交：$((git log -1 --format='%h %s'))"
  }

  Write-Host "`n== 3. 推送 ==" -ForegroundColor Cyan
  $env:GIT_TERMINAL_PROMPT = '0'
  $pushed = $false
  for ($i = 1; $i -le 3; $i++) {
    $out = git push origin main 2>&1
    if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
    Write-Host "   第 $i 次失败，5 秒后重试" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
  if (-not $pushed) { throw "推送失败：$out" }
  Write-Host "   推送成功"

  Write-Host "`n== 4. 核对远程 ==" -ForegroundColor Cyan
  $local = (git rev-parse HEAD).Trim()
  $remote = ((git ls-remote origin refs/heads/main) -split "\s+")[0]
  if ($local -ne $remote) {
    Write-Host "   ✗ 远程 HEAD 与本地不一致" -ForegroundColor Red
    Write-Host "     本地 $local"
    Write-Host "     远程 $remote"
    exit 1
  }
  Write-Host "   ✓ 一致：$($local.Substring(0,7))"

  Write-Host "`n== 5. 抽查 raw 可达性 ==" -ForegroundColor Cyan
  $base = 'https://raw.githubusercontent.com/zwg1097551433/phone-armor/main'
  foreach ($f in @('deploy.sh', 'armor.sh', 'preflight/lib/index.js', 'payload/prompt-inject.md')) {
    try {
      $r = Invoke-WebRequest "$base/$f" -UseBasicParsing -TimeoutSec 25
      Write-Host "   ✓ $f ($($r.RawContentLength) 字节)"
    } catch {
      Write-Host "   ✗ $f 拉不到：$($_.Exception.Message)" -ForegroundColor Red
      exit 1
    }
  }

  Write-Host "`n全部同步完成。" -ForegroundColor Green
}
finally {
  Pop-Location
}
