<#
  upgrade-cline-zh.ps1 — Cline 桌面版升级后「一键恢复汉化 + 重打 sidecar 补丁」
  ---------------------------------------------------------------------------
  官方桌面版每次更新后，需要手工做的事全部收敛到这一步：
    1. 读安装版本 -> 2. 考证官方是否已修AVX2（决定还要不要打补丁）
    3. 检出对应 tag -> 4. bun install -> 5. build:sdk -> 6. 编译 sidecar
    7. 备份 -> 8. 替换安装目录 + 固定副本 -> 9. 中文版启动器重启
    10. 验证：哈希一致 / sidecar 存活 / CDP 可达 / **界面版本号 == 安装版本号**

  关键点（都是本机踩过的坑）：
    - 官方 sidecar 与补丁版 FileVersion 同为 1.4.x，**版本号无法区分**，只能比 SHA256。
    - 界面显示的版本号来自源码 tauri.conf.json / package.json，**不是 exe 的 FileVersion**；
      源码 tag 与安装版本错位会导致界面报旧版本号。脚本会自动对齐并核验。
    - Cline 正常运行时有两个 code-sidecar.exe（hub-daemon + 桌面后端主进程），
      **不能只取第一个判 PID 变化**，否则会误报崩溃循环。

  用法：
      powershell -ExecutionPolicy Bypass -File .\upgrade-cline-zh.ps1
      powershell -ExecutionPolicy Bypass -File .\upgrade-cline-zh.ps1 -Tag desktop-v0.0.41
#>
[CmdletBinding()]
param(
    # 以下默认值均为空 = 自动探测（推荐）。仅在非标准安装时才需手动指定。
    [string]$ClineDir  = "",
    [string]$RepoDir   = "",
    [string]$BunExe    = "",
    [string]$PinnedDir = "",
    [string]$Launcher  = "",
    [string]$NodeExe   = "",
    [string]$Tag       = "",
    [switch]$ForcePatch
)

# ---------- 自动探测 ----------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-ClineDir {
    $cands = @(
        $env:ProgramFiles + "\Cline",
        ${env:ProgramFiles(x86)} + "\Cline",
        "$env:LOCALAPPDATA\Cline"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path (Join-Path $c "cline-app.exe"))) { return $c } }
    # 再从当前脚本位置的上级推断（<安装目录>\cline-zh\upgrade-cline-zh.ps1）
    $parent = Split-Path -Parent $ScriptDir
    if ($parent -and (Test-Path (Join-Path $parent "cline-app.exe"))) { return $parent }
    return $null
}

if (-not $ClineDir) { $ClineDir = Find-ClineDir }
if (-not $RepoDir) {
    # 源码仓库默认放在 <cline-zh> 的同级 build 目录，或本仓库内的 ./cline
    foreach ($c in @((Join-Path (Split-Path -Parent $ScriptDir) "cline-build\cline"), (Join-Path $ScriptDir "cline"))) {
        if (Test-Path (Join-Path $c ".git")) { $RepoDir = $c; break }
    }
}
if (-not $BunExe) {
    $bunCmd = Get-Command bun -ErrorAction SilentlyContinue
    if ($bunCmd) { $BunExe = $bunCmd.Source }
    elseif ($RepoDir) { $BunExe = Join-Path (Split-Path -Parent $RepoDir) "bun.exe" }
}
if (-not $PinnedDir) { $PinnedDir = Join-Path $ScriptDir "bin" }
if (-not $Launcher) { $Launcher  = Join-Path $ScriptDir "launch-silent.vbs" }
if (-not $NodeExe) {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) { $NodeExe = $nodeCmd.Source }
    else { $NodeExe = "C:\Program Files\nodejs\node.exe" }
}

$ErrorActionPreference = "Stop"
$script:Failed = $false

