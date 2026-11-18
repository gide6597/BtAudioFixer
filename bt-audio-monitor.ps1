# 蓝牙音箱 A2DP 掉线监控脚本
# 用途: 持续采样 HUAWEI AI Speaker2 的 A2DP 端点状态, 记录掉线规律
# 用法(本机为 Windows PowerShell 5.1, 无 pwsh):
#   在 DeepSeek Harness 中直接粘贴脚本正文执行, 或:
#   powershell -ExecutionPolicy Bypass -File bt-audio-monitor.ps1 -Minutes 10 -IntervalSec 5

param(
    [int]$Minutes = 10,
    [int]$IntervalSec = 5,
    [string]$OutDir = "$PSScriptRoot"
)

$ErrorActionPreference = 'SilentlyContinue'
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath  = Join-Path $OutDir "bt-audio-log-$stamp.csv"
$txtPath  = Join-Path $OutDir "bt-audio-log-$stamp.txt"

$renderBase = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'

function Get-EndpointState {
    param([string]$Match)

    $out = @{}
    Get-ChildItem $renderBase | ForEach-Object {
        $p    = Get-ItemProperty "$($_.PSPath)\Properties"
        $name = "$($p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2')$($p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6')"
        if ($name -match $Match) {
            $state = (Get-ItemProperty $_.PSPath).DeviceState
            $label = switch ($state) {
                1 { 'ACTIVE' }
                2 { 'DISABLED' }
                4 { 'NOTPRESENT' }
                8 { 'UNPLUGGED' }
                default { "OTHER($state)" }
            }
            $out[$name] = $label
        }
    }
    return $out
}

function Get-BtLinkState {
    # A2DP(音频) / HFP(免提) / AVRCP(遥控) 三层链路各自是否真的挂着
    $a2dp  = (Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue |
              Where-Object { $_.FriendlyName -match 'HUAWEI.*Stereo' -and $_.Problem -ne 'CM_PROB_PHANTOM' } |
              Measure-Object).Count
    $hfp   = (Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue |
              Where-Object { $_.FriendlyName -match 'HUAWEI.*Hands-Free' -and $_.Problem -ne 'CM_PROB_PHANTOM' } |
              Measure-Object).Count
    $avrcp = (Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
              Where-Object { $_.FriendlyName -match 'HUAWEI.*Avrcp' -and $_.Problem -ne 'CM_PROB_PHANTOM' } |
              Measure-Object).Count
    return [pscustomobject]@{ A2DP = $a2dp; HFP = $hfp; AVRCP = $avrcp }
}

$deadline = (Get-Date).AddMinutes($Minutes)
$rows     = @()
$events   = @()

Write-Host "监控开始, 持续 $Minutes 分钟, 每 $IntervalSec 秒采样一次" -ForegroundColor Cyan
Write-Host "日志: $csvPath" -ForegroundColor DarkGray

while ((Get-Date) -lt $deadline) {
    $now   = Get-Date
    $eps   = Get-EndpointState 'HUAWEI'
    $links = Get-BtLinkState

    $a2dp1571 = $eps['扬声器HUAWEI AI Speaker2-01571 Stereo']
    $a2dp8547 = $eps['扬声器HUAWEI AI Speaker2-85474 Stereo']

    $row = [pscustomobject]@{
        时间           = $now.ToString('HH:mm:ss')
        A2DP音频链路数  = $links.A2DP
        HFP免提链路数   = $links.HFP
        AVRCP遥控链路数 = $links.AVRCP
        '01571_Stereo'  = $a2dp1571
        '85474_Stereo'  = $a2dp8547
    }
    $rows += $row

    # 检测异常: 遥控在但音频不在 = 正是"连上没声音"
    $flag = ''
    if ($links.AVRCP -gt 0 -and $links.A2DP -eq 0) { $flag = '!! 遥控已连但A2DP音频通道缺失 = 无声故障' }
    elseif ($a2dp1571 -eq 'ACTIVE')                { $flag = 'OK 音频端点活跃' }
    elseif ($a2dp1571 -eq 'UNPLUGGED')             { $flag = '-- A2DP端点未挂载' }

    $line = "{0}  A2DP={1} HFP={2} AVRCP={3}  01571={4}  85474={5}  {6}" -f `
            $now.ToString('HH:mm:ss'), $links.A2DP, $links.HFP, $links.AVRCP, $a2dp1571, $a2dp8547, $flag

    Write-Host $line
    if ($flag -ne '') { $events += $line }

    Start-Sleep -Seconds $IntervalSec
}

$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
@(
    "蓝牙音箱 A2DP 掉线监控报告",
    "生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "采样时长: $Minutes 分钟 / 间隔 $IntervalSec 秒 / 共 $($rows.Count) 个采样点",
    "",
    "=== 状态分布 ===",
    "01571_Stereo: " + (($rows | Group-Object '01571_Stereo' | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  '),
    "85474_Stereo: " + (($rows | Group-Object '85474_Stereo' | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  '),
    "",
    "=== 异常事件 (遥控连着但音频掉了) ===",
    $(if ($events.Count) { $events } else { "(无异常)" })
) | Set-Content -Path $txtPath -Encoding UTF8

Write-Host "`n完成. 报告: $txtPath" -ForegroundColor Green
Write-Host "结果分布: 01571=" + (($rows | Group-Object '01571_Stereo' | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ' ') -ForegroundColor Yellow
