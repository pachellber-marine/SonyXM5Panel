# SonyXM5Panel.ps1 — WH-1000XM5 全功能控制台 (Windows, 纯 PowerShell + WPF, 无依赖)
# 功能: 环境声控制(降噪/环境声/关闭 + ASM 等级) / 关注语音 / 智能免摘(Speak-to-Chat)开关 / 连接管理
# 协议: mdr.v2 (Sony WH-1000XM5), RFCOMM SPP UUID 956c7b26-d49a-4ba8-b03f-b17d393cb6e2
# 启动: powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File SonyXM5Panel.ps1

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$SPP_UUID = [Guid]'956c7b26-d49a-4ba8-b03f-b17d393cb6e2'

# ---------- C# 流读写 helper (PS 5.1 无法直接操作 WinRT 流) ----------
$dllFile = Join-Path $env:TEMP 'BtStream_s2c.dll'
if (-not (Test-Path $dllFile)) {
  $btCs = @'
using System;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;

public static class BtStream
{
    public static object MakeWriter(object socketObj)
    {
        var s = (StreamSocket)socketObj;
        return new DataWriter(s.OutputStream);
    }
    public static object MakeReader(object socketObj)
    {
        var s = (StreamSocket)socketObj;
        var r = new DataReader(s.InputStream);
        r.InputStreamOptions = InputStreamOptions.Partial;
        return r;
    }
    public static uint Write(object writerObj, byte[] data)
    {
        var w = (DataWriter)writerObj;
        w.WriteBytes(data);
        return AwaitOp<uint>((Windows.Foundation.IAsyncOperation<uint>)w.StoreAsync(), 10000);
    }
    // 单一挂起读: LoadAsync 不支持取消(取消即报废), 保留 pending op 轮询; 仅允许单线程调用
    static Windows.Foundation.IAsyncOperation<uint> pendingLoad = null;
    static System.Threading.ManualResetEvent loadEvt = new System.Threading.ManualResetEvent(false);
    public static byte[] ReadPoll(object readerObj, int timeoutMs)
    {
        var r = (DataReader)readerObj;
        if (pendingLoad == null)
        {
            pendingLoad = r.LoadAsync(512);
            pendingLoad.Completed = (o, s) => { loadEvt.Set(); };
        }
        if (!loadEvt.WaitOne(timeoutMs)) return null;
        var op = pendingLoad; pendingLoad = null; loadEvt.Reset();
        if (op.Status != Windows.Foundation.AsyncStatus.Completed) throw new Exception("read fail: " + op.ErrorCode);
        uint n = op.GetResults();
        if (n == 0) throw new Exception("EOF");
        byte[] buf = new byte[n];
        r.ReadBytes(buf);
        return buf;
    }
    static T AwaitOp<T>(Windows.Foundation.IAsyncOperation<T> op, int timeoutMs)
    {
        var done = new System.Threading.ManualResetEvent(false);
        op.Completed = (o, s) => { if (s != Windows.Foundation.AsyncStatus.Started) done.Set(); };
        if (!done.WaitOne(timeoutMs))
        {
            try { op.Cancel(); } catch { }
            done.WaitOne(500);
            throw new TimeoutException("winrt op timeout");
        }
        if (op.Status != Windows.Foundation.AsyncStatus.Completed) throw new Exception("winrt op failed: " + op.ErrorCode);
        return op.GetResults();
    }
    public static void CloseWriter(object w) { ((DataWriter)w).Dispose(); }
    public static void CloseReader(object r) { ((DataReader)r).Dispose(); }
    public static void CloseSocket(object s) { ((StreamSocket)s).Dispose(); }
}
'@
  $csFile = Join-Path $env:TEMP 'BtStream.cs'
  [IO.File]::WriteAllText($csFile, $btCs, (New-Object System.Text.UTF8Encoding $true))
  $csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  $swr = Get-ChildItem "$env:windir\Microsoft.NET\assembly\GAC_MSIL\System.Runtime\v4.0_4.0.*\System.Runtime.dll" | Select-Object -First 1
  & $csc /nologo /t:library /out:"$dllFile" /r:"$($swr.FullName)" `
    /r:"$env:windir\System32\WinMetadata\Windows.Foundation.winmd" `
    /r:"$env:windir\System32\WinMetadata\Windows.Networking.winmd" `
    /r:"$env:windir\System32\WinMetadata\Windows.Storage.winmd" `
    "$csFile"
  if ($LASTEXITCODE -ne 0) { throw "BtStream compile failed" }
}
[void][Reflection.Assembly]::LoadFrom($dllFile)
[void][Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
[void][Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId, Windows.Devices.Bluetooth.Rfcomm, ContentType=WindowsRuntime]
[void][Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService, Windows.Devices.Bluetooth.Rfcomm, ContentType=WindowsRuntime]
[void][Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult, Windows.Devices.Bluetooth.Rfcomm, ContentType=WindowsRuntime]
[void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
[void][Windows.Networking.Sockets.StreamSocket, Windows.Networking.Sockets, ContentType=WindowsRuntime]

$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$resultType, [int]$timeoutMs = 15000) {
  $asTask = $script:asTaskGeneric.MakeGenericMethod($resultType)
  $netTask = $asTask.Invoke($null, @($op))
  if (-not $netTask.Wait($timeoutMs)) { throw "WinRT timeout" }
  return $netTask.Result
}
function AwaitAction($action, [int]$timeoutMs = 15000) {
  $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
  $netTask = $asTaskAction.Invoke($null, @($action))
  try {
    if (-not $netTask.Wait($timeoutMs)) { throw "WinRT timeout" }
  } catch {
    $agg = $_.Exception.InnerException
    if ($agg -and $agg.InnerExceptions.Count -gt 0) {
      $msgs = ($agg.InnerExceptions | ForEach-Object { $_.Message + ' (' + $_.HResult.ToString('X') + ')' }) -join ' | '
      throw "RFCOMM connect failed: $msgs"
    }
    throw
  }
}

# ---------- 帧封装 (帧格式: 3e | type seq len(4,BE) payload chk(escaped) | 3c) ----------
function New-Frame([byte]$type, [byte]$seq, [byte[]]$payload) {
  $body = New-Object System.Collections.Generic.List[byte]
  $body.Add($type); $body.Add($seq)
  $len = $payload.Length
  $body.Add([byte](($len -shr 24) -band 0xFF)); $body.Add([byte](($len -shr 16) -band 0xFF))
  $body.Add([byte](($len -shr 8) -band 0xFF));  $body.Add([byte]($len -band 0xFF))
  foreach ($b in $payload) { $body.Add([byte]$b) }
  $sum = 0; foreach ($b in $body) { $sum = ($sum + $b) -band 0xFF }
  $out = New-Object System.Collections.Generic.List[byte]
  $out.Add([byte]0x3e)
  foreach ($b in ($body + [byte]$sum)) {
    if ($b -eq 0x3e -or $b -eq 0x3c -or $b -eq 0x3d) { $out.Add([byte]0x3d); $out.Add([byte]($b -band 0xEF)) }
    else { $out.Add([byte]$b) }
  }
  $out.Add([byte]0x3c)
  return $out.ToArray()
}
function Unescape([byte[]]$raw) {
  $res = New-Object System.Collections.Generic.List[byte]
  for ($i = 0; $i -lt $raw.Length; $i++) {
    if ($raw[$i] -eq 0x3d -and ($i + 1) -lt $raw.Length) { $i++; $res.Add([byte]($raw[$i] -bor 0x10)) }
    else { $res.Add($raw[$i]) }
  }
  return $res.ToArray()
}

# ---------- UI (Win11 风格: 米白底 + 白卡片 + 圆角) ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sony WH-1000XM5 Controller" Height="640" Width="500"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#F3F3F3" FontFamily="Segoe UI, Microsoft YaHei UI" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="Button" x:Key="RdBtn">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextBlock.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="BorderBrush" Value="#E4E4E4"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Style="{StaticResource Card}" Padding="14">
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="Dot" Width="11" Height="11" Fill="#DC2626" VerticalAlignment="Center" Margin="2,0,10,0"/>
        <TextBlock x:Name="ConnText" Text="未连接" FontSize="14" FontWeight="SemiBold" Foreground="#1B1B1B" VerticalAlignment="Center"/>
        <Button x:Name="BtnReconnect" Content="重连" Style="{StaticResource RdBtn}" Width="64" Height="28"
                Margin="14,0,0,0" Background="#0067C0" Foreground="White" FontSize="12"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="环境声控制" FontSize="15" FontWeight="Bold" Foreground="#1B1B1B" Margin="2,0,0,10"/>
        <UniformGrid Columns="3">
          <Button x:Name="BtnNC"  Content="降噪"   Style="{StaticResource RdBtn}" Height="34" Margin="3" FontSize="13"
                  Background="#F0F0F0" Foreground="#1B1B1B" IsEnabled="False"/>
          <Button x:Name="BtnAMB" Content="环境声" Style="{StaticResource RdBtn}" Height="34" Margin="3" FontSize="13"
                  Background="#F0F0F0" Foreground="#1B1B1B" IsEnabled="False"/>
          <Button x:Name="BtnOff" Content="关闭"   Style="{StaticResource RdBtn}" Height="34" Margin="3" FontSize="13"
                  Background="#F0F0F0" Foreground="#1B1B1B" IsEnabled="False"/>
        </UniformGrid>
        <TextBlock x:Name="AsmLabel" Text="环境声等级: --" FontSize="13" Foreground="#616161" Margin="4,12,0,4"/>
        <Slider x:Name="AsmSlider" Minimum="0" Maximum="20" Value="0" IsSnapToTickEnabled="True" TickFrequency="1"
                IsEnabled="False" Margin="4,0,4,0"/>
        <CheckBox x:Name="ChkFocus" Content="关注语音 (Focus on Voice, 环境声模式下生效)" FontSize="13"
                  Foreground="#616161" Margin="4,10,0,0" IsEnabled="False"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="2" Style="{StaticResource Card}">
      <StackPanel Orientation="Horizontal">
        <StackPanel>
          <TextBlock Text="智能免摘 (Speak-to-Chat)" FontSize="15" FontWeight="Bold" Foreground="#1B1B1B"/>
          <TextBlock x:Name="S2cState" Text="状态未知" FontSize="12" Foreground="#9A9A9A" Margin="2,5,0,0"/>
        </StackPanel>
        <Button x:Name="BtnS2c" Content="关闭免摘" Style="{StaticResource RdBtn}" Width="104" Height="34"
                Margin="24,0,0,0" VerticalAlignment="Center" FontSize="13" FontWeight="SemiBold"
                Background="#0067C0" Foreground="White" IsEnabled="False"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="10">
      <TextBox x:Name="LogBox" Background="Transparent" Foreground="#8A8A8A" FontFamily="Consolas"
               FontSize="11" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
    </Border>
  </Grid>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$ctl = @{}
foreach ($n in 'Dot','ConnText','BtnReconnect','BtnNC','BtnAMB','BtnOff','AsmLabel','AsmSlider','ChkFocus','S2cState','BtnS2c','LogBox') { $ctl[$n] = $win.FindName($n) }

$script:bc = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { return $script:bc.ConvertFromString($hex) }

function Add-Log([string]$line) {
  $ctl['LogBox'].AppendText("[$(Get-Date -Format 'HH:mm:ss')] $($line.TrimEnd())`r`n")
  $ctl['LogBox'].ScrollToEnd()
}

# ---------- 共享状态 (UI 与监听 runspace 之间) ----------
$script:queue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$script:txQueue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$script:flags = [hashtable]::Synchronized(@{ Stop = $false })
$script:writer = $null; $script:reader = $null; $script:socket = $null
$script:listener = $null; $script:listenerPs = $null
$script:connector = $null; $script:connectorPs = $null; $script:cx = $null
$script:seq = 0
$script:asc = $null        # 最后一次环境声控制回包 payload
$script:s2c = $null        # 最后一次免摘状态 0x00/0x01
$script:initOk = $false
$script:suppressSlider = $false

function Set-Connected([bool]$on, [string]$msg) {
  if ($on) {
    $ctl['Dot'].Fill = Brush '#16A34A'
    $ctl['ConnText'].Text = $msg
    $ctl['ConnText'].Foreground = Brush '#1B1B1B'
  } else {
    $ctl['Dot'].Fill = Brush '#DC2626'
    $ctl['ConnText'].Text = $msg
    $ctl['ConnText'].Foreground = Brush '#9A9A9A'
    foreach ($n in 'BtnNC','BtnAMB','BtnOff','AsmSlider','ChkFocus','BtnS2c') { $ctl[$n].IsEnabled = $false }
  }
}

# ---------- 监听 runspace (读帧 / 回 ACK / 分发事件) ----------
$listenerScript = {
  param($readerObj, $writerObj, $queue, $flags, $dllPath, $txQueue)
  [void][Reflection.Assembly]::LoadFrom($dllPath)
  function NF([byte]$type, [byte]$seq, [byte[]]$payload) {
    $body = New-Object System.Collections.Generic.List[byte]
    $body.Add($type); $body.Add($seq)
    $len = $payload.Length
    $body.Add([byte](($len -shr 24) -band 0xFF)); $body.Add([byte](($len -shr 16) -band 0xFF))
    $body.Add([byte](($len -shr 8) -band 0xFF));  $body.Add([byte]($len -band 0xFF))
    foreach ($b in $payload) { $body.Add([byte]$b) }
    $sum = 0; foreach ($b in $body) { $sum = ($sum + $b) -band 0xFF }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x3e)
    foreach ($b in ($body + [byte]$sum)) {
      if ($b -eq 0x3e -or $b -eq 0x3c -or $b -eq 0x3d) { $out.Add([byte]0x3d); $out.Add([byte]($b -band 0xEF)) }
      else { $out.Add([byte]$b) }
    }
    $out.Add([byte]0x3c)
    return $out.ToArray()
  }
  function UE([byte[]]$raw) {
    $res = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $raw.Length; $i++) {
      if ($raw[$i] -eq 0x3d -and ($i + 1) -lt $raw.Length) { $i++; $res.Add([byte]($raw[$i] -bor 0x10)) }
      else { $res.Add($raw[$i]) }
    }
    return $res.ToArray()
  }
  $rxbuf = New-Object System.Collections.Generic.List[byte]
  while (-not $flags['Stop']) {
    # 发送队列: UI 只入队, 由监听线程统一写 (UI 是 STA, 不能碰 WinRT 异步)
    while ($txQueue.Count -gt 0) {
      $tx = $txQueue[0]
      try { $txQueue.RemoveAt(0) } catch { break }
      try {
        $frame = NF 0x0c ([byte]$tx.seq) ([byte[]]$tx.payload)
        [void][BtStream]::Write($writerObj, [byte[]]$frame)
      } catch {
        $queue.Add(@{kind='sendfail'; msg=$_.Exception.Message}) | Out-Null
        $flags['Stop'] = $true
        break
      }
    }
    if ($flags['Stop']) { break }
    try { $chunk = [BtStream]::ReadPoll($readerObj, 300) } catch { $queue.Add(@{kind='closed'; msg=$_.Exception.Message}) | Out-Null; break }
    if ($null -eq $chunk) { continue }
    foreach ($b in $chunk) { $rxbuf.Add([byte]$b) }
    while ($true) {
      $start = -1
      for ($i = 0; $i -lt $rxbuf.Count; $i++) { if ($rxbuf[$i] -eq 0x3e) { $start = $i; break } }
      if ($start -lt 0) { if ($rxbuf.Count -gt 0) { $rxbuf.Clear() }; break }
      if ($start -gt 0) { $rxbuf.RemoveRange(0, $start) }
      $end = -1
      for ($i = 1; $i -lt $rxbuf.Count; $i++) { if ($rxbuf[$i] -eq 0x3c) { $end = $i; break } }
      if ($end -lt 0) { break }
      $raw = New-Object byte[] ($end + 1)
      $rxbuf.CopyTo(0, $raw, 0, $end + 1)
      $rxbuf.RemoveRange(0, $end + 1)
      try {
        $msg = UE $raw[1..($raw.Length - 2)]
        if ($msg.Length -lt 7) { continue }
        $type = $msg[0]; $seq = $msg[1]
        $plen = ([uint32]$msg[2] -shl 24) -bor ([uint32]$msg[3] -shl 16) -bor ([uint32]$msg[4] -shl 8) -bor [uint32]$msg[5]
        if ($msg.Length -lt (7 + $plen)) { continue }
        if ($plen -gt 0) { $payload = $msg[6..(5 + $plen)] } else { $payload = @() }
        if ($type -ne 0x01) {
          # 命令帧必须回 ACK (seq 互补)
          try { [void][BtStream]::Write($writerObj, [byte[]](NF 0x01 ([byte](1 - $seq)) @())) } catch { }
          if ($type -eq 0x0c -and $plen -eq 8 -and $payload[0] -eq 0x01) {
            $queue.Add(@{kind='init'}) | Out-Null
          }
          elseif ($type -eq 0x0c -and $plen -ge 4 -and ($payload[0] -eq 0xf7 -or $payload[0] -eq 0xf9) -and $payload[1] -eq 0x0c) {
            $queue.Add(@{kind='s2c'; state=$payload[2]}) | Out-Null
          }
          elseif ($type -eq 0x0c -and $plen -ge 7 -and ($payload[0] -eq 0x67 -or $payload[0] -eq 0x69) -and ($payload[1] -eq 0x15 -or $payload[1] -eq 0x17)) {
            $queue.Add(@{kind='asc'; payload=$payload}) | Out-Null
          }
          else {
            $hex = ($payload | ForEach-Object { $_.ToString('x2') }) -join ' '
            $queue.Add(@{kind='log'; msg=("frame type=0x{0:x2} len=$plen : $hex" -f $type)}) | Out-Null
          }
        }
      } catch { }
    }
  }
}