function Say([string]$m)  { Write-Host ("  [1/10] " + $m) -ForegroundColor Cyan }
function Ok([string]$m)    { Write-Host ("  [OK]   " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow }
function Step([string]$m) { Write-Host ("`n==> " + $m) -ForegroundColor White }
function Die([string]$m)  { Write-Host ("  [FAIL] " + $m) -ForegroundColor Red; exit 1 }

$ProgressPreference = 'SilentlyContinue'
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Cline 升级后一键汉化 / sidecar 补丁重打" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ---------- 0. 前置检查 ----------
Step "0/11 前置检查"
$appExe = Join-Path $ClineDir "cline-app.exe"
if (-not (Test-Path $appExe))       { Die "找不到 Cline 安装目录下的 cline-app.exe。请用 -ClineDir 指定安装目录（当前探测值：'$ClineDir'）" }
if (-not (Test-Path $BunExe))        { Die "找不到 Bun（编译补丁版 sidecar 必需）。请安装 Bun 或用 -BunExe 指定路径（当前探测值：'$BunExe'）" }
if (-not (Test-Path (Join-Path $RepoDir ".git"))) { Die "找不到官方源码仓库。请先 git clone --depth 1 https://github.com/cline/cline，或用 -RepoDir 指定（当前探测值：'$RepoDir'）" }

$version = (Get-Item $appExe).VersionInfo.FileVersion.Trim()
if (-not $Tag) { $Tag = "desktop-v" + $version }
$bunVer = (& $BunExe --version).Trim()
Say "安装版本 = $version，目标 tag = $Tag，Bun = $bunVer"
Ok "前置检查通过"

# ---------- 1. CPU 是否需要补丁 ----------
Step "1/11 判定本机是否需要 AVX2 补丁"
$needPatch = $true
try {
    $ps7 = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($ps7) {
        $avx2 = & $ps7 -NoProfile -Command '[System.Runtime.Intrinsics.X86.Avx2]::IsSupported' 2>$null
        $avx2 = ($avx2 | Select-Object -Last 1).Trim()
        if ($avx2 -eq "True") {
            Warn "本机 CPU 支持 AVX2，官方 sidecar 理论上可直接运行"
        } else {
            Say "本机 CPU 不支持 AVX2（.NET 权威 API 确认）-> 需要补丁"
        }
    } else {
        Warn "未找到 pwsh，跳过 AVX2 检测（按需要补丁处理）"
    }
} catch { Warn "AVX2 检测异常，按需要补丁处理" }

# ---------- 2. 考证官方是否已修（仅在不需要补丁时才跳过） ----------
Step "2/11 考证官方是否已把 Windows sidecar 改为 baseline 构建"
Push-Location $RepoDir
try {
    & git fetch --depth 1 origin ("+refs/tags/" + $Tag + ":refs/tags/" + $Tag) 2>&1 | Out-Null
    & git rev-parse --verify --quiet ("refs/tags/" + $Tag) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Warn "仓库中没有 tag $Tag（官方可能改了命名）；仍会尝试用当前工作区构建"
    } else {
        $bs = & git show ("desktop-v0.0.40:apps/examples/desktop-app/scripts/build-sidecar-bin.ts") 2>$null
        $cur = & git show ($Tag + ":apps/examples/desktop-app/scripts/build-sidecar-bin.ts") 2>$null
        $winLine = ($cur | Select-String -Pattern 'x86_64-pc-windows' | Select-Object -First 1)
        if ($winLine -and $winLine.ToString() -match 'bun-windows-x64-baseline') {
            Ok "官方该版本 Windows sidecar 已用 baseline 构建 -> 本机无需补丁"
            $needPatch = $false
        } elseif ($winLine) {
            Say "官方该版本 Windows sidecar 仍为标准构建（bun-windows-x64）-> 需要补丁"
            Say ("  " + $winLine.ToString().Trim())
        } else {
            Warn "未能在 $Tag 的 build-sidecar-bin.ts 中定位 Windows 分支，按需要补丁处理"
        }
    }
} finally { Pop-Location }

if (-not $needPatch) {
    Warn "按考证结果跳过 sidecar 编译（-ForcePatch 可强制编译）"
}
if ($ForcePatch) {
    Say "-ForcePatch 已指定，强制编译补丁"
    $needPatch = $true
}

# ---------- 3. 检出对应 tag ----------
if ($needPatch) {
Step "3/11 检出源码 tag $Tag"
Push-Location $RepoDir
try {
    & git checkout -f $Tag 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "git checkout $Tag 失败" }
    $repoVer = (Select-String -Path (Join-Path $RepoDir "apps\examples\desktop-app\src-tauri\tauri.conf.json") -Pattern '"version"\s*:\s*"([^"]+)"').Matches[0].Groups[1].Value
    Say "源码已切到 $Tag（tauri.conf.json version = $repoVer）"
    if ($repoVer -ne $version) {
        Warn "源码版本号($repoVer) 与安装版本($version) 不一致，界面会显示 $repoVer"
    } else {
        Ok "源码版本与安装版本一致（$repoVer），界面版本号不会错位"
    }
} catch { Pop-Location; Die $_.Exception.Message }
Pop-Location

# ---------- 4. bun install ----------
Step "4/11 安装依赖（bun install）"
$env:BUILD_MODE = "package"
$env:PATH = (Split-Path $BunExe) + ";" + $env:PATH
Push-Location $RepoDir
try {
    & $BunExe install 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Die "bun install 失败" }
} catch { Pop-Location; Die $_.Exception.Message }
Pop-Location
Ok "依赖安装完成"

