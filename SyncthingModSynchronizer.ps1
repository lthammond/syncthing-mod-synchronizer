# ===================== Assemblies =====================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ===================== DPI AWARENESS =====================
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(int value);
}
"@
# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4) — sharpest on all monitors
[DpiHelper]::SetProcessDpiAwarenessContext(-4) | Out-Null

# ===================== Games =====================
$commonIgnores = @(
  # Core
  "(?i)*.exe",
  "(?i)*.dmp",
  "(?i)*.log",
  
  # Unity
  "(?i)*_Data/", # Folder contents
  "(?i)*_Data",  # Folder itself
  "MonoBleedingEdge/",
  "MonoBleedingEdge",
  "UnityCrashHandler64.exe",
  "UnityPlayer.dll",
  "NVUnityPlugin.dll",
  "nvngx_dlss.dll",
  "version.txt"
)

$games = @(
  @{
    Name = "PEAK"
    IgnoreTemplate = $commonIgnores + @(
      "D3D12/",
      "D3D12"
    )
  }, 
  @{
    Name = "Lethal Company"
    IgnoreTemplate = $commonIgnores + @(

    )
  }
  @{
    Name = "STRAFTAT"
    IgnoreTemplate = $commonIgnores + @(

    )
  }
)

# ===================== CONFIG =====================
$ErrorActionPreference = 'Stop'
$RemoteDeviceID   = 'IDIB5I7-HB4DODS-R3PMSZP-QNQLNAJ-E76GH6K-5FWFROC-VXJ2BOZ-J3ZIIAQ'
$RemoteDeviceName = 'Server'
$RemoteAddresses  = @('dynamic')
$script:AppVersion = '1.0.0'
$script:RepoSlug   = 'lthammond/syncthing-mod-synchronizer'

# ===================== CORE FINDERS =====================
function Get-DriveRoots {
  (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Sort-Object -Unique
}

function Get-SteamAppsRoots {
  $roots = @()
  foreach ($rk in @(
    "HKCU:\Software\Valve\Steam",
    "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
    "HKLM:\SOFTWARE\Valve\Steam"
  )) {
    try {
      $ip = (Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue).InstallPath
      if ($ip) {
        $sa = Join-Path $ip "steamapps"
        if (Test-Path -LiteralPath $sa -PathType Container) { $roots += $sa }
      }
    } catch { }
  }
  foreach ($drv in (Get-DriveRoots)) {
    foreach ($rel in @(
      "Steam\steamapps",
      "Program Files (x86)\Steam\steamapps",
      "Program Files\Steam\steamapps",
      "SteamLibrary\steamapps"
    )) {
      $p = Join-Path $drv $rel
      if (Test-Path -LiteralPath $p -PathType Container) { $roots += $p }
    }
  }
  $roots | Sort-Object -Unique
}

function Get-SteamGamePathsByName {
  param([Parameter(Mandatory=$true)] [string]$NameLike)
  $hits = @()
  foreach ($sa in (Get-SteamAppsRoots)) {
    Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $txt = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
        $mName = ([regex]::Match($txt,'(?m)^\s*"name"\s*"(.+?)"')).Groups[1].Value
        $mDir  = ([regex]::Match($txt,'(?m)^\s*"installdir"\s*"(.+?)"')).Groups[1].Value
        if ($mDir) {
          if ($mDir -like "*$NameLike*" -or ($mName -and $mName -like "*$NameLike*")) {
            $common = Join-Path $sa 'common'
            $full   = Join-Path $common $mDir
            if (Test-Path -LiteralPath $full -PathType Container) { $hits += $full }
          }
        }
      } catch { }
    }
    $common2 = Join-Path $sa 'common'
    if (Test-Path -LiteralPath $common2 -PathType Container) {
      Get-ChildItem -LiteralPath $common2 -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$NameLike*" } |
        ForEach-Object { $hits += $_.FullName }
    }
  }
  $hits |
    Where-Object { $_ -and ($_ -match '^[A-Za-z]:\\.+') -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Sort-Object -Unique
}

# ===================== SYNCTHING INSTALLER + REST HELPERS =====================
$script:SyncthingApiInfo   = $null
$script:SyncthingInstalled = $false
$script:SyncthingRunning   = $false
$script:SyncthingPath      = $null

