<#
================================================================================
  明日方舟：终末地 —— 资源概况与刷取规划工具
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action = 'shell',

    [Parameter(Position = 1)]
    [string[]]$Target,

    [Parameter(Position = 2)]
    [double]$Number,

    [string]$Sort,

    [string]$Scale,

    [switch]$NoColor
)

# ============ 全局配置 ============
$script:NoColor = [bool]$NoColor
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigFile = Join-Path $ScriptDir 'settings.json'

$UnitMap      = @{ '折金票' = '万'; '珍贵培养素材' = '箱' }
$BarWidth     = 36
$NameWidth    = 14
$ValWidth     = 8

# ============ 基础辅助函数 ============
function Write-C {
    param([Parameter(Mandatory)][string]$Text, [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray)
    if ($script:NoColor) { Write-Host $Text -NoNewline; return }
    Write-Host $Text -NoNewline -ForegroundColor $Color
}
function NL { Write-Host '' }

function Get-Unit([string]$Name) {
    if ($UnitMap.ContainsKey($Name)) { return $UnitMap[$Name] }
    return ''
}

function Format-Num($Value) {
    if ($null -eq $Value) { return '0' }
    $d = [double]$Value
    if ([Math]::Abs($d - [Math]::Round($d)) -lt 1e-9) {
        return ([long][Math]::Round($d)).ToString()
    }
    return $d.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-DisplayWidth([string]$S) {
    $w = 0
    foreach ($ch in $S.ToCharArray()) {
        if ([int]$ch -gt 0x2E7F) { $w += 2 } else { $w += 1 }
    }
    return $w
}
function Pad-Display([string]$S, [int]$Width) {
    $pad = $Width - (Get-DisplayWidth $S)
    if ($pad -le 0) { return $S + ' ' }
    return $S + (' ' * $pad)
}
function Pad-Right([string]$S, [int]$Width) {
    $pad = $Width - (Get-DisplayWidth $S)
    if ($pad -le 0) { return $S }
    return (' ' * $pad) + $S
}

function Read-Config([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "缺少配置文件：$Path" -ForegroundColor Red
        exit 1
    }
    try {
        $json = [System.IO.File]::ReadAllText($Path)
        return ($json | ConvertFrom-Json)
    } catch {
        Write-Host "配置文件解析失败：$Path" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}
function Write-Config([string]$Path, $Config) {
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}
function Get-Owned($Config, [string]$Name) {
    $v = $Config.owned.$Name
    if ($null -eq $v) { return 0.0 }
    return [double]$v
}
function Set-Owned($Config, [string]$Name, [double]$Value) {
    $val = [Math]::Max(0.0, $Value)
    $Config.owned.$Name = $val
    return $val
}
function Add-Owned($Config, [string]$Name, [double]$Amount) {
    return Set-Owned $Config $Name ((Get-Owned $Config $Name) + $Amount)
}

# ============ 绘制进度条 ============
# RefMode: 'normal' (对齐), 'need-center' (需求为基准), 'owned-center' (拥有为基准)
# $GlobalMin / $GlobalMax 为坐标轴范围。
#   need-center  : 基准线 1.0 固定映射到 1/GlobalMax 处，GlobalMin 恒为 0
#   owned-center : 基准线 1.0 固定映射到 1/GlobalMax 处，GlobalMin 恒为 0
function Write-Bar([double]$R, [double]$O, [int]$Width, [double]$MaxScale, [string]$RefMode = 'normal', [double]$GlobalMin = 0, [double]$GlobalMax = 0) {
    if ($R -le 0 -and $O -le 0) { Write-C ('·' * $Width) DarkGray; return }

    $pR = 0
    $pO = 0

    if ($RefMode -eq 'need-center' -or $RefMode -eq 'owned-center') {
        if ($GlobalMax -le 0) { $GlobalMax = 1.0 }
        $pR = [int][Math]::Round([Math]::Min($R, $GlobalMax) / $GlobalMax * ($Width - 1))
        $pO = [int][Math]::Round([Math]::Min($O, $GlobalMax) / $GlobalMax * ($Width - 1))
    }
    else {
        if ($MaxScale -gt 0) {
            $pR = [int][Math]::Round($R / $MaxScale * ($Width - 1))
            $pO = [int][Math]::Round($O / $MaxScale * ($Width - 1))
        }
    }

    if ($pR -lt 0) { $pR = 0 }; if ($pR -ge $Width) { $pR = $Width - 1 }
    if ($pO -lt 0) { $pO = 0 }; if ($pO -ge $Width) { $pO = $Width - 1 }

    for ($i = 0; $i -lt $Width; $i++) {
        if ($i -eq $pR -and $i -eq $pO) { Write-C '◆' Yellow }
        elseif ($i -eq $pR)             { Write-C '▼' Cyan }
        elseif ($i -eq $pO)             { Write-C '▲' White }
        elseif ($i -lt [Math]::Min($pR, $pO)) { Write-C '█' DarkGray }
        elseif ($i -gt [Math]::Max($pR, $pO)) { Write-C '·' DarkGray }
        elseif ($O -lt $R)              { Write-C '░' DarkRed }
        else                            { Write-C '░' DarkGreen }
    }
}

# ============ 界面 ============
function Show-CmdQuickRef {
    $commands = @(
        @{ Cmd = 're';                Desc = '查看报告' },
        @{ Cmd = 'fill';              Desc = '按顺序录入各材料数量' },
        @{ Cmd = 'toggle';            Desc = '切换某板块启用状态' },
        @{ Cmd = 'help';              Desc = '显示完整帮助' },
        @{ Cmd = 'exit';              Desc = '退出交互环境' }
    )
    $cmdWidth = 22
    Write-C ('─' * 58) DarkGray
    NL
    foreach ($c in $commands) {
        Write-C ('    ' + ($c.Cmd).PadRight($cmdWidth)) Gray
        Write-C $c.Desc DarkGray
        NL
    }
    Write-C ('─' * 58) DarkGray
    NL
}

function Show-Help {
    NL
    Write-C '  交互环境内直接输入：' Yellow; NL
    Write-C '    report / re                                 查看报告' White; NL
    Write-C '    input / fill                                按默认顺序依次录入各材料数量' White; NL
    Write-C '    set <材料名> <数量>                         设置拥有量（例：set 协议圆盘 500）' White; NL
    Write-C '    add <材料名> <数量>                         增加拥有量（负数即减少，例：add 协议圆盘 -5）' White; NL
    Write-C '    toggle <板块名>                             切换板块启用状态' White; NL
    Write-C '    section <板块1>,<板块2>                     设置启用板块（覆盖）' White; NL
    Write-C '    section all                                 启用全部板块' White; NL
    Write-C '    sort <default|shortage>                     设置图表排序（默认/缺口降序）' White; NL
    Write-C '    scale <aligned|need|owned|sanity>           设置对齐口径（最大对齐/需求刻度/拥有刻度/理智价值）' White; NL
    Write-C '    list                                        列出材料名/板块名' White; NL
    Write-C '    clear / cls                                 清屏' White; NL
    Write-C '    exit / quit                                 退出交互环境' White; NL
    Write-C '    help                                        显示本帮助' White; NL
    Write-C '    中文别名：set=设置/改，add=增加/加，toggle=切换，section=板块，list=列表，help=帮助，report=查看/re' DarkGray; NL
    NL
}

# 按默认顺序录入材料数量
function Invoke-InputMode {
    $cfg = Read-Config $ConfigFile
    $materials = @($cfg.farmRates.PSObject.Properties.Name)
    if ($materials.Count -eq 0) {
        Write-C '  没有可录入的材料。' Red; NL
        return
    }

    NL
    Write-C '  ◆ 按默认顺序录入材料数量' Yellow
    NL
    Write-C '    直接回车 = 跳过；输入 q = 中止；输入数字 = 设为该拥有量。' DarkGray
    NL

    $updated = 0
    $aborted = $false

    for ($i = 0; $i -lt $materials.Count; $i++) {
        $m = $materials[$i]
        $unit = Get-Unit $m
        $cur = Get-Owned $cfg $m
        $curStr = (Format-Num $cur) + $unit
        $prompt = '  [{0}/{1}] {2}（当前 {3}）> ' -f ($i + 1), $materials.Count, $m, $curStr
        Write-C $prompt Cyan
        try {
            $line = Read-Host -ErrorAction Stop
        } catch {
            $aborted = $true
            break
        }
        $line = if ($null -eq $line) { '' } else { $line.Trim() }
        if ($line -eq '') { continue }
        if ($line -in @('q', 'Q', 'quit', 'exit')) { $aborted = $true; break }

        $val = 0.0
        if (-not [double]::TryParse($line, [ref]$val)) {
            Write-C "  数量无效：'$line'，已跳过。" Red; NL
            continue
        }
        $newVal = Set-Owned $cfg $m $val
        $updated++
        Write-C ('  已更新 {0} → {1}{2}' -f $m, (Format-Num $newVal), $unit) Green
        NL
    }

    if ($updated -gt 0) {
        Write-Config $ConfigFile $cfg
    }

    NL
    if ($aborted) {
        Write-C ('  录入已中止，本次更新 {0} 项。' -f $updated) DarkGray
    } else {
        Write-C ('  录入完成，本次更新 {0} 项。' -f $updated) DarkGray
    }
    NL
    Show-Report
}

function Start-EndfieldShell {
    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $engine = Join-Path $PSHOME $engineName
    if (-not (Test-Path -LiteralPath $engine)) { $engine = $engineName }

    $validCmds = @(
        'report','查看','r','re',
        'input','录入','fill','enter','i',
        'set','设置','改','update','u',
        'add','增加','加','a',
        'toggle','切换','t',
        'section','板块','s',
        'list','列表','l',
        'help','帮助','h','?','-h','--help',
        'sort','scale',
        'clear','cls','清屏',
        'exit','quit','q','退出'
    )

    Clear-Host
    Show-Report

    while ($true) {
        try {
            Write-C 'EndfieldLedger> ' Yellow
            $line = Read-Host -ErrorAction Stop
        } catch {
            Write-C '  无法读取交互输入，已退出资源规划命令环境。' Red; NL
            break
        }
        $line = if ($null -eq $line) { '' } else { $line.Trim() }
        if (-not $line) { continue }

        $tokens = @($line -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -eq 0) { continue }
        $command = $tokens[0].ToLowerInvariant()

        if ($command -notin $validCmds) {
            Write-C "  未知指令：'$command'。输入 help 查看可用指令。" Red; NL
            continue
        }

        if ($command -in @('exit', 'quit', 'q', '退出')) { break }
        if ($command -in @('clear', 'cls', '清屏')) { Clear-Host; continue }

        if ($command -in @('input', '录入', 'fill', 'enter', 'i')) {
            Invoke-InputMode
            continue
        }

        if ($command -in @('set', '设置', '改', 'update', 'u', 'add', '增加', '加', 'a')) {
            if ($tokens.Count -lt 3) {
                Write-C "  用法：$($tokens[0]) <材料名> <数量>" Red; NL
                continue
            }
            $matName = $tokens[1]
            $numStr  = $tokens[2]
            $numVal  = 0.0
            if (-not [double]::TryParse($numStr, [ref]$numVal)) {
                Write-C "  数量无效：'$numStr'。请提供数字（可带负号）。" Red; NL
                continue
            }
            $verb = if ($command -in @('set', '设置', '改', 'update', 'u')) { 'set' } else { 'add' }
            & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $verb $matName -Number $numVal
            continue
        }

        if ($command -eq 'sort') {
            $val = if ($tokens.Count -gt 1) { $tokens[1].ToLower() } else { '' }
            if ($val -in @('shortage', '缺', '缺口')) {
                $cfg = Read-Config $ConfigFile; $cfg.monitorSort = 'shortage'; Write-Config $ConfigFile $cfg
                Write-C "  排序已设置为：缺口从高到低" Green; NL
                & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath 'report'
            } elseif ($val -in @('default', '默认')) {
                $cfg = Read-Config $ConfigFile; $cfg.monitorSort = 'default'; Write-Config $ConfigFile $cfg
                Write-C "  排序已设置为：默认顺序" Green; NL
                & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath 'report'
            } else {
                Write-C "  用法：sort <default|shortage>" Red; NL
            }
            continue
        }

        if ($command -eq 'scale') {
            $val = if ($tokens.Count -gt 1) { $tokens[1].ToLower() } else { '' }
            if ($val -in @('sanity', '理智', '等长')) {
                $cfg = Read-Config $ConfigFile; $cfg.monitorScale = 'sanity'; Write-Config $ConfigFile $cfg
                Write-C "  刻度已设置为：按理智价值等长" Green; NL
                & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath 'report'
            } elseif ($val -in @('need', '需求', '所需')) {
                $cfg = Read-Config $ConfigFile; $cfg.monitorScale = 'need'; Write-Config $ConfigFile $cfg
                Write-C "  刻度已设置为：需求刻度" Green; NL
                & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath 'report'
            } elseif ($val -in @('owned', '拥有', '上三角')) {
                $cfg = Read-Config $ConfigFile; $cfg.monitorScale = 'owned'; Write-Config $ConfigFile $cfg
                Write-C "  刻度已设置为：拥有刻度" Green; NL
                & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath 'report'
            } elseif ($val -in @('aligned', '最大值', '最大对齐', '默认')) {
                $cfg = Read-Config $ConfigFile; $cfg.monitorScale = 'aligned'; Write-Config $ConfigFile $cfg
                Write-C "  刻度已设置为：最大对齐" Green; NL
                & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath 'report'
            } else {
                Write-C "  用法：scale <aligned|need|owned|sanity>" Red; NL
            }
            continue
        }

        & $engine -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @tokens
    }

    NL
    Write-C '  已退出资源规划命令环境。' DarkGray; NL
}

function Show-List($Config) {
    $sections = @($Config.requirements.PSObject.Properties.Name)
    $materials = @($Config.farmRates.PSObject.Properties.Name)
    NL
    Write-C '  可用板块（toggle/section 的对象）：' Yellow; NL
    foreach ($s in $sections) { Write-C ('      ' + $s) White; NL }
    Write-C '  可用材料（set/add 的对象）：' Yellow; NL
    foreach ($m in $materials) {
        $u = Get-Unit $m
        $suffix = if ($u) { "（单位：$u）" } else { '' }
        Write-C ('      ' + $m + $suffix) White; NL
    }
    NL
}

function Show-Report {
    $Config  = Read-Config $ConfigFile
    $sections = @($Config.requirements.PSObject.Properties.Name)
    $materials = @($Config.farmRates.PSObject.Properties.Name)
    $enabled = @($Config.enabledSections)
    if ($null -eq $enabled -or $enabled.Count -eq 0) { $enabled = @($sections) }
    $notes = @($Config.notes)

    $sortMode = ([string]$Config.monitorSort).Trim().ToLower()
    if ($sortMode -in @('缺', '缺口', '缺口从高到低', 'shortage')) { $sortMode = 'shortage' }
    else { $sortMode = 'default' }

    $scaleMode = ([string]$Config.monitorScale).Trim().ToLower()
    if ($scaleMode -in @('理智', '体力', '等长', 'sanity', 'runs')) { $scaleMode = 'sanity' }
    elseif ($scaleMode -in @('需求', '所需', 'need')) { $scaleMode = 'need' }
    elseif ($scaleMode -in @('拥有', '上三角', 'owned')) { $scaleMode = 'owned' }
    else { $scaleMode = 'aligned' }

    $need = [ordered]@{}
    foreach ($m in $materials) { $need[$m] = 0.0 }
    foreach ($s in $enabled) {
        $sec = $Config.requirements.$s
        if ($null -ne $sec) {
            foreach ($prop in $sec.PSObject.Properties) {
                $k = $prop.Name
                if ($need.Contains($k)) { $need[$k] = [double]$need[$k] + [double]$prop.Value }
            }
        }
    }

    NL
    Write-C '  ◆ 明日方舟：终末地 · 资源概况与刷取规划' Yellow
    NL
    Write-C ('─' * 58) DarkGray
    NL
    Write-C '  已启用板块：' Cyan
    Write-C ($enabled -join '、') White
    NL
    Write-C '  说明：以下均为「单干员」养成需求；刷取按 80 理智/局 计算。' DarkGray
    NL
    NL

    $sortLabel = if ($sortMode -eq 'shortage') { '缺口从高到低' } else { '默认' }
    $scaleLabel = switch ($scaleMode) {
        'sanity' { '理智价值' }
        'need'   { '需求刻度' }
        'owned'  { '拥有刻度' }
        default  { '最大对齐' }
    }
    Write-C '  【资源概况】' Yellow
    Write-C '  排序：' DarkGray
    Write-C $sortLabel Magenta
    Write-C '  刻度：' DarkGray
    Write-C $scaleLabel Magenta
    NL
    Write-C '    图例：' DarkGray
    Write-C '█' DarkGray; Write-C '已拥有(重叠)  ' DarkGray
    Write-C '░' DarkRed; Write-C '缺口区  ' DarkGray
    Write-C '░' DarkGreen; Write-C '富余区  ' DarkGray
    Write-C '▼' Cyan; Write-C '需求刻度  ' DarkGray
    Write-C '▲' White; Write-C '拥有刻度  ' DarkGray
    Write-C '◆' Yellow; Write-C '重合' DarkGray
    NL

    $stats = @()
    foreach ($m in $materials) {
        $R = [double]$need[$m]
        $O = Get-Owned $Config $m
        $rate = 0.0
        $rv = $Config.farmRates.$m
        if ($null -ne $rv) { $rate = [double]$rv }
        $rruns = $R
        $oruns = $O
        if ($rate -gt 0) { $rruns = $R / $rate; $oruns = $O / $rate }
        $stats += [pscustomobject]@{ Name = $m; R = $R; O = $O; Shortage = ($R - $O); Rruns = $rruns; Oruns = $oruns }
    }
    if ($sortMode -eq 'shortage') {
        $stats = @($stats | Sort-Object Shortage -Descending)
    }

    $commonMax = 0.0
    $globalMin = 0.0
    $globalMax = 1.0

    if ($scaleMode -eq 'sanity') {
        foreach ($s in $stats) { $commonMax = [Math]::Max($commonMax, [Math]::Max($s.Rruns, $s.Oruns)) }
    } elseif ($scaleMode -eq 'need') {
        $globalMin = 0.0
        $globalMax = 1.0
        foreach ($s in $stats) {
            if ($s.R -gt 0) {
                $ratioO = $s.O / $s.R
                if ($ratioO -gt $globalMax) { $globalMax = $ratioO }
            }
        }
    } elseif ($scaleMode -eq 'owned') {
        $globalMin = 0.0
        $globalMax = 1.0
        foreach ($s in $stats) {
            if ($s.O -gt 0) {
                $ratioR = $s.R / $s.O
                if ($ratioR -gt $globalMax) { $globalMax = $ratioR }
            }
        }
    } else {
        foreach ($s in $stats) { $commonMax = [Math]::Max($commonMax, [Math]::Max($s.R, $s.O)) }
    }

    foreach ($s in $stats) {
        $m = $s.Name
        $R = $s.R
        $O = $s.O
        $unit = Get-Unit $m
        $reqStr = (Format-Num $R) + $unit
        $ownStr = (Format-Num $O) + $unit
        $d = $O - $R

        $Rd = $R
        $Od = $O
        $scaleMax = 1.0
        $refMode = 'normal'

        if ($scaleMode -eq 'sanity') {
            $Rd = $s.Rruns
            $Od = $s.Oruns
            $scaleMax = $commonMax
        } elseif ($scaleMode -eq 'need') {
            $refMode = 'need-center'
            $Rd = 1.0
            $Od = if ($R -gt 0) { $O / $R } else { 1.0 }
        } elseif ($scaleMode -eq 'owned') {
            $refMode = 'owned-center'
            $Od = 1.0
            $Rd = if ($O -gt 0) { $R / $O } else { 1.0 }
        } else {
            $scaleMax = [Math]::Max($R, $O)
            if ($scaleMax -le 0) { $scaleMax = 1 }
        }

        Write-C ('  ' + (Pad-Display $m $NameWidth)) White
        Write-C '[' DarkGray
        Write-Bar $Rd $Od $BarWidth $scaleMax $refMode $globalMin $globalMax
        Write-C ']' DarkGray

        Write-C '  需 ' DarkGray
        Write-C (Pad-Right $reqStr $ValWidth) Cyan
        Write-C '  有 ' DarkGray
        Write-C (Pad-Right $ownStr $ValWidth) White

        if ($d -gt 1e-9) {
            Write-C '  富余 ' DarkGreen
            Write-C (Pad-Right ((Format-Num $d) + $unit) $ValWidth) Green
        } elseif ($d -lt -1e-9) {
            Write-C '  缺口 ' DarkRed
            Write-C (Pad-Right ((Format-Num (-$d)) + $unit) $ValWidth) Red
        } else {
            Write-C '  持平' DarkGray
        }
        NL
    }
    NL

    # ==== 刷取规划：自动升阶到下一名干员 ====
    Write-C '  【刷取规划】' Yellow
    Write-C '    按缺口从高到低' DarkGray
    NL

    $ownerCount = 0   # 已完整满足的干员数
    $rows = @()
    $gapTier = 0      # 当前缺口对应的“第 N 位干员”

    while ($true) {
        $nextCount = $ownerCount + 1
        $candidate = @()
        foreach ($m in $materials) {
            $R = [double]$need[$m] * $nextCount
            $O = Get-Owned $Config $m
            $gap = $R - $O
            if ($gap -gt 1e-9) {
                $rate = 0.0
                $rv = $Config.farmRates.$m
                if ($null -ne $rv) { $rate = [double]$rv }
                $candidate += [pscustomobject]@{ Name = $m; Gap = $gap; Rate = $rate; Unit = (Get-Unit $m) }
            }
        }
        if ($candidate.Count -eq 0) {
            $ownerCount = $nextCount
            if ($nextCount -ge 99) { break }
            continue
        } else {
            $gapTier = $nextCount
            $rows = @($candidate | Sort-Object Gap -Descending)
            break
        }
    }

    if ($ownerCount -ge 1 -and $gapTier -ge 2) {
        $msg = '  所有材料均已满足 {0} 位干员需求，无需刷取。下面是培养第 {1} 位干员的缺口：' -f $ownerCount, $gapTier
        Write-C $msg DarkGreen
        NL
    }

    if ($rows.Count -eq 0) {
        # 极端兜底：连续 99 位都完全满足，正常不会走到这里
        Write-C ('  所有材料均已满足 {0} 位干员需求，无需刷取。' -f $ownerCount) Green
        NL
    } else {
        $rank = 0
        $totalRuns = 0.0
        $gapColor = if ($gapTier -ge 2) { [System.ConsoleColor]::DarkYellow } else { [System.ConsoleColor]::Red }
        foreach ($r in $rows) {
            $rank++
            $runs   = if ($r.Rate -gt 0) { [int][Math]::Ceiling($r.Gap / $r.Rate) } else { 0 }
            $sanity = $runs * 80
            $totalRuns += $runs
            Write-C ('  {0,2}. ' -f $rank) Yellow
            Write-C (Pad-Display $r.Name $NameWidth) White
            Write-C '缺口 ' DarkGray
            Write-C (Pad-Right ((Format-Num $r.Gap) + $r.Unit) $ValWidth) $gapColor
            Write-C ('  约 {0,3} 局 / {1,6} 理智' -f $runs, $sanity) Yellow
            NL
        }
        NL
        Write-C ('  合计 {0} 种材料缺料，约需 {1} 局 / {2} 理智（未计溢出，供参考）。' -f $rows.Count, [int]$totalRuns, [int]($totalRuns * 80)) DarkGray
        NL
    }

    Write-C '  【提示】' Yellow
    NL
    foreach ($n in $notes) {
        Write-C ('    · ' + $n) DarkGray
        NL
    }

    Show-CmdQuickRef
}

# ============ 主流程 ============
$cmd = ([string]$Action).Trim().ToLower()
if ($cmd -in @('', 'shell', '环境', 'interactive', 'i')) { $cmd = 'shell' }
elseif ($cmd -in @('report', '查看', 'r', 're'))       { $cmd = 'report' }
elseif ($cmd -in @('input', '录入', 'fill', 'enter'))   { $cmd = 'input' }
elseif ($cmd -in @('set', '设置', '改', 'update', 'u')) { $cmd = 'set' }
elseif ($cmd -in @('add', '增加', '加', 'a'))            { $cmd = 'add' }
elseif ($cmd -in @('toggle', '切换', 't'))               { $cmd = 'toggle' }
elseif ($cmd -in @('section', '板块', 's'))              { $cmd = 'section' }
elseif ($cmd -in @('list', '列表', 'l'))                 { $cmd = 'list' }
elseif ($cmd -in @('help', '帮助', 'h', '?', '-h', '--help')) { $cmd = 'help' }

$items = @()
foreach ($t in $Target) {
    foreach ($part in @($t -split ',')) {
        $p = ([string]$part).Trim()
        if ($p) { $items += $p }
    }
}

switch ($cmd) {
    'shell' { Start-EndfieldShell }
    'help' { Show-Help }
    'list' { $cfg = Read-Config $ConfigFile; Show-List $cfg }
    'report' { Show-Report }
    'input' { Invoke-InputMode }

    'set' {
        $cfg = Read-Config $ConfigFile
        $materials = @($cfg.farmRates.PSObject.Properties.Name)
        if ($items.Count -ne 1 -or $materials -notcontains $items[0]) {
            Write-Host "未知材料或缺少材料名：'$($Target -join ',')'。用法：set <材料名> <数量>" -ForegroundColor Red
            Show-List $cfg
            exit 1
        }
        $t = $items[0]
        $val = Set-Owned $cfg $t $Number
        Write-Config $ConfigFile $cfg
        Write-C "已更新 ${t} → $(Format-Num $val)$(Get-Unit $t)" Green
        NL
        Show-Report
    }
    'add' {
        $cfg = Read-Config $ConfigFile
        $materials = @($cfg.farmRates.PSObject.Properties.Name)
        if ($items.Count -ne 1 -or $materials -notcontains $items[0]) {
            Write-Host "未知材料或缺少材料名：'$($Target -join ',')'。用法：add <材料名> <数量>" -ForegroundColor Red
            Show-List $cfg
            exit 1
        }
        $t = $items[0]
        $val = Add-Owned $cfg $t $Number
        Write-Config $ConfigFile $cfg
        Write-C "已调整 ${t}（$Number）→ 现为 $(Format-Num $val)$(Get-Unit $t)" Green
        NL
        Show-Report
    }
    'toggle' {
        $cfg = Read-Config $ConfigFile
        $sections = @($cfg.requirements.PSObject.Properties.Name)
        if ($items.Count -ne 1 -or $sections -notcontains $items[0]) {
            Write-Host "未知板块或缺少板块名：'$($Target -join ',')'。可用板块：$($sections -join '、')" -ForegroundColor Red
            exit 1
        }
        $t = $items[0]
        $cur = @($cfg.enabledSections)
        if ($cur -contains $t) { $new = @($cur | Where-Object { $_ -ne $t }) }
        else { $new = @($cur) + $t }
        $cfg.enabledSections = @($new)
        Write-Config $ConfigFile $cfg
        Write-C "已切换「$t」：$($new -join '、')" Green
        NL
        Show-Report
    }
    'section' {
        $cfg = Read-Config $ConfigFile
        $sections = @($cfg.requirements.PSObject.Properties.Name)
        if ($items.Count -eq 0) {
            Write-Host '用法：section <板块1,板块2,...> 或 section all' -ForegroundColor Red
            exit 1
        }
        $names = $items
        if ($names -contains 'all' -or $names -contains '全部' -or $names -contains 'reset') {
            $names = $sections
        }
        foreach ($n in $names) {
            if ($sections -notcontains $n) {
                Write-Host "未知板块：'$n'。可用板块：$($sections -join '、')" -ForegroundColor Red
                exit 1
            }
        }
        $cfg.enabledSections = @($names)
        Write-Config $ConfigFile $cfg
        Write-C "已设置启用板块：$($names -join '、')" Green
        NL
        Show-Report
    }

    default {
        Write-Host "未知指令：'$Action'。可用指令见下方帮助。" -ForegroundColor Red
        Show-Help
        exit 1
    }
}