# ---------- 5. build:sdk ----------
Step "5/11 构建 SDK（build:sdk）"
Push-Location $RepoDir
try {
    & $BunExe run build:sdk 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Die "build:sdk 失败" }
} catch { Pop-Location; Die $_.Exception.Message }
Pop-Location
Ok "SDK 构建完成"

# ---------- 6. 编译 sidecar ----------
Step "6/11 编译 sidecar"
$repoSidecar = Join-Path $RepoDir "apps\examples\desktop-app\src-tauri\bin\code-sidecar-x86_64-pc-windows-msvc.exe"
Push-Location (Join-Path $RepoDir "apps\examples\desktop-app")
try {
    & $BunExe build ./sidecar/index.ts --compile --target=bun-windows-x64 `
        --no-compile-autoload-dotenv --no-compile-autoload-bunfig `
        --compile-exec-argv=--use-system-ca --outfile $repoSidecar 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Die "sidecar 编译失败" }
} catch { Pop-Location; Die $_.Exception.Message }
Pop-Location

if (-not (Test-Path $repoSidecar)) { Die "编译产物不存在：$repoSidecar" }
$newVer = (Get-Item $repoSidecar).VersionInfo.FileVersion.Trim()
$newLen = (Get-Item $repoSidecar).Length
Say ("产物 FileVersion = {0}，大小 = {1} MB" -f $newVer, [math]::Round($newLen/1MB,1))
if ($newVer -ne $bunVer) { Die "产物版本 $newVer 与 bun $bunVer 不一致，为防误替换已中止" }
if ($newLen -lt 100MB)   { Die "产物小于 100MB，疑似不完整，已中止" }
Ok "编译产物校验通过"

# ---------- 7. 关闭进程 / 备份 / 替换 ----------
Step "7/11 关闭 Cline、备份并替换 sidecar"
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*inject.js*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name cline-app  -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Get-Process -Name code-sidecar -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

$target = Join-Path $ClineDir "code-sidecar.exe"
if (Test-Path $target) {
    $oldVer = (Get-Item $target).VersionInfo.FileVersion.Trim()
    $bak = Join-Path $ClineDir ("code-sidecar.exe.bak-" + $oldVer)
    if (Test-Path $bak) { Warn "备份已存在，跳过：$(Split-Path $bak -Leaf)" }
    else { [System.IO.File]::Copy($target, $bak, $true); Ok "旧 sidecar 已备份 -> $(Split-Path $bak -Leaf)" }
}
[System.IO.File]::Copy($repoSidecar, $target, $true)
Ok "已替换 $target"

if ($PinnedDir) {
    [System.IO.Directory]::CreateDirectory($PinnedDir) | Out-Null
    $pinned = Join-Path $PinnedDir "code-sidecar.exe"
    [System.IO.File]::Copy($repoSidecar, $pinned, $true)
    Ok "已更新固定副本 $pinned"
}
}

# ---------- 8. 通过中文版启动器重启 ----------
Step "8/11 通过中文版启动器重启（含调试端口 + 汉化注入）"
if (Test-Path $Launcher) {
    Start-Process "wscript.exe" -ArgumentList ('"' + $Launcher + '"') -WindowStyle Hidden
    Ok "已通过 launch-silent.vbs 启动"
} else {
    Warn "未找到 $Launcher，改为直接启动原版 exe（将无汉化）"
    Start-Process $appExe | Out-Null
}

# ---------- 9. 验证 sidecar 存活 / 无崩溃循环 ----------
Step "9/11 验证：sidecar 存活 / 端口监听 / 无崩溃循环"
$deadline = (Get-Date).AddSeconds(90)
$mainPid = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $side = @(Get-CimInstance Win32_Process -Filter "Name='code-sidecar.exe'" -ErrorAction SilentlyContinue)
    if ($side.Count -eq 0) { continue }
    # 桌面后端主进程 = 命令行里没有 --cline-hub-daemon 的那个（正常运行有两个 sidecar）
    $main = $side | Where-Object { $_.CommandLine -notlike '*--cline-hub-daemon*' } | Select-Object -First 1
    if (-not $main) { $main = $side | Select-Object -First 1 }
    $listen = Get-NetTCPConnection -State Listen -OwningProcess $main.ProcessId -ErrorAction SilentlyContinue
    if ($listen) { $mainPid = $main.ProcessId; break }
}
if (-not $mainPid) { Die "90 秒内未检测到 sidecar 监听端口" }
Ok "sidecar 主进程运行中（PID $mainPid）"