function Find-Syncthing {
  $cmd = Get-Command syncthing.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\Syncthing\syncthing.exe",
    "$env:ProgramFiles\Syncthing\syncthing.exe"
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  return $null
}

function Get-LatestSWSAsset {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $api = 'https://api.github.com/repos/Bill-Stewart/SyncthingWindowsSetup/releases/latest'
  $rel = Invoke-RestMethod -Uri $api -UseBasicParsing
  $asset = $rel.assets | Where-Object { $_.name -match '^syncthing-windows-setup.*\.exe$' } | Select-Object -First 1
  if (-not $asset) { throw "Could not locate syncthing-windows-setup*.exe in latest release." }
  [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url }
}

function Download-File {
  param([Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile)
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  try { Unblock-File -LiteralPath $OutFile } catch {}
  if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download failed: $OutFile not found." }
}

function Run-SWSInstaller {
  param([Parameter(Mandatory)][string]$InstallerPath)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $InstallerPath
  $psi.Arguments = '/currentuser /silent'
  $psi.UseShellExecute = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  if ($p) { $p.WaitForExit() }
  $p.ExitCode
}

function Get-SyncthingConfigPath {
  $candidates = @(
    "$env:LOCALAPPDATA\Syncthing\config.xml",
    "$env:ProgramData\Syncthing\config.xml"
  )
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  throw "Syncthing config.xml not found yet."
}

function Get-SyncthingApiInfo {
  if ($script:SyncthingApiInfo) { return $script:SyncthingApiInfo }

  $cfgPath = Get-SyncthingConfigPath
  [xml]$x = Get-Content -LiteralPath $cfgPath -Raw
  $apiKey = $x.configuration.gui.apikey
  if (-not $apiKey) { throw "Syncthing API key missing in config.xml." }

  $addr = $x.configuration.gui.address
  if (-not $addr) { $addr = '127.0.0.1:8384' }
  $scheme = if ($x.configuration.gui.tls -eq 'true') { 'https' } else { 'http' }

  $base = "${scheme}://$addr"
  $base = $base -replace '://0\.0\.0\.0:', '://127.0.0.1:' -replace '://\[::\]:', '://127.0.0.1:'

  $script:SyncthingApiInfo = @{
    BaseUrl = $base.TrimEnd('/')
    ApiKey  = $apiKey
  }
  return $script:SyncthingApiInfo
}

function Invoke-ST {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [object]$Body
  )
  $info = Get-SyncthingApiInfo
  $uri  = ($info.BaseUrl + $Path)
  $h    = @{ 'X-API-Key' = $info.ApiKey }
  if ($PSBoundParameters.ContainsKey('Body')) {
    $json = ($Body | ConvertTo-Json -Depth 16)
    Invoke-RestMethod -Method $Method -Uri $uri -Headers $h -ContentType 'application/json' -Body $json
  } else {
    Invoke-RestMethod -Method $Method -Uri $uri -Headers $h
  }
}

function Wait-SyncthingReady {
  param([int]$TimeoutSec = 60)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $pong = Invoke-ST -Method GET -Path "/rest/system/ping"
      if ($pong -and $pong.ping -eq 'pong') { return $true }
    } catch { }

    # Keep UI responsive while we wait
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }

    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Start-SyncthingIfNeeded {
  try { if (Wait-SyncthingReady -TimeoutSec 1) { return } } catch {}
  $exe = Find-Syncthing
  if ($exe) { Start-Process -FilePath $exe -ArgumentList "-no-console -no-browser" -WindowStyle Hidden | Out-Null }
}

# ---- Device add (local only) WITHOUT auto-accept ----
function Ensure-Device {
  param(
    [Parameter(Mandatory)][string]$DeviceID,
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Addresses = @('dynamic')
  )
  if ([string]::IsNullOrWhiteSpace($DeviceID)) { return }
  $existing = $null
  try { $existing = Invoke-ST -Method GET -Path "/rest/config/devices/$DeviceID" } catch {}
  $body = @{
    deviceID          = $DeviceID
    name              = $Name
    addresses         = $Addresses
    autoAcceptFolders = $false
  }
  if ($existing) {
    Invoke-ST -Method PATCH -Path "/rest/config/devices/$DeviceID" -Body $body | Out-Null
  } else {
    Invoke-ST -Method POST -Path "/rest/config/devices" -Body $body | Out-Null
  }
}

