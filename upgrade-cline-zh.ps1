<#
  upgrade-cline-zh.ps1 — Cline 桌面版升级后「一键恢复汉化 + 重打 sidecar 补丁」
  ---------------------------------------------------------------------------
  官方桌面版每次更新后，需要手工做的事全部收敛到这一步：
    1. 读安装版本 -> 2. 考证官方是否已修AVX2（决定还要不要打补丁）
    3. 检出对应 tag -> 4. bun install -> 5. build:sdk -> 6. 编译 sidecar
    7. 备份 -> 8. 替换安装目录 + 固定副本 -> 9. 中文版启动器重启
    10. 验证：哈希一致 / sidecar 存活 / CDP 可达 / **界面版本号 == 安装版本号**
   11. 验证：Telegram connector 是否随 sidecar 重启自动恢复
   12. 清理临时文件与陈旧备份

  关键点（都是本机踩过的坑）：
    - 官方 sidecar 与补丁版 FileVersion 同为 1.4.x，**版本号无法区分**，只能比 SHA256。
    - 界面显示的版本号来自源码 tauri.conf.json / package.json，**不是 exe 的 FileVersion**；
      源码 tag 与安装版本错位会导致界面报旧版本号。脚本会自动对齐并核验。
    - Cline 正常运行时有两个 code-sidecar.exe（hub-daemon + 桌面后端主进程），
      **不能只取第一个判 PID 变化**，否则会误报崩溃循环。
    - 【新增】**必须先关掉 Cline 自动更新**（global-settings.json: autoUpdateEnabled）。
      否则更新可能在脚本中途发生：安装目录 sidecar 变成官方未打补丁版本，
      而 launch-silent.vbs 把 sidecar 钉在 cline-zh\bin，于是 app/sidecar 版本错位；
      直接跑 cline-app.exe 还会用到未打补丁的 sidecar —— 本机 CPU 无 AVX2 会崩。
      脚本会在第 0 步检测，未关闭则直接中止。
    - 【新增】Telegram connector 连的是 hub（127.0.0.1:25463），sidecar 重启即断连。
      脚本第 7 步停掉 connector 进程，第 11 步观察桌面版是否自动重连
      （sidecar 的 reconnectPersistedConnectors 会读 connectors.db 里的完整配置，
      且继承了启动器注入的代理环境，所以通常无需人工干预）。
    - 【新增】脚本全程**不读写 bot token**。connector 目录下的 json 只有
      botUsername/botId，token 在 connectors.db 里由桌面版自己用；
      兜底输出命令时也用占位符，避免明文凭据进命令行历史。

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
    $parent = Split-Path -Parent $ScriptDir

    # 与 cline-zh 平级、且内含 cline-app.exe 的目录。
    # 支持两种布局：
    #   A) cline-zh 嵌在安装目录内：<install>\cline-zh\        -> $parent 就是安装目录
    #   B) cline-zh 与安装目录平级：D:\cline-zh + D:\Cline     -> 需要扫描同级目录
    #      （早期版本只处理 A，遇到布局 B 会返回 $null，
    #        随后 Join-Path $null 抛 "Cannot bind argument to parameter 'Path'"）
    $siblingHits = @()
    if ($parent) {
        $siblingHits = @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
                         Where-Object { Test-Path (Join-Path $_.FullName "cline-app.exe") } |
                         Select-Object -ExpandProperty FullName)
    }
    $ordered = @()
    $ordered += @($siblingHits | Where-Object { (Split-Path $_ -Leaf) -ieq "Cline" })
    $ordered += @($siblingHits | Where-Object { (Split-Path $_ -Leaf) -ine "Cline" })

    $cands = @(
        $env:ProgramFiles + "\Cline",
        ${env:ProgramFiles(x86)} + "\Cline",
        "$env:LOCALAPPDATA\Cline",
        "$env:LOCALAPPDATA\Programs\Cline",
        $parent
    ) + $ordered

    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c "cline-app.exe"))) { return $c }
    }
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