# ---------- 连接 / 断开 ----------
# 连接脚本: 跑在 MTA runspace 里, 全程不碰 UI; 结果经 queue 回 UI 线程
$connectScript = {
  param($queue, $cx, $dllPath, $sppUuid)
  [void][System.Reflection.Assembly]::LoadFrom($dllPath)
  # UI 线程是 STA 且绝不能阻塞 WinRT 异步 (会死锁), 所以连接整体挪到这里 (MTA)
  function CWait($op, [type]$retType, [int]$ms = 15000) {
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $t = $m.MakeGenericMethod($retType).Invoke($null, @($op))
    if (-not $t.Wait($ms)) { throw "WinRT 超时: $($op.GetType().Name)" }
    return $t.Result
  }
  function CWaitAction($action, [int]$ms = 15000) {
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    $t = $m.Invoke($null, @($action))
    if (-not $t.Wait($ms)) { throw "WinRT 超时: $($action.GetType().Name)" }
  }
  try {
    $selector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true)
    $props = [string[]]@('System.ItemNameDisplay', 'System.Devices.Aep.DeviceAddress')
    $devInfos = CWait ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector, $props)) ([Windows.Devices.Enumeration.DeviceInformationCollection]) 15000
    if ($cx['Cancelled']) { return }
    $sid = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::FromUuid($sppUuid)
    $target = $null; $targetName = ''
    foreach ($di in $devInfos) {
      if ($cx['Cancelled']) { return }
      $addrStr = [string]$di.Properties['System.Devices.Aep.DeviceAddress']
      if (-not $addrStr -or $addrStr -notmatch '^[0-9a-fA-F:]+$') {
        if ($di.Id -match '([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\s*$') { $addrStr = $Matches[1] }
      }
      if (-not $addrStr) { continue }
      $addr = [UInt64]::Parse(($addrStr -replace ':', ''), [System.Globalization.NumberStyles]::HexNumber)
      try {
        $bt = CWait ([Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($addr)) ([Windows.Devices.Bluetooth.BluetoothDevice]) 8000
        if (-not $bt) { continue }
        $svcResult = CWait ($bt.GetRfcommServicesForIdAsync($sid)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult]) 10000
        if ($svcResult.Services.Count -gt 0) { $target = $svcResult.Services[0]; $targetName = [string]$di.Properties['System.ItemNameDisplay']; break }
      } catch { }
    }
    if ($cx['Cancelled']) { return }
    if (-not $target) { $queue.Add(@{kind='connectfail'; msg='没找到耳机 (确认 XM5 已开机)'}) | Out-Null; return }
    if ($cx['Cancelled']) { return }
    $socket = New-Object Windows.Networking.Sockets.StreamSocket
    CWaitAction ($socket.ConnectAsync($target.ConnectionHostName, $target.ServiceId.AsString())) 12000
    if ($cx['Cancelled']) { try { [BtStream]::CloseSocket($socket) } catch {}; return }
    $writer = [BtStream]::MakeWriter($socket)
    $reader = [BtStream]::MakeReader($socket)
    $queue.Add(@{kind='connected'; socket=$socket; writer=$writer; reader=$reader; name=$targetName}) | Out-Null
  } catch {
    $queue.Add(@{kind='connectfail'; msg=$_.Exception.Message}) | Out-Null
  }
}
function Stop-Listener {
  if ($script:listenerPs) {
    $script:flags['Stop'] = $true
    try { [void]$script:listenerPs.BeginStop($null, $null) } catch { }
    $script:listenerPs = $null; $script:listener = $null
    $script:flags['Stop'] = $false
  }
}
function Stop-Connector {
  if ($script:connectorPs) {
    try { [void]$script:connectorPs.BeginStop($null, $null) } catch { }
    $script:connectorPs = $null; $script:connector = $null
  }
}
function Disconnect-Bt {
  Stop-Listener
  if ($script:cx) { $script:cx['Cancelled'] = $true }   # 让还在跑的连接线程自己退出
  Stop-Connector
  if ($script:reader) { try { [BtStream]::CloseReader($script:reader) } catch {} ; $script:reader = $null }
  if ($script:writer) { try { [BtStream]::CloseWriter($script:writer) } catch {} ; $script:writer = $null }
  if ($script:socket) { try { [BtStream]::CloseSocket($script:socket) } catch {} ; $script:socket = $null }
  $script:initOk = $false; $script:asc = $null; $script:s2c = $null
}
function Connect-Bt {
  # UI 线程只负责起连接线程, 连接全程在 MTA runspace 里完成
  Disconnect-Bt
  Set-Connected $false '正在查找耳机...'
  Add-Log '查找已配对的 XM5...'
  $script:cx = [hashtable]::Synchronized(@{ Cancelled = $false })
  $script:connector = [runspacefactory]::CreateRunspace()
  $script:connector.Open()
  $script:connectorPs = [powershell]::Create()
  $script:connectorPs.Runspace = $script:connector
  [void]$script:connectorPs.AddScript($connectScript).AddArgument($script:queue).AddArgument($script:cx).AddArgument($dllFile).AddArgument($SPP_UUID)
  [void]$script:connectorPs.BeginInvoke()
}
function Send-Raw([byte[]]$payload) {
  # UI 线程 (STA) 不碰 WinRT 写, 只入队; 由监听线程统一写
  if (-not $script:socket) { Add-Log '(未连接, 忽略操作)'; return }
  $script:txQueue.Add(@{ seq = [byte]$script:seq; payload = [byte[]]$payload }) | Out-Null
  $script:seq = ($script:seq + 1) -band 0xFF
}

