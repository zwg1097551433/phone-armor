# 把仓库占位符替换成你的 GitHub 用户名，并可选地完成本地提交。
#
#   .\set-repo.ps1 -Owner 你的GitHub用户名
#   .\set-repo.ps1 -Owner 你的GitHub用户名 -Commit
#
# 之后手动建远程仓库并推送（github.com/new 建一个同名空仓库）：
#   git remote add origin https://github.com/<你>/phone-armor.git
#   git push -u origin main
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [string]$Repo = 'phone-armor',
  [string]$Branch = 'main',
  [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($f in @('bootstrap.sh', 'INSTALL-PROMPT.txt', 'README.md')) {
  $p = Join-Path $root $f
  if (-not (Test-Path $p)) { Write-Warning "skip (missing): $f"; continue }
  $orig = Get-Content $p -Raw -Encoding UTF8
  $t = $orig.Replace('CHANGE_ME', $Owner).Replace('OWNER/REPO', "$Owner/$Repo")
  if ($t -ne $orig) {
    $t = $t.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($p, $t, $utf8)
    Write-Host "patched: $f"
  }
  else { Write-Host "no placeholder: $f" }
}

# 校验：仓库里所有 .sh（含子目录）必须是 LF
foreach ($sh in Get-ChildItem $root -Filter *.sh -File -Recurse) {
  if ($sh.FullName -match '\\\.git\\') { continue }
  $bytes = [System.IO.File]::ReadAllBytes($sh.FullName)
  $cr = ($bytes | Where-Object { $_ -eq 13 }).Count
  if ($cr -gt 0) { Write-Warning "$($sh.Name) 含 $cr 个 CR —— 会被手机 sh 拒绝，先转 LF" }
}

if ($Commit) {
  Push-Location $root
  try {
    if (-not (Test-Path '.git')) { git init | Out-Null; Write-Host "git init 完成" }
    $name = (git config user.name) 2>$null
    $mail = (git config user.email) 2>$null
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($mail)) {
      Write-Warning "git 未配置身份，先跑：git config --global user.name `"你的名字`"; git config --global user.email `"你的邮箱`""
      return
    }
    git add -A
    git -c core.autocrlf=false commit -m "phone-armor: 一键注入包 dsh-purge 1.6.91 (DSH 0.2.2-rc.1)" | Out-Null
    Write-Host "已提交。下一步手动推送："
    Write-Host "  git branch -M $Branch"
    Write-Host "  git remote add origin https://github.com/$Owner/$Repo.git"
    Write-Host "  git push -u origin $Branch"
  }
  finally { Pop-Location }
}