function Say([string]$m)  { Write-Host ("  [>>]   " + $m) -ForegroundColor Cyan }
function Ok([string]$m)    { Write-Host ("  [OK]   " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow }
function Step([string]$m) { Write-Host ("`n==> " + $m) -ForegroundColor White }
function Die([string]$m)  { Write-Host ("  [FAIL] " + $m) -ForegroundColor Red; exit 1 }

$ProgressPreference = 'SilentlyContinue'
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Cline 升级后一键汉化 / sidecar 补丁重打" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ---------- 原生命令包装 ----------
# 为什么需要它：git / bun 会把**正常的状态信息**写到 stderr
#（例如 git 的 "HEAD is now at ..."、bun install 的进度条）。
# 而 $ErrorActionPreference='Stop' 时，PowerShell 会把原生 stderr 转成
# 终止性 NativeCommandError —— 命令其实成功了，却被外层 catch 捕获并误报失败。
#
# 实测踩坑：$ErrorActionPreference='Stop' 下执行 `git checkout -f <tag>`，
# git 输出 "HEAD is now at 4515a41 chore(desktop): release v0.0.41"，
# PowerShell 直接抛异常，脚本在第 3 步中断，但仓库其实已经切到目标 tag 了。
#
# 这里临时把 ErrorActionPreference 降级为 Continue，只依据 $LASTEXITCODE 判成败。
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = "",   # 可选：临时切换目录（用完自动还原）
        [switch]$Tail,        # 只回显最后 3 行非空输出
        [switch]$Capture      # 返回 @{ExitCode; Output}
    )
    $prevEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pushed = $false
    try {
        if ($WorkingDirectory) { Push-Location $WorkingDirectory; $pushed = $true }
        $global:LASTEXITCODE = 0
        $raw  = & $FilePath @Arguments 2>&1
        $rc   = $LASTEXITCODE
        $text = ($raw | Out-String)
        if ($Capture) { return [pscustomobject]@{ ExitCode = $rc; Output = $text } }
        if ($Tail -and $text.Trim()) {
            @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) |
                ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor DarkGray }
        }
        return $rc
    } finally {
        if ($pushed) { Pop-Location }
        $ErrorActionPreference = $prevEA
    }
}

# ---------- Telegram / Connector 辅助函数 ----------
$script:ProxyBase   = ""
$script:ClineCmd    = ""
$script:SavedConns  = @()
$script:ActiveBefore = @()

function Get-ClineCmd {
    if ($script:ClineCmd) { return $script:ClineCmd }
    $cands = @(
        (Join-Path $env:APPDATA "npm\cline.cmd"),
        (Join-Path $env:USERPROFILE "AppData\Roaming\npm\cline.cmd")
    )
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) { $script:ClineCmd = $c; return $c }
    }
    return $null
}

# 从 launch-silent.vbs 解析代理地址，保证与启动器是单一配置源。
# 脚本自身要调 `cline connect` 拉起 connector 时必须带上这些变量，
# 否则 connector 进程无法访问 api.telegram.org。
function Import-ProxyEnvFromLauncher {
    param([string]$LauncherPath)
    if (-not $LauncherPath -or -not (Test-Path $LauncherPath)) { return $null }
    $m = Select-String -Path $LauncherPath -Pattern 'proxyBase\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue
    if (-not $m -or -not $m.Matches[0].Groups[1].Value) { return $null }
    $pb = $m.Matches[0].Groups[1].Value.Trim()
    if (-not $pb) { return $null }
    $env:HTTP_PROXY  = $pb
    $env:HTTPS_PROXY = $pb
    $env:NO_PROXY    = "127.0.0.1,localhost,::1"
    $script:ProxyBase = $pb
    return $pb
}

# 读取持久化的 connector 配置（~/.cline/data/connectors/*.json）
# 这里只有 botUsername / botId / pid，**不含 token**；
# token 存在 connectors.db 里，由桌面版 sidecar 的 reconnectPersistedConnectors 使用，
# 所以本脚本全程不接触明文凭据。
function Get-PersistedConnector {
    $dir = Join-Path $env:USERPROFILE ".cline\data\connectors"
    if (-not (Test-Path $dir)) { return @() }
    $out = @()
    # 必须递归：实际布局是 connectors\<channel>\<BotUsername>.json（channel 是子目录）
    foreach ($f in (Get-ChildItem $dir -Filter "*.json" -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $j.botUsername) { continue }
            $ch = Split-Path (Split-Path $f.FullName -Parent) -Leaf   # 取 channel 子目录名
            if (-not $ch) { $ch = "telegram" }
            $out += [pscustomobject]@{
                File = $f.FullName; Channel = $ch
                BotUsername = $j.botUsername; BotId = $j.botId
            }
        } catch { }
    }
    return $out
}