# ---------- 操作 ----------
function Op-Ambient([string]$mode) {
  # mode: nc / amb / off ; 基于最后一次 ASC 回包镜像, 只改 [3] NC开关 与 [4] 模式位
  if (-not $script:asc) { Add-Log '还没拿到环境声状态, 先等查询回包'; return }
  $p = $script:asc
  $set = New-Object byte[] $p.Length
  for ($i = 0; $i -lt $p.Length; $i++) { $set[$i] = [byte]$p[$i] }
  $set[0] = 0x68
  switch ($mode) {
    'nc'  { $set[3] = 0x01; $set[4] = 0x00 }
    'amb' { $set[3] = 0x01; $set[4] = 0x01 }
    'off' { $set[3] = 0x00; $set[4] = 0x00 }
  }
  Send-Raw $set
  Add-Log "环境声 → $mode"
}
function Op-Level([int]$level) {
  if (-not $script:asc) { return }
  $p = $script:asc
  $set = New-Object byte[] $p.Length
  for ($i = 0; $i -lt $p.Length; $i++) { $set[$i] = [byte]$p[$i] }
  $set[0] = 0x68
  if ($set[3] -eq 0x00) { $set[3] = 0x01; $set[4] = 0x01 }   # 等级只在环境声模式有意义, 顺带切到环境声
  $set[$set.Length - 1] = [byte]$level
  Send-Raw $set
}
function Op-Focus([bool]$on) {
  if (-not $script:asc) { return }
  $p = $script:asc
  $fi = if ($p[1] -eq 0x17 -and $p.Length -ge 8) { 6 } else { 5 }
  $set = New-Object byte[] $p.Length
  for ($i = 0; $i -lt $p.Length; $i++) { $set[$i] = [byte]$p[$i] }
  $set[0] = 0x68
  $set[$fi] = if ($on) { 0x01 } else { 0x00 }
  Send-Raw $set
}
function Op-S2c([bool]$on) {
  $val = if ($on) { 0x00 } else { 0x01 }
  Send-Raw ([byte[]]@(0xf8, 0x0c, $val, 0x01))
  Add-Log ("智能免摘 → " + $(if ($on) { '开启' } else { '关闭' }))
}