# ---- Pause/Unpause helpers ----
function Pause-Folder   { param([Parameter(Mandatory)][string]$FolderID) try { Invoke-ST -Method PATCH -Path "/rest/config/folders/$FolderID" -Body @{ paused = $true }  | Out-Null } catch {} }
function Unpause-Folder { param([Parameter(Mandatory)][string]$FolderID) try { Invoke-ST -Method PATCH -Path "/rest/config/folders/$FolderID" -Body @{ paused = $false } | Out-Null } catch {} }

# ---- Folder helpers ----
function Get-AllFolders { Invoke-ST -Method GET -Path "/rest/config/folders" }

function Get-GameFolderLabel {
  param([Parameter(Mandatory)][string]$GameName)
  "$GameName | Mods"
}

function Find-ExistingFolderIdForGame {
  param([Parameter(Mandatory)][string]$GameName)
  $labelWanted = Get-GameFolderLabel -GameName $GameName
  $all = Get-AllFolders
  if (-not $all) { return $null }
  $folder = $all |
    Where-Object { $_.label -and ($_.label -ieq $labelWanted) } |
    Select-Object -First 1
  if ($folder) { return $folder.id }
  return $null
}

function Assign-Path-ToExistingFolder {
  param(
    [Parameter(Mandatory)][string]$FolderID,
    [Parameter(Mandatory)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Folder path does not exist: $Path"
  }
  $f = Invoke-ST -Method GET -Path "/rest/config/folders/$FolderID"
  if (-not $f) { throw "Folder '$FolderID' not found in local config." }
  Pause-Folder -FolderID $FolderID
  $f.path = $Path
  $f.type = 'receiveonly'
  Invoke-ST -Method PUT -Path "/rest/config/folders/$FolderID" -Body $f | Out-Null
}

function Set-FolderIgnores {
  param(
    [Parameter(Mandatory)][string]$FolderID,
    [string[]]$Lines
  )
  # Syncthing expects: POST /rest/db/ignores?folder=<id> with body { "ignore": [ ... ] }
  $path = "/rest/db/ignores?folder={0}" -f [Uri]::EscapeDataString($FolderID)
  $body = @{ ignore = $Lines }
  Invoke-ST -Method POST -Path $path -Body $body | Out-Null
}

function Ensure-FolderMarker {
  param([Parameter(Mandatory)][string]$FolderID)
  $f = Invoke-ST -Method GET -Path "/rest/config/folders/$FolderID"
  if (-not $f) { throw "Folder '$FolderID' not found when ensuring marker." }
  $targetPath = $f.path
  if (-not $targetPath -or -not (Test-Path -LiteralPath $targetPath -PathType Container)) {
    throw "Syncthing's configured path for '$FolderID' is invalid or not present: $targetPath"
  }
  $marker = $f.folderMarker
  if (-not $marker) { $marker = $f.markerName }
  if (-not $marker) { $marker = ".stfolder" }
  $markerPath = Join-Path $targetPath $marker
  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path -LiteralPath $markerPath -PathType Container)) {
    New-Item -ItemType Directory -Path $markerPath -Force | Out-Null
  }
}

function Trigger-Rescan {
  param([Parameter(Mandatory)][string]$FolderID)
  Invoke-ST -Method POST -Path ("/rest/db/scan?folder={0}" -f [Uri]::EscapeDataString($FolderID)) | Out-Null
}