# 查询当前活跃的 connector（走 cline doctor，剥离 ANSI 色码后正则解析）
#
# 注意：doctor 的输出格式随版本变过，两种都要认：
#   旧（core 0.0.89）："- telegram | bot=@Clinebot121_bot | pid=6300 | hub=... | started=..."
#   新（core 0.0.90）："- telegram | instance=Clinebot121_bot | state=running | origin=spawned | pid=6076"
# 且新版本多了一节 "hub-supervised connectors:"，旧版那节 "active connectors:" 会是空的。
# 只匹配旧的 bot= 会导致明明在跑却报"未恢复"。
function Get-ActiveConnector {
    $cmd = Get-ClineCmd
    if (-not $cmd) { return @() }
    $raw = (Invoke-Native -FilePath $cmd -Arguments @("doctor") -Capture).Output
    $esc = [char]27
    $clean = [regex]::Replace($raw, ($esc + "\[[0-9;]*[A-Za-z]"), "")
    $res = @()
    foreach ($ln in ($clean -split "\r?\n")) {
        if ($ln -notmatch '^\s*-\s*(?<ch>[a-z]+)\s*\|') { continue }
        $ch = $Matches['ch']
        $bot = ""
        if     ($ln -match '\bbot=(?<b>\S+)')      { $bot = $Matches['b'] }
        elseif ($ln -match '\binstance=(?<b>\S+)') { $bot = "@" + $Matches['b'] }
        # 注意：变量名不能用 $pid —— PowerShell 变量名大小写不敏感，
        # $pid 等同只读自动变量 $PID，赋值会抛 "Cannot overwrite variable PID"。
        $procId = 0
        if ($ln -match '\bpid=(?<p>\d+)') { $procId = [int]$Matches['p'] }
        if ($bot -or $procId) {
            $res += [pscustomobject]@{ Channel = $ch; Bot = $bot; Pid = $procId }
        }
    }
    return $res
}

# ---------- 0. 前置检查 ----------
Step "0/12 前置检查"
$appExe = Join-Path $ClineDir "cline-app.exe"
if (-not (Test-Path $appExe))       { Die "找不到 Cline 安装目录下的 cline-app.exe。请用 -ClineDir 指定安装目录（当前探测值：'$ClineDir'）" }
if (-not (Test-Path $BunExe))        { Die "找不到 Bun（编译补丁版 sidecar 必需）。请安装 Bun 或用 -BunExe 指定路径（当前探测值：'$BunExe'）" }
if (-not (Test-Path (Join-Path $RepoDir ".git"))) { Die "找不到官方源码仓库。请先 git clone --depth 1 https://github.com/cline/cline，或用 -RepoDir 指定（当前探测值：'$RepoDir'）" }

# ---- 自动更新守卫 ----
# Cline 若在脚本运行期间自行更新，安装目录的 sidecar 会变成官方未打补丁的版本，
# 而 launch-silent.vbs 把 sidecar 钉在 cline-zh\bin，于是出现 app 与 sidecar 版本错位；
# 更糟的是直接跑 cline-app.exe 时会用到未打补丁的 sidecar —— 本机 CPU 无 AVX2 会崩。
$gsPath = Join-Path $env:USERPROFILE ".cline\data\settings\global-settings.json"
if (Test-Path $gsPath) {
    try {
        $gs = Get-Content $gsPath -Raw | ConvertFrom-Json
        if ($gs.autoUpdateEnabled -eq $true) {
            Die "检测到 Cline 自动更新仍处于开启状态（global-settings.json: autoUpdateEnabled=true）。`n" +
                "       请先到 Cline 设置里关闭自动更新，再重跑本脚本。`n" +
                "       原因：更新可能在脚本中途发生，导致 app / sidecar 版本错位；`n" +
                "       且官方未打补丁的 Windows sidecar 在本机（无 AVX2）无法运行。"
        } else {
            Ok "自动更新已关闭（符合预期）"
        }
    } catch { Warn "读取 global-settings.json 失败，跳过自动更新检查" }
} else {
    Warn "找不到 global-settings.json，无法确认自动更新状态，请自行确认"
}

# ---- 代理环境：从启动器导入，供本脚本后续拉起 connector 使用 ----
$pb = Import-ProxyEnvFromLauncher -LauncherPath $Launcher
if ($pb) { Ok "已从 launch-silent.vbs 载入出站代理：$pb" }
else { Warn "未能从 launch-silent.vbs 解析代理；若 connector 需出网，自动恢复可能失败" }