# ---------- 事件处理 ----------
$ctl['BtnReconnect'].Add_Click({
  try { Connect-Bt } catch { Set-Connected $false "连接失败: $($_.Exception.Message)"; Add-Log "连接失败: $($_.Exception.Message)" }
})
$ctl['BtnNC'].Add_Click({ Op-Ambient 'nc' })
$ctl['BtnAMB'].Add_Click({ Op-Ambient 'amb' })
$ctl['BtnOff'].Add_Click({ Op-Ambient 'off' })
$ctl['BtnS2c'].Add_Click({
  if ($script:s2c -eq 0x00) { Op-S2c $false } elseif ($script:s2c -eq 0x01) { Op-S2c $true }
})
$ctl['ChkFocus'].Add_Click({
  $cur = if ($script:asc) { $fi = if ($script:asc[1] -eq 0x17 -and $script:asc.Length -ge 8) { 6 } else { 5 }; $script:asc[$fi] -eq 0x01 } else { $false }
  Op-Focus (-not $cur)
})
# 等级滑条: 拖完才发 (防抖)
$script:levelTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:levelTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:levelTimer.Add_Tick({
  $script:levelTimer.Stop()
  Op-Level ([int]$ctl['AsmSlider'].Value)
})
$ctl['AsmSlider'].Add_ValueChanged({
  $ctl['AsmLabel'].Text = "环境声等级: $([int]$ctl['AsmSlider'].Value)"
  if ($script:suppressSlider) { $script:levelTimer.Stop(); return }
  $script:levelTimer.Stop()
  $script:levelTimer.Start()
})