# ---- Accept a pending folder offer (label-based) ----
function Accept-PendingFolderForGame {
  param(
    [Parameter(Mandatory)][string]$GameName,
    [Parameter(Mandatory)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Folder path does not exist: $Path"
  }

  $labelWanted = Get-GameFolderLabel -GameName $GameName
  $pending = Invoke-ST -Method GET -Path "/rest/cluster/pending/folders"

  $folderId   = $null
  $offerDevId = $null

  # Case 1: array of pending entries
  if ($pending -is [System.Collections.IEnumerable] -and $pending.GetType().IsArray) {
    $hit = $pending |
      Where-Object { $_.label -and ($_.label -ieq $labelWanted) } |
      Select-Object -First 1
    if ($hit) {
      $folderId   = $hit.id
      $offerDevId = [string](( $hit.devices | Select-Object -First 1 ).deviceID)
    }
  } else {
    # Case 2: PSCustomObject with properties keyed by folder ID
    foreach ($kv in $pending.PSObject.Properties) {
      $fid = $kv.Name
      $val = $kv.Value
      if ($val -and $val.offeredBy) {
        foreach ($devProp in $val.offeredBy.PSObject.Properties) {
          $off = $devProp.Value
          $lbl = $off.label
          if ($lbl -and ($lbl -ieq $labelWanted)) {
            $folderId   = $fid
            $offerDevId = [string]$devProp.Name
            break
          }
        }
      }
      if ($folderId) { break }
    }
  }

  if (-not $folderId -or -not $offerDevId) {
    throw "Could not find a pending folder offer for label '$labelWanted'. Ensure the server has shared it to this device."
  }

  $body = @{
    id      = $folderId
    label   = $labelWanted
    path    = $Path
    type    = 'receiveonly'
    devices = @(@{ deviceID = $offerDevId })
    paused  = $true
  }

  Invoke-ST -Method POST -Path "/rest/config/folders" -Body $body | Out-Null
  return $folderId
}

# Optional: after installing, add the remote device (no auto-accept)
function AutoWire-RemoteDevice {
  Start-SyncthingIfNeeded
  if (-not (Wait-SyncthingReady -TimeoutSec 90)) { throw "Syncthing API did not come up in time." }
  if ([string]::IsNullOrWhiteSpace($RemoteDeviceID)) { return }
  Ensure-Device -DeviceID $RemoteDeviceID -Name $RemoteDeviceName -Addresses $RemoteAddresses
}

function Invoke-UpdateCheck {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel    = Invoke-RestMethod "https://api.github.com/repos/$script:RepoSlug/releases/latest" -UseBasicParsing
    $latest = $rel.tag_name -replace '^v', ''
    if ([version]$latest -le [version]$script:AppVersion) { return }

    $asset = $rel.assets | Where-Object { $_.name -eq 'SyncthingModSynchronizer.exe' } | Select-Object -First 1
    if (-not $asset) { return }

    if ($null -ne $output) { $output.Text = "Updating to v$latest, please wait..."; [System.Windows.Forms.Application]::DoEvents() }

    $newExe  = "$env:TEMP\SyncthingModSynchronizer_update.exe"
    $selfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $newExe -UseBasicParsing

    # Write a small updater script that waits for this process to exit, swaps the file, relaunches
    $updater = "$env:TEMP\SyncthingModSynchronizer_updater.ps1"
    @"
Start-Sleep -Seconds 2
Copy-Item -LiteralPath '$newExe' -Destination '$selfPath' -Force
Start-Process -FilePath '$selfPath'
"@ | Set-Content -LiteralPath $updater -Encoding UTF8

    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updater`""
    [System.Windows.Forms.Application]::Exit()
  } catch {}
}

function Refresh-SyncthingStatus {
  $script:SyncthingInstalled = $false
  $script:SyncthingRunning   = $false
  $script:SyncthingPath      = $null

  $exe = Find-Syncthing
  if ($exe) {
    $script:SyncthingInstalled = $true
    $script:SyncthingPath      = $exe
    try {
      if (Wait-SyncthingReady -TimeoutSec 1) {
        $script:SyncthingRunning = $true
      }
    } catch {
      $script:SyncthingRunning = $false
    }
  }

  # Grey out / enable Open Web UI depending on install status
  if ($webUIButton -ne $null) {
    $webUIButton.Enabled = $script:SyncthingInstalled
  }

  # Initial text in the output box
  if ($output -ne $null) {
    $statusLines = @()
    if ($script:SyncthingInstalled) {
      $statusLines += "Syncthing: Installed ($script:SyncthingPath)"
      if ($script:SyncthingRunning) {
        $statusLines += "Syncthing status: Running (API responding)"
      } else {
        $statusLines += "Syncthing status: Installed but API not responding"
      }
    } else {
      $statusLines += "Syncthing: Not installed."
    }
    $statusLines += ""
    $statusLines += "=================================="
    $statusLines += "Click a game's button to automatically find the path and prepare the .stignore file."
    $output.Text = ($statusLines -join "`r`n")
  }
}

function Ensure-SyncthingInstalledInteractive {
  try {
    # Initial status refresh
    Refresh-SyncthingStatus
    if ($script:SyncthingInstalled) {
      try { AutoWire-RemoteDevice } catch {}
      # Status may change (running) after AutoWire
      Refresh-SyncthingStatus
      return
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
      "Syncthing does not appear to be installed for this user." + "`r`n`r`n" +
      "Would you like to download and install Syncthing now?",
      "Syncthing Required",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
      # User declined; just reflect that in status
      Refresh-SyncthingStatus
      return
    }

    $asset = Get-LatestSWSAsset
    $dest  = Join-Path $env:TEMP $asset.Name
    Download-File -Url $asset.Url -OutFile $dest

    $code = Run-SWSInstaller -InstallerPath $dest
    if ($code -eq 0) {
      try {
        AutoWire-RemoteDevice
        [System.Windows.Forms.MessageBox]::Show(
          "Syncthing installed successfully and the remote device was added." + "`r`n`r`n" +
          "You can now have the server share the Mods folder and use 'Sync Mods' to accept it.",
          "Synching Installed",
          'OK',
          [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
      } catch {
        [System.Windows.Forms.MessageBox]::Show(
          "Syncthing was installed, but wiring the remote device failed:" + "`r`n" +
          $_.Exception.Message,
          "Syncthing Installed",
          'OK',
          [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
      }
    } else {
      [System.Windows.Forms.MessageBox]::Show(
        "Syncthing installer exited with code $code.",
        "Syncthing Install",
        'OK',
        [System.Windows.Forms.MessageBoxIcon]::Warning
      ) | Out-Null
    }

    # Final status refresh after install attempt
    Refresh-SyncthingStatus
  }
  catch {
    [System.Windows.Forms.MessageBox]::Show(
      "Could not install Syncthing:" + "`r`n" + $_.Exception.Message,
      "Syncthing Install Error",
      'OK',
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    Refresh-SyncthingStatus
  }
}

# ===================== UI HELPERS =====================
function Is-DriveRoot {
  param([string]$Path)
  if (-not $Path) { return $false }
  if ($Path -match '^[A-Za-z]:\\?$') { return $true }
  if ($Path -match '^\\\\[^\\]+\\[^\\]+\\?$') { return $true }
  return $false
}

function Pick-FolderGUI {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = "Select the game's root folder"
  $dlg.ShowNewFolderButton = $false
  if ($dlg.ShowDialog($global:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) {
    if (Is-DriveRoot $dlg.SelectedPath) {
      [System.Windows.Forms.MessageBox]::Show(
        "Please select the actual game folder, not the drive root:`r`n$($dlg.SelectedPath)",
        "Invalid Path","OK","Warning"
      ) | Out-Null
      return $null
    }
    return $dlg.SelectedPath
  }
  return $null
}

# ===================== MAIN UI =====================
$global:MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "Syncthing Mod Synchronizer"
$MainForm.Width = 800
$MainForm.Height = 520
$MainForm.MinimumSize = New-Object System.Drawing.Size(500, 320)
$MainForm.StartPosition = "CenterScreen"
$MainForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = [System.Windows.Forms.DockStyle]::Fill
$split.Orientation = [System.Windows.Forms.Orientation]::Vertical
$split.FixedPanel   = [System.Windows.Forms.FixedPanel]::Panel1
$split.IsSplitterFixed = $false
$split.SplitterWidth = 6
$split.Panel1MinSize = 240
[void]$MainForm.Controls.Add($split)

# Left: container (label on top, buttons fill the rest)
$leftContainer = New-Object System.Windows.Forms.Panel
$leftContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
[void]$split.Panel1.Controls.Add($leftContainer)

$leftPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$leftPanel.WrapContents = $true
$leftPanel.AutoScroll = $false
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$leftContainer.Controls.Add($leftPanel)

$step1Label = New-Object System.Windows.Forms.Label
$step1Label.Text = "Step 1: Select your game."
$step1Label.AutoSize = $true
$step1Label.Dock = [System.Windows.Forms.DockStyle]::Top
$step1Label.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
[void]$leftContainer.Controls.Add($step1Label)

# Right: results area (label + textbox)
$right = New-Object System.Windows.Forms.TableLayoutPanel
$right.Dock = [System.Windows.Forms.DockStyle]::Fill
$right.ColumnCount = 2
$right.RowCount = 3
[void]$right.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$right.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$right.RowStyles.Add(  (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$right.RowStyles.Add(  (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$right.RowStyles.Add(  (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$split.Panel2.Controls.Add($right)

$label = New-Object System.Windows.Forms.Label
$label.AutoSize = $true
$label.Text = "Step 2: Review the path below, then click 'Sync Mods'."
$label.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
[void]$right.Controls.Add($label, 0, 0)

$output = New-Object System.Windows.Forms.TextBox
$output.Multiline = $true
$output.ReadOnly  = $true
$output.ScrollBars = "Vertical"
$output.Dock = [System.Windows.Forms.DockStyle]::Fill
$output.Text = ""  # Filled by Refresh-SyncthingStatus
[void]$right.SetColumnSpan($output, 2)
[void]$right.Controls.Add($output, 0, 1)

# ===================== SINGLE BOTTOM BAR =====================
$leftMargin   = 16
$rightMargin  = 12
$buttonWidth  = 120
$buttonSpacing = 8
$barHeight    = 38

$bottomBar = New-Object System.Windows.Forms.Panel
$bottomBar.Dock   = [System.Windows.Forms.DockStyle]::Bottom
$bottomBar.Height = $barHeight
[void]$MainForm.Controls.Add($bottomBar)

# Set Up Sync (left)
$writeBtn = New-Object System.Windows.Forms.Button
$writeBtn.Text = "Set Up Sync"
$writeBtn.Width = $buttonWidth
$writeBtn.Height = 30
$writeBtn.Top = 2
$writeBtn.Anchor = "Top,Left"
[void]$bottomBar.Controls.Add($writeBtn)

# Path textbox (middle, stretches)
$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.ReadOnly = $true
$pathBox.Top = 4
$pathBox.Anchor = "Top,Left,Right"
[void]$bottomBar.Controls.Add($pathBox)

# Browse button (right side, left of Open Web UI)
$browseBtn = New-Object System.Windows.Forms.Button
$browseBtn.Text = "Browse"
$browseBtn.Width = $buttonWidth
$browseBtn.Height = 30
$browseBtn.Top = 2
$browseBtn.Anchor = "Top,Right"
$browseBtn.Enabled = $false
[void]$bottomBar.Controls.Add($browseBtn)

# Open Web UI button (rightmost)
$webUIButton = New-Object System.Windows.Forms.Button
$webUIButton.Text = "Open Web UI"
$webUIButton.Width = $buttonWidth
$webUIButton.Height = 30
$webUIButton.Top = 2
$webUIButton.Anchor = "Top,Right"
$webUIButton.Enabled = $false  # Enabled when Syncthing is installed
[void]$bottomBar.Controls.Add($webUIButton)

# --- Resize handler for bottom bar ---
$resizeBars = {
  & {
    $availW = $MainForm.ClientSize.Width
    $buttonWidth = 120
    $buttonSpacing = 8
    $leftMargin = 16
    $rightMargin = 12

    # Right side: Web UI (rightmost), Browse left of it
    $webuiLeft   = $availW - $rightMargin - $buttonWidth
    $browseLeft  = $webuiLeft - $buttonSpacing - $buttonWidth

    $webUIButton.Left = $webuiLeft
    $browseBtn.Left   = $browseLeft

    # Left: Write button
    $writeBtn.Left = $leftMargin

    # Path textbox between Write and Browse
    $pathLeft  = $leftMargin + $buttonWidth + $buttonSpacing
    $pathRight = $browseLeft - $buttonSpacing
    $pathWidth = [Math]::Max(80, $pathRight - $pathLeft)

    $pathBox.Left  = $pathLeft
    $pathBox.Width = $pathWidth
  } | Out-Null
  return
}
[void]$MainForm.Add_Resize($resizeBars)
[void]$MainForm.Add_Shown($resizeBars)

# ===================== BUTTON HANDLERS =====================
$browseBtn.Add_Click({
  try {
    $picked = Pick-FolderGUI
    if ($picked) { $null = ($pathBox.Text = $picked) }
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Browse Error",'OK','Error') | Out-Null
  }
})

$webUIButton.Add_Click({
  try { Start-Process "http://localhost:8384/" } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Open Web UI",'OK','Error') | Out-Null
  }
})

$writeBtn.Add_Click({
  # --- UI: show busy state and disable bottom buttons ---
  $prevCursor           = $MainForm.UseWaitCursor
  $prevWriteEnabled     = $writeBtn.Enabled
  $prevBrowseEnabled    = $browseBtn.Enabled
  $prevWebUIEnabled     = $webUIButton.Enabled

  $MainForm.UseWaitCursor = $true
  $writeBtn.Enabled       = $false
  $browseBtn.Enabled      = $false
  $webUIButton.Enabled    = $false

  try {
    $dir = $pathBox.Text
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
      [System.Windows.Forms.MessageBox]::Show("No valid directory selected.","Write .stignore",'OK','Warning') | Out-Null
      return
    }

    # Determine game
    $game = $script:CurrentGame
    if (-not $game) {
      foreach ($g in $games) {
        if ($dir -like "*$($g.Name)*") { $game = $g; break }
      }
    }
    if (-not $game) {
      [System.Windows.Forms.MessageBox]::Show("Could not infer the game for this path. Click a game button first.","Write .stignore",'OK','Warning') | Out-Null
      return
    }

    # Progress feedback
    $output.Text = "Setting up sync for '$($game.Name)', please wait..."
    [System.Windows.Forms.Application]::DoEvents()

    # 1) Write .stignore locally
    if (-not $game.IgnoreTemplate) {
      [System.Windows.Forms.MessageBox]::Show("No .stignore template found for '$($game.Name)'.","Write .stignore",'OK','Warning') | Out-Null
      return
    }
    $stignorePath = Join-Path $dir ".stignore"
    $content = $game.IgnoreTemplate -join "`r`n"
    Set-Content -LiteralPath $stignorePath -Value $content -Encoding UTF8

    # 2) Wire Syncthing folder: assign existing or accept pending
    Start-SyncthingIfNeeded

    # Shorter wait here (30s) to avoid feeling hung forever
    if (-not (Wait-SyncthingReady -TimeoutSec 30)) {
      throw "Syncthing API did not come up in time (30s). Make sure Syncthing is running and try again."
    }

    $labelWanted = Get-GameFolderLabel -GameName $game.Name
    $folderId    = Find-ExistingFolderIdForGame -GameName $game.Name

    if ($folderId) {
      Assign-Path-ToExistingFolder -FolderID $folderId -Path $dir
      Ensure-FolderMarker -FolderID $folderId
      Set-FolderIgnores  -FolderID $folderId -Lines $game.IgnoreTemplate
      Unpause-Folder     -FolderID $folderId
      Trigger-Rescan     -FolderID $folderId
    } else {
      $folderId = Accept-PendingFolderForGame -GameName $game.Name -Path $dir
      if (-not $folderId) {
        throw "Could not find a pending folder offer for '$labelWanted'. Ensure the server has shared it to this device."
      }
      Ensure-FolderMarker -FolderID $folderId
      Set-FolderIgnores  -FolderID $folderId -Lines $game.IgnoreTemplate
      Unpause-Folder     -FolderID $folderId
      Trigger-Rescan     -FolderID $folderId
    }

    $verify = Invoke-ST -Method GET -Path "/rest/config/folders/$folderId"
    $actualPath = $verify.path
    [System.Windows.Forms.MessageBox]::Show("Done!") | Out-Null

    # Refresh status after wiring (Syncthing now almost certainly running)
    Refresh-SyncthingStatus
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Write .stignore",'OK','Error') | Out-Null
    Refresh-SyncthingStatus
  } finally {
    # --- UI: restore previous state ---
    $MainForm.UseWaitCursor = $prevCursor
    $writeBtn.Enabled       = $prevWriteEnabled
    $browseBtn.Enabled      = $prevBrowseEnabled
    $webUIButton.Enabled    = $prevWebUIEnabled -and $script:SyncthingInstalled
  }
})

# ===================== OTHER UI TWEAKS =====================
[void]$MainForm.Add_Shown({
  & {
    $desiredLeft = 240
    $minRight    = 360
    $clientW = $split.ClientSize.Width
    if ($clientW -gt 0) {
      $maxLeft = [Math]::Max(0, $clientW - $minRight)
      $left = [Math]::Min($desiredLeft, $maxLeft)
      if ($left -lt $split.Panel1MinSize) { $left = $split.Panel1MinSize }
      $null = ($split.SplitterDistance = [int]$left)
    }
  } | Out-Null
  return
})

[void]$MainForm.Add_Shown({
  Invoke-UpdateCheck
  Ensure-SyncthingInstalledInteractive
})

# Track the last-clicked game for Set Up Sync
$script:CurrentGame = $null

# -------------------- BUTTONS PER GAME --------------------
foreach ($g in $games) {
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $g.Name
  $btn.Height = 36
  $btn.Margin = New-Object System.Windows.Forms.Padding(6)
  $btn.Anchor = "Top, Left, Right"
  $btn.MinimumSize = New-Object System.Drawing.Size(80, 36)
  $btn.MaximumSize = New-Object System.Drawing.Size(10000, 36)
  $btn.AutoSize = $false
  $btn.Width = $leftPanel.ClientSize.Width - 20
  $btn.Tag = $g
  [void]$leftPanel.Controls.Add($btn)

  [void]$btn.Add_Click({
    param($sender, $e)
    try {
      $pathBox.Text = ""
      $browseBtn.Enabled = $false

      $game = [hashtable]$sender.Tag
      $script:CurrentGame = $game

      $found = Get-SteamGamePathsByName -NameLike $game.Name

      $chosen = $null
      if ($found -and $found.Count -gt 0) {
        $exact = $found | Where-Object { (Split-Path -Leaf $_) -ieq $game.Name } | Select-Object -First 1
        if ($exact) {
          $chosen = $exact
        } else {
          $chosen = $found[0]
        }
      }

      $lines = @()

      # Always start with current Syncthing status summary
      if ($script:SyncthingInstalled) {
        $lines += "Syncthing: Installed ($script:SyncthingPath)"
        if ($script:SyncthingRunning) {
          $lines += "Syncthing status: Running (API responding)"
        } else {
          $lines += "Syncthing status: Installed but API not responding"
        }
      } else {
        $lines += "Syncthing: Not installed."
      }
      $lines += ""
      $lines += "=================================="

      if ($chosen) {
        $pathBox.Text = $chosen
        $lines += "Path was automatically found at:"
        $lines += $chosen
        $lines += ""

        $alt = $found | Where-Object { $_ -ne $chosen }
        if ($alt -and $alt.Count -gt 0) {
          $lines += "Other candidates found:"
          $lines += $alt
          $lines += ""
        }

        $lines += "Now, just click 'Write .stignore'. Once finished, a pop-up will confirm successful setup."
        $lines += ""
        $lines += "You may click 'Open Web UI' if you wish to verify setup in Syncthing."
        $lines += ""

      } else {
        $browseBtn.Enabled = $true
        $lines += "Path to '$($game.Name)' could not be automatically determined."
        $lines += "Click 'Browse' to select the folder manually."
        $lines += ""
      }

      if ($game.IgnoreTemplate) {
        $lines += "=================================="
        $lines += "Files ignored for '$($game.Name)':"
        $lines += ($game.IgnoreTemplate -join "`r`n")
      } else {
        $lines += "No .stignore template found for '$($game.Name)'."
      }

      $output.Text = ($lines -join "`r`n")
    }
    catch {
      $output.Text = "ERROR: $($_.Exception.Message)"
      $pathBox.Text = ""
      $browseBtn.Enabled = $true
    }
    return
  })
}

if (-not $MainForm.IsDisposed) {
  [void][System.Windows.Forms.Application]::Run($MainForm)
}