# ---- connector 快照（升级前它们在跑，升级过程会打断）----
$script:SavedConns   = Get-PersistedConnector
$script:ActiveBefore = Get-ActiveConnector
if (@($script:ActiveBefore).Count -gt 0) {
    foreach ($c in $script:ActiveBefore) { Say "升级前 connector：$($c.Channel) / $($c.Bot) (pid=$($c.Pid))" }
} else {
    Say "升级前没有活跃的 connector"
}
if (@($script:SavedConns).Count -gt 0 -and @($script:ActiveBefore).Count -eq 0) {
    Warn "存在持久化 connector 配置但当前未运行，升级后应会自动拉起"
}

$version = (Get-Item $appExe).VersionInfo.FileVersion.Trim()
if (-not $Tag) { $Tag = "desktop-v" + $version }
$bunVer = (Invoke-Native -FilePath $BunExe -Arguments @("--version") -Capture).Output.Trim()
Say "安装版本 = $version，目标 tag = $Tag，Bun = $bunVer"
Ok "前置检查通过"

# ---------- 1. CPU 是否需要补丁 ----------
Step "1/12 判定本机是否需要 AVX2 补丁"
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
Step "2/12 考证官方是否已把 Windows sidecar 改为 baseline 构建"
Push-Location $RepoDir
try {
    Invoke-Native -FilePath "git" -Arguments @("fetch","--depth","1","origin","+refs/tags/$($Tag):refs/tags/$($Tag)") | Out-Null
    $rcTag = Invoke-Native -FilePath "git" -Arguments @("rev-parse","--verify","--quiet","refs/tags/$($Tag)")
    if ($rcTag -ne 0) {
        Warn "仓库中没有 tag $Tag（官方可能改了命名）；仍会尝试用当前工作区构建"
    } else {
        $bs  = Invoke-Native -FilePath "git" -Arguments @("show","desktop-v0.0.40:apps/examples/desktop-app/scripts/build-sidecar-bin.ts") -Capture
        $cur = Invoke-Native -FilePath "git" -Arguments @("show","$($Tag):apps/examples/desktop-app/scripts/build-sidecar-bin.ts") -Capture
        $winLine = ($cur.Output | Select-String -Pattern 'x86_64-pc-windows' | Select-Object -First 1)
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
Step "3/12 检出源码 tag $Tag"
Push-Location $RepoDir
try {
    $rcCheckout = Invoke-Native -FilePath "git" -Arguments @("checkout","-f",$Tag)
    if ($rcCheckout -ne 0) { Die "git checkout $Tag 失败（exit=$rcCheckout）。请手动执行：cd `"$RepoDir`"; git checkout -f $Tag" }
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
Step "4/12 安装依赖（bun install）"
$env:BUILD_MODE = "package"
$env:PATH = (Split-Path $BunExe) + ";" + $env:PATH
Push-Location $RepoDir
try {
    $rcInstall = Invoke-Native -FilePath $BunExe -Arguments @("install") -Tail
    if ($rcInstall -ne 0) { Die "bun install 失败（exit=$rcInstall）" }
} catch { Pop-Location; Die $_.Exception.Message }
Pop-Location
Ok "依赖安装完成"

# ---------- 5. build:sdk ----------
Step "5/12 构建 SDK（build:sdk）"
Push-Location $RepoDir
try {
    $rcSdk = Invoke-Native -FilePath $BunExe -Arguments @("run","build:sdk") -Tail
    if ($rcSdk -ne 0) { Die "build:sdk 失败（exit=$rcSdk）" }
} catch { Pop-Location; Die $_.Exception.Message }
Pop-Location
Ok "SDK 构建完成"

# ---------- 6. 编译 sidecar ----------
Step "6/12 编译 sidecar"
$repoSidecar = Join-Path $RepoDir "apps\examples\desktop-app\src-tauri\bin\code-sidecar-x86_64-pc-windows-msvc.exe"
Push-Location (Join-Path $RepoDir "apps\examples\desktop-app")
try {
    $bunBuildArgs = @(
        "build", "./sidecar/index.ts", "--compile", "--target=bun-windows-x64",
        "--no-compile-autoload-dotenv", "--no-compile-autoload-bunfig",
        "--compile-exec-argv=--use-system-ca", "--outfile", $repoSidecar
    )
    $rcBuild = Invoke-Native -FilePath $BunExe -Arguments $bunBuildArgs -Tail
    if ($rcBuild -ne 0) { Die "sidecar 编译失败（exit=$rcBuild）" }
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
Step "7/12 关闭 Cline、备份并替换 sidecar"
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*inject.js*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# connector 进程也一并停掉：它们连的是 hub，hub 重启后会断连，
# 留着只会在升级窗口里对 Telegram 空轮询并刷 409 冲突。
# 只匹配 Cline 已知平台的 connect 子命令，避免误杀无关 node 进程。
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'connect\s+(telegram|slack|discord|gchat|whatsapp|linear)' } |
    ForEach-Object {
        $pname = ([regex]::Match($_.CommandLine, 'connect\s+(telegram|slack|discord|gchat|whatsapp|linear)')).Value
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Ok "已停止 connector 进程 pid=$($_.ProcessId) ($pname)"
    }
Get-Process -Name cline-app  -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Get-Process -Name code-sidecar -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

$target = Join-Path $ClineDir "code-sidecar.exe"
if (Test-Path $target) {
    # 备份名不能用 FileVersion：官方版与补丁版的 FileVersion 都是 1.4.x，
    # 会导致 "备份已存在，跳过" 而永远存不下真正的旧版本。
    # 改用「安装版本 + 内容哈希前 8 位」，每个二进制唯一。
    $sha8 = (Get-FileHash $target -Algorithm SHA256).Hash.Substring(0,8)
    $bak = Join-Path $ClineDir ("code-sidecar.exe.bak-" + $version + "-" + $sha8)
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
Step "8/12 通过中文版启动器重启（含调试端口 + 汉化注入）"
if (Test-Path $Launcher) {
    Start-Process "wscript.exe" -ArgumentList ('"' + $Launcher + '"') -WindowStyle Hidden
    Ok "已通过 launch-silent.vbs 启动"
} else {
    Warn "未找到 $Launcher，改为直接启动原版 exe（将无汉化）"
    Start-Process $appExe | Out-Null
}

# ---------- 9. 验证 sidecar 存活 / 无崩溃循环 ----------
Step "9/12 验证：sidecar 存活 / 端口监听 / 无崩溃循环"
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
Step "10/12 验证：哈希一致 + 汉化生效"
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

# ---------- 11. Telegram connector 验证与恢复 ----------
Step "11/12 验证 Telegram connector"
if (@($script:SavedConns).Count -eq 0) {
    Say "没有持久化的 connector 配置，跳过"
} else {
    # 桌面版 sidecar 启动时会 reconnectPersistedConnectors 自动重连，
    # 它继承了 launch-silent.vbs 注入的代理环境，所以正常情况下无需脚本干预。
    # 这里只做观察与兜底，最长等 60 秒。
    $restored = @()
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        $restored = Get-ActiveConnector
        if (@($restored).Count -gt 0) { break }
    }
    if (@($restored).Count -gt 0) {
        foreach ($c in $restored) { Ok "connector 已自动恢复：$($c.Channel) / $($c.Bot) (pid=$($c.Pid))" }
        if ($script:ProxyBase) { Ok "恢复的 connector 继承了代理 $script:ProxyBase" }
    } else {
        Warn "60 秒内 connector 未自动恢复"
        $cmd = Get-ClineCmd
        if (-not $cmd) {
            Warn "未安装 cline CLI，无法自动拉起。"
        } else {
            # 不在本脚本里读写 token —— token 存在 connectors.db，由桌面版负责。
            # 这里只给出可复制的命令，token 用占位符，避免明文凭据进入命令行历史。
            foreach ($c in $script:SavedConns) {
                if (-not $c.BotUsername) { continue }
                $ch = ([regex]::Match($c.File, '(?i)(telegram|slack|discord|gchat|whatsapp|linear)')).Value
                if (-not $ch) { $ch = "telegram" }
                Write-Host ""
                Write-Host "  请在 PowerShell 中执行以下命令手动恢复（token 从 @BotFather 取，或见 connectors.db）：" -ForegroundColor Yellow
                Write-Host ("    `$env:HTTPS_PROXY = '" + $script:ProxyBase + "'") -ForegroundColor DarkGray
                Write-Host ("    & `"$cmd`" connect $ch -k <BOT_TOKEN> --bot-username " + $c.BotUsername + " --allowed-user-id <YOUR_USER_ID>") -ForegroundColor DarkGray
                Write-Host ""
            }
        }
        Warn "Telegram 功能暂不可用，按上面的命令恢复后即可继续"
    }
}

# ---------- 12. 清理临时文件与陈旧备份 ----------
Step "12/12 清理临时文件与陈旧备份"
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
Write-Host "  前提：Cline 设置里的自动更新保持关闭。" -ForegroundColor Yellow