# UI 刷新定时器: 处理监听线程的事件 + init 重试
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
  # init 重试: 已连接但没收到 init 回包, 每 2.5 秒补发一次 (最多 3 次)
  if ($script:socket -and -not $script:initOk -and $script:initTries -lt 3 -and
      ([DateTime]::UtcNow - $script:lastInitAt).TotalMilliseconds -gt 2500) {
    $script:initTries++
    $script:lastInitAt = [DateTime]::UtcNow
    Add-Log "init 无回包, 重试 ($script:initTries/3)..."
    Send-Raw ([byte[]]@(0x00, 0x00))
  }
  while ($script:queue.Count -gt 0) {
    $ev = $script:queue[0]; try { $script:queue.RemoveAt(0) } catch { break }
    switch ($ev.kind) {
      'init' {
        if (-not $script:initOk) {
          $script:initOk = $true
          Add-Log 'init 回包: v2 协议确认 (WH-1000XM5)'
          foreach ($n in 'BtnNC','BtnAMB','BtnOff','AsmSlider','ChkFocus','BtnS2c') { $ctl[$n].IsEnabled = $true }
          Send-Raw ([byte[]]@(0x66, 0x17))    # GET 环境声控制
          Send-Raw ([byte[]]@(0xf6, 0x0c))    # GET 智能免摘
        }
      }
      's2c' {
        $script:s2c = $ev.state
        if ($ev.state -eq 0x00) {
          $ctl['S2cState'].Text = '状态: 开启 (说话会自动暂停音乐)'
          $ctl['S2cState'].Foreground = Brush '#B45309'
          $ctl['BtnS2c'].Content = '关闭免摘'
        } elseif ($ev.state -eq 0x01) {
          $ctl['S2cState'].Text = '状态: 已关闭'
          $ctl['S2cState'].Foreground = Brush '#15803D'
          $ctl['BtnS2c'].Content = '开启免摘'
        }
      }
      'asc' {
        $script:asc = $ev.payload
        $p = $ev.payload
        $modeTxt = if ($p[3] -eq 0x00) { '关闭' } elseif ($p[4] -eq 0x00) { '降噪' } else { '环境声' }
        $fi = if ($p[1] -eq 0x17 -and $p.Length -ge 8) { 6 } else { 5 }
        $focus = ($p[$fi] -eq 0x01)
        $lv = if ($fi + 1 -lt $p.Length) { [int]$p[$fi + 1] } else { 0 }
        $ctl['AsmLabel'].Text = "环境声等级: $lv"
        $script:suppressSlider = $true
        if ([int]$ctl['AsmSlider'].Value -ne $lv) { $ctl['AsmSlider'].Value = $lv }
        $script:suppressSlider = $false
        $ctl['ChkFocus'].IsChecked = $focus
        foreach ($b in 'BtnNC','BtnAMB','BtnOff') {
          $ctl[$b].Background = Brush '#F0F0F0'; $ctl[$b].Foreground = Brush '#1B1B1B'
        }
        $active = switch ($modeTxt) { '降噪' { 'BtnNC' } '环境声' { 'BtnAMB' } '关闭' { 'BtnOff' } }
        if ($active) { $ctl[$active].Background = Brush '#0067C0'; $ctl[$active].Foreground = Brush 'White' }
        Add-Log "环境声: $modeTxt, 等级 $lv, 关注语音 $(if ($focus) { '开' } else { '关' })"
      }
      'log' { Add-Log $ev.msg }
      'connected' {
        # 连接线程报捷: 存对象、起监听线程、发 init 握手 (发一次, 没回包由本定时器重试)
        $script:socket = $ev.socket; $script:writer = $ev.writer; $script:reader = $ev.reader
        $script:seq = 0
        $script:listener = [runspacefactory]::CreateRunspace()
        $script:listener.Open()
        $script:listenerPs = [powershell]::Create()
        $script:listenerPs.Runspace = $script:listener
        [void]$script:listenerPs.AddScript($listenerScript).AddArgument($script:reader).AddArgument($script:writer).AddArgument($script:queue).AddArgument($script:flags).AddArgument($dllFile).AddArgument($script:txQueue)
        [void]$script:listenerPs.BeginInvoke()
        Set-Connected $true "已连接 $($ev.name)"
        Add-Log 'RFCOMM 已连接, 发送 init 握手...'
        $script:initOk = $false
        $script:initTries = 1
        $script:lastInitAt = [DateTime]::UtcNow
        Send-Raw ([byte[]]@(0x00, 0x00))
      }
      'connectfail' {
        Add-Log "连接失败: $($ev.msg)"
        Disconnect-Bt
        Set-Connected $false "连接失败: $($ev.msg)"
      }
      'sendfail' {
        Add-Log "发送失败: $($ev.msg) —— 按断开处理"
        Disconnect-Bt
        Set-Connected $false '连接已断开 (点重连)'
      }
      'closed' {
        Add-Log "耳机连接断开 ($($ev.msg))"
        Disconnect-Bt
        Set-Connected $false '耳机已断开 (点重连)'
      }
    }
  }
})

$win.Add_Closing({ Disconnect-Bt })
$win.Add_Loaded({ try { Connect-Bt } catch { Set-Connected $false "连接失败: $($_.Exception.Message)"; Add-Log "自动连接失败: $($_.Exception.Message)" } })
Set-Connected $false '未连接'
Add-Log '控制台就绪, 正在自动连接 XM5...'
$timer.Start()
[void]$win.ShowDialog()