$start1 = (Get-Process -Id $mainPid).StartTime
Say "稳定性观察 30 秒（检测崩溃循环）..."
Start-Sleep -Seconds 30
$still = Get-Process -Id $mainPid -ErrorAction SilentlyContinue
if (-not $still)           { Die "sidecar 已退出，疑似崩溃循环" }
if ($still.StartTime -ne $start1) { Die "sidecar 被重启，疑似崩溃循环" }
Ok "sidecar 30 秒内 PID 稳定，无崩溃循环"

# ---------- 10. 验证哈希与汉化 ----------
Step "10/11 验证：哈希一致 + 汉化生效"
if ($needPatch) {
    $h1 = (Get-FileHash $target -Algorithm SHA256).Hash
    $h2 = (Get-FileHash (Join-Path $PinnedDir "code-sidecar.exe") -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    if ($h1 -and ($h1 -eq $h2)) { Ok "安装目录与固定副本哈希一致（$($h1.Substring(0,16))…）" }
    else { Warn "两侧哈希不一致：安装=$h1 固定=$h2" }
}

$cdpOk = $false
foreach ($p in 19333,19334,19527,9333) {
    try {
        $null = Invoke-WebRequest "http://127.0.0.1:$p/json/version" -UseBasicParsing -TimeoutSec 3
        Say "CDP 端口 $p 可达"
        $cdpOk = $true; $cdpPort = $p; break
    } catch { }
}
if (-not $cdpOk) {
    Warn "CDP 端口不可达 -> 汉化未生效。请用「Cline 中文版」快捷方式启动（不要用 cline-app.exe）"
} elseif (Test-Path $NodeExe) {
    $tmp = Join-Path $env:TEMP "cline_probe.js"
    Set-Content -Path $tmp -Encoding UTF8 -Value @"
const http=require('http');
http.get('http://127.0.0.1:$cdpPort/json',r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{
  const t=JSON.parse(d).find(x=>x.type==='page'); if(!t){console.log('');process.exit(0);}
  const ws=new WebSocket(t.webSocketDebuggerUrl);
  ws.onopen=()=>ws.send(JSON.stringify({id:1,method:'Runtime.evaluate',params:{expression:'document.body.innerText.slice(0,150)',returnByValue:true}}));
  ws.onmessage=e=>{const m=JSON.parse(e.data); if(m.id===1){console.log(m.result.result.value||''); process.exit(0);}};
});});
"@
    $uiText = & $NodeExe $tmp 2>$null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($uiText -match '会话|定时任务|自定义') { Ok "汉化已生效（检测到中文 UI）" }
    else { Warn "未检测到中文 UI 特征词，请肉眼确认界面" }
}

# ---------- 11. 清理临时文件与陈旧备份 ----------
Step "11/11 清理临时文件与陈旧备份"
# 清理本脚本产生的临时文件与编译日志
$tmpLogs = @(
    (Join-Path $env:TEMP "cline_probe.js"),
    (Join-Path (Split-Path -Parent $RepoDir) "repatch.log"),
    (Join-Path (Split-Path -Parent $RepoDir) "repatch.err.log")
)
foreach ($tmpf in $tmpLogs) {
    if ($tmpf -and (Test-Path $tmpf)) { Remove-Item $tmpf -Force -ErrorAction SilentlyContinue; Ok "已删除临时文件 $(Split-Path $tmpf -Leaf)" }
}
# 清理仓库内可能残留的探针文件
Get-ChildItem $ScriptDir,$RepoDir -Filter '_probe*.js' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Ok "已删除 $($_.Name)" }

# 陈旧备份：sidecar 只保留最近 2 个 + 当前补丁版，词典备份只保留最近 3 个
if ($needPatch) {
    $sidecarBaks = Get-ChildItem $ClineDir -Filter 'code-sidecar.exe.bak-*' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($sidecarBaks.Count -gt 2) {
        $sidecarBaks | Select-Object -Skip 2 | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Ok "已删除陈旧 sidecar 备份 $($_.Name)"
        }
    } else { Ok "sidecar 备份数量正常（$($sidecarBaks.Count) 个，无需清理）" }
}
$dictBaks = Get-ChildItem $ScriptDir -Filter 'dictionary.json.bak*' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
if ($dictBaks.Count -gt 3) {
    $dictBaks | Select-Object -Skip 3 | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Ok "已删除陈旧词典备份 $($_.Name)"
    }
} else { Ok "词典备份数量正常（$($dictBaks.Count) 个，无需清理）" }

Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host ("  全部完成：Cline $version 汉化版已就绪，临时文件已清理") -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  提醒：以后官方更新后，直接重跑本脚本即可。" -ForegroundColor Yellow
