#requires -Version 5.1
<#
.SYNOPSIS
    SetupHub - a single-file Windows app installer and WinGet updater.
.DESCRIPTION
    Built with Windows PowerShell/WPF and the built-in WinGet client. No modules or
    third-party PowerShell packages are required. Custom EXE/MSI/MSIX installers are
    user-supplied and must be trusted. The script does not disable or bypass Defender.
#>

if ($env:OS -ne 'Windows_NT') {
    throw 'SetupHub works on Windows only.'
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
} catch {
    throw "Windows Presentation Foundation (WPF) could not be loaded. Run this on Windows with Windows PowerShell 5.1 or PowerShell 7 for Windows. Details: $($_.Exception.Message)"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$script:AppName = 'SetupHub'
$script:DataRoot = Join-Path $env:LOCALAPPDATA 'SetupHub'
$script:CustomCatalogPath = Join-Path $script:DataRoot 'custom-apps.json'
$script:LogPath = Join-Path $script:DataRoot 'setup.log'
$script:WingetPath = $null
$script:IsBusy = $false
$script:ActiveWorker = $null
$script:UpgradeItems = @()
$script:AppItems = New-Object System.Collections.ArrayList
$script:BusyControls = @()
$script:Window = $null
$script:StatusLabel = $null
$script:ProgressBar = $null
$script:AppListPanel = $null
$script:UpdateListPanel = $null
$script:SearchBox = $null
$script:WingetStatusText = $null

New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null

function Write-SetupLog {
    param([string]$Message)
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

function New-UiBrush {
    param([string]$Color)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Get-IconUrl {
    param([string]$Slug)
    if ([string]::IsNullOrWhiteSpace($Slug)) { return $null }
    # Iconify serves raster PNGs for WPF. A letter fallback is shown if an icon cannot load.
    return "https://api.iconify.design/simple-icons/$Slug.png?color=%23E5E7EB&width=96"
}

# Edit this list to make additional apps part of the public GitHub script for every user.
# Use exact WinGet package IDs; installs are handled by WinGet's package manifest.
$script:BuiltInApps = @(
    [pscustomobject]@{ Name='7-Zip'; Description='File archiver'; Id='7zip.7zip'; IconUrl=(Get-IconUrl '7zip'); Category='Utilities'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Google Chrome'; Description='Web browser'; Id='Google.Chrome'; IconUrl=(Get-IconUrl 'googlechrome'); Category='Browser'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Mozilla Firefox'; Description='Independent web browser'; Id='Mozilla.Firefox'; IconUrl=(Get-IconUrl 'firefoxbrowser'); Category='Browser'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Brave'; Description='Privacy-focused web browser'; Id='Brave.Brave'; IconUrl=(Get-IconUrl 'brave'); Category='Browser'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='VLC media player'; Description='Video and audio player'; Id='VideoLAN.VLC'; IconUrl=(Get-IconUrl 'vlcmediaplayer'); Category='Media'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Visual Studio Code'; Description='Code editor'; Id='Microsoft.VisualStudioCode'; IconUrl=(Get-IconUrl 'visualstudiocode'); Category='Development'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Git'; Description='Version control'; Id='Git.Git'; IconUrl=(Get-IconUrl 'git'); Category='Development'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Notepad++'; Description='Advanced text editor'; Id='Notepad++.Notepad++'; IconUrl=(Get-IconUrl 'notepadplusplus'); Category='Development'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Microsoft PowerToys'; Description='Windows productivity utilities'; Id='Microsoft.PowerToys'; IconUrl=(Get-IconUrl 'microsoftpowertoys'); Category='Utilities'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Everything'; Description='Instant file search'; Id='voidtools.Everything'; IconUrl=(Get-IconUrl 'everything'); Category='Utilities'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='ShareX'; Description='Screenshots and screen recording'; Id='ShareX.ShareX'; IconUrl=(Get-IconUrl 'sharex'); Category='Utilities'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='OBS Studio'; Description='Recording and live streaming'; Id='OBSProject.OBSStudio'; IconUrl=(Get-IconUrl 'obsstudio'); Category='Media'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Spotify'; Description='Music streaming app'; Id='Spotify.Spotify'; IconUrl=(Get-IconUrl 'spotify'); Category='Media'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Discord'; Description='Voice and text chat'; Id='Discord.Discord'; IconUrl=(Get-IconUrl 'discord'); Category='Communication'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Zoom Workplace'; Description='Video meetings'; Id='Zoom.Zoom'; IconUrl=(Get-IconUrl 'zoom'); Category='Communication'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='LibreOffice'; Description='Office productivity suite'; Id='TheDocumentFoundation.LibreOffice'; IconUrl=(Get-IconUrl 'libreoffice'); Category='Productivity'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='SumatraPDF'; Description='Lightweight PDF reader'; Id='SumatraPDF.SumatraPDF'; IconUrl=(Get-IconUrl 'sumatrapdf'); Category='Productivity'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='GIMP'; Description='Image editor'; Id='GIMP.GIMP'; IconUrl=(Get-IconUrl 'gimp'); Category='Creative'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Python 3.13'; Description='Python runtime'; Id='Python.Python.3.13'; IconUrl=(Get-IconUrl 'python'); Category='Development'; Type='Winget'; Selected=$false }
    [pscustomobject]@{ Name='Postman'; Description='API development platform'; Id='Postman.Postman'; IconUrl=(Get-IconUrl 'postman'); Category='Development'; Type='Winget'; Selected=$false }
)

# Add direct-download installers here if you want them in the public GitHub catalog for everyone.
# Use HTTPS URLs. For EXE installers, provide the vendor-documented silent arguments.
$script:BuiltInCustomApps = @(
    # Example schema (uncomment and replace with a real trusted installer):
    # [pscustomobject]@{ Name='Example Custom App'; Description='Custom app from your publisher link'; Type='Custom'; CatalogSource='BuiltIn'; Id=$null; Url='https://downloads.example.com/setup.exe'; PackageType='EXE'; SilentArgs='/S'; IconUrl='https://example.com/logo.png'; Sha256=''; Category='Custom'; Selected=$false }
)

foreach ($item in $script:BuiltInApps) { [void]$script:AppItems.Add($item) }
foreach ($item in $script:BuiltInCustomApps) {
    if (-not $item.PSObject.Properties['CatalogSource']) { $item | Add-Member -NotePropertyName CatalogSource -NotePropertyValue 'BuiltIn' }
    [void]$script:AppItems.Add($item)
}

function Get-WinGetPath {
    $command = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) { return $command.Source }
    $command = Get-Command 'winget' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ([int]$character -eq 92) {
            $backslashes++
            continue
        }
        if ([int]$character -eq 34) {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * (($backslashes * 2) + 1))) }
            else { [void]$builder.Append('\') }
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Command not found: $FilePath"
    }
    $quotedArguments = @($Arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $quotedArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode=[int]$process.ExitCode; StdOut=[string]$stdout; StdErr=[string]$stderr }
    } finally {
        $process.Dispose()
    }
}

function Parse-WinGetUpgradeOutput {
    param([string]$Text)
    $parsed = New-Object System.Collections.ArrayList
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match '^-{3,}$') { continue }
        if ($trimmed -match '^(Name\s+Id\s+Version|No installed package|No applicable upgrade|Found no|Source agreements|The source agreement)') { continue }
        $columns = @($trimmed -split '\s{2,}')
        # WinGet's table separates columns with padded whitespace. Package IDs have no spaces.
        if ($columns.Count -lt 4) { continue }
        $id = [string]$columns[1]
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { continue }
        $name = [string]$columns[0]
        $installed = [string]$columns[2]
        $available = [string]$columns[3]
        $source = if ($columns.Count -ge 5) { [string]$columns[4] } else { 'WinGet' }
        if ($name -and $id -and $installed -and $available) {
            [void]$parsed.Add([pscustomobject]@{
                Name=$name; Id=$id; InstalledVersion=$installed; AvailableVersion=$available
                Source=$source; Type='Winget'; Selected=$false
            })
        }
    }
    return @($parsed.ToArray())
}

function Save-CustomCatalog {
    try {
        $custom = @($script:AppItems | Where-Object { $_.Type -eq 'Custom' -and $_.CatalogSource -eq 'Local' } | ForEach-Object {
            [pscustomobject]@{
                Name=$_.Name; Description=$_.Description; Url=$_.Url; PackageType=$_.PackageType
                SilentArgs=$_.SilentArgs; IconUrl=$_.IconUrl; Sha256=$_.Sha256; Category='Custom'
            }
        })
        ConvertTo-Json -InputObject $custom -Depth 5 | Set-Content -LiteralPath $script:CustomCatalogPath -Encoding UTF8
    } catch {
        Write-SetupLog "Could not save custom catalog: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("The app was added for this session, but the local custom catalog could not be saved.`n$($_.Exception.Message)", 'SetupHub', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
}

function Load-CustomCatalog {
    if (-not (Test-Path -LiteralPath $script:CustomCatalogPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:CustomCatalogPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $savedApps = @(ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
        foreach ($saved in $savedApps) {
            if ([string]::IsNullOrWhiteSpace([string]$saved.Name)) { continue }
            if ([string]$saved.Url -notmatch '^https://') { continue }
            if ([string]$saved.PackageType -notin @('EXE','MSI','MSIX','MSIXBUNDLE')) { continue }
            [void]$script:AppItems.Add([pscustomobject]@{
                Name=[string]$saved.Name; Description=[string]$saved.Description; Type='Custom'; Id=$null
                Url=[string]$saved.Url; PackageType=[string]$saved.PackageType.ToUpperInvariant()
                SilentArgs=[string]$saved.SilentArgs; IconUrl=[string]$saved.IconUrl; Sha256=([string]$saved.Sha256).ToUpperInvariant()
                Category='Custom'; Selected=$false; CatalogSource='Local'
            })
        }
    } catch {
        Write-SetupLog "Could not read custom catalog: $($_.Exception.Message)"
    }
}

function Set-ButtonAppearance {
    param($Button, [string]$Background='#282D36', [string]$Foreground='#F2F4F8', [string]$Border='#3A414D')
    $Button.Background = New-UiBrush $Background
    $Button.Foreground = New-UiBrush $Foreground
    $Button.BorderBrush = New-UiBrush $Border
    $Button.BorderThickness = [System.Windows.Thickness]::new(1)
    $Button.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
    $Button.FontFamily = 'Segoe UI'
    $Button.FontSize = 13
    $Button.Cursor = [System.Windows.Input.Cursors]::Hand
    $Button.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
}

function New-SetupButton {
    param([string]$Text, [string]$Background='#282D36', [string]$Foreground='#F2F4F8', [string]$Border='#3A414D')
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    Set-ButtonAppearance -Button $button -Background $Background -Foreground $Foreground -Border $Border
    return $button
}

function New-TextBlock {
    param([string]$Text, [double]$Size=13, [string]$Color='#E5E7EB', [bool]$Bold=$false)
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontFamily = 'Segoe UI'
    $block.FontSize = $Size
    $block.Foreground = New-UiBrush $Color
    $block.TextWrapping = [System.Windows.TextWrapping]::Wrap
    if ($Bold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    return $block
}

function Add-GridRow {
    param($Grid, [System.Windows.GridLength]$Height)
    $row = New-Object System.Windows.Controls.RowDefinition
    $row.Height = $Height
    [void]$Grid.RowDefinitions.Add($row)
}

function Add-GridColumn {
    param($Grid, [System.Windows.GridLength]$Width)
    $column = New-Object System.Windows.Controls.ColumnDefinition
    $column.Width = $Width
    [void]$Grid.ColumnDefinitions.Add($column)
}

function New-AppCard {
    param($Item, [switch]$IsUpdate)
    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-UiBrush '#181C22'
    $card.BorderBrush = New-UiBrush '#2B313B'
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(9)
    $card.Padding = [System.Windows.Thickness]::new(11, 9, 12, 9)
    $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 7)

    $grid = New-Object System.Windows.Controls.Grid
    Add-GridColumn $grid ([System.Windows.GridLength]::new(28))
    Add-GridColumn $grid ([System.Windows.GridLength]::new(48))
    Add-GridColumn $grid ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))
    Add-GridColumn $grid ([System.Windows.GridLength]::Auto)

    $check = New-Object System.Windows.Controls.CheckBox
    $check.IsChecked = [bool]$Item.Selected
    $check.Tag = $Item
    $check.VerticalAlignment = 'Center'
    $check.HorizontalAlignment = 'Left'
    $check.Margin = [System.Windows.Thickness]::new(1, 0, 7, 0)
    $check.Add_Checked({ $sender = $args[0]; $sender.Tag.Selected = $true })
    $check.Add_Unchecked({ $sender = $args[0]; $sender.Tag.Selected = $false })
    [System.Windows.Controls.Grid]::SetColumn($check, 0)
    [void]$grid.Children.Add($check)

    $iconBox = New-Object System.Windows.Controls.Border
    $iconBox.Width = 38; $iconBox.Height = 38
    $iconBox.Background = New-UiBrush '#252B34'
    $iconBox.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $iconBox.HorizontalAlignment = 'Left'
    $iconBox.VerticalAlignment = 'Center'
    $fallback = New-TextBlock -Text ([string]$Item.Name.Substring(0,1).ToUpperInvariant()) -Size 16 -Color '#DCE3ED' -Bold $true
    $fallback.HorizontalAlignment = 'Center'; $fallback.VerticalAlignment = 'Center'
    $iconGrid = New-Object System.Windows.Controls.Grid
    [void]$iconGrid.Children.Add($fallback)
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.IconUrl) -and [string]$Item.IconUrl -match '^https://') {
        try {
            $image = New-Object System.Windows.Controls.Image
            $image.Width = 30; $image.Height = 30
            $image.Stretch = [System.Windows.Media.Stretch]::Uniform
            $image.HorizontalAlignment = 'Center'; $image.VerticalAlignment = 'Center'
            $image.Add_ImageFailed({ $sender = $args[0]; $sender.Visibility = [System.Windows.Visibility]::Collapsed })
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = [Uri]$Item.IconUrl
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnDemand
            $bitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::DelayCreation
            $bitmap.EndInit()
            $image.Source = $bitmap
            [void]$iconGrid.Children.Add($image)
        } catch { }
    }
    $iconBox.Child = $iconGrid
    [System.Windows.Controls.Grid]::SetColumn($iconBox, 1)
    [void]$grid.Children.Add($iconBox)

    $textStack = New-Object System.Windows.Controls.StackPanel
    $textStack.Orientation = 'Vertical'
    $textStack.VerticalAlignment = 'Center'
    $textStack.Margin = [System.Windows.Thickness]::new(8, 0, 10, 0)
    $nameBlock = New-TextBlock -Text ([string]$Item.Name) -Size 14 -Color '#F1F4F8' -Bold $true
    [void]$textStack.Children.Add($nameBlock)
    if ($IsUpdate) {
        $desc = "Installed: $($Item.InstalledVersion)   •   Available: $($Item.AvailableVersion)   •   $($Item.Source)"
    } else {
        $desc = [string]$Item.Description
        if ([string]::IsNullOrWhiteSpace($desc)) {
            if ($Item.Type -eq 'Custom') { $desc = "Custom $($Item.PackageType) installer" }
            else { $desc = [string]$Item.Category }
        }
    }
    $descBlock = New-TextBlock -Text $desc -Size 11.5 -Color '#9AA4B2'
    $descBlock.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    [void]$textStack.Children.Add($descBlock)
    [System.Windows.Controls.Grid]::SetColumn($textStack, 2)
    [void]$grid.Children.Add($textStack)

    $sourceText = if ($IsUpdate) { [string]$Item.Id } elseif ($Item.Type -eq 'Custom') { 'CUSTOM LINK' } else { 'WINGET' }
    $sourceBlock = New-TextBlock -Text $sourceText -Size 10.5 -Color '#8D98A8' -Bold $true
    $sourceBlock.VerticalAlignment = 'Center'
    $sourceBlock.HorizontalAlignment = 'Right'
    $sourceBlock.Margin = [System.Windows.Thickness]::new(5, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($sourceBlock, 3)
    [void]$grid.Children.Add($sourceBlock)

    $card.Child = $grid
    return $card
}

function Build-AppList {
    if (-not $script:AppListPanel) { return }
    $script:AppListPanel.Children.Clear()
    $query = ''
    if ($script:SearchBox) { $query = [string]$script:SearchBox.Text }
    $matching = @($script:AppItems | Where-Object {
        [string]::IsNullOrWhiteSpace($query) -or
        ([string]$_.Name).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ([string]$_.Description).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ([string]$_.Category).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($matching.Count -eq 0) {
        $empty = New-TextBlock -Text 'No apps match this search.' -Size 13 -Color '#9AA4B2'
        $empty.Margin = [System.Windows.Thickness]::new(4, 18, 0, 0)
        [void]$script:AppListPanel.Children.Add($empty)
        return
    }
    foreach ($item in $matching) { [void]$script:AppListPanel.Children.Add((New-AppCard -Item $item)) }
}

function Build-UpdateList {
    if (-not $script:UpdateListPanel) { return }
    $script:UpdateListPanel.Children.Clear()
    if (-not $script:UpgradeItems -or $script:UpgradeItems.Count -eq 0) {
        $empty = New-TextBlock -Text 'No available updates are listed. Select “Check for updates” to scan again.' -Size 13 -Color '#9AA4B2'
        $empty.Margin = [System.Windows.Thickness]::new(4, 18, 0, 0)
        [void]$script:UpdateListPanel.Children.Add($empty)
        return
    }
    foreach ($item in $script:UpgradeItems) { [void]$script:UpdateListPanel.Children.Add((New-AppCard -Item $item -IsUpdate)) }
}

function Open-WinGetInstallPage {
    $choice = [System.Windows.MessageBox]::Show(
        'WinGet is provided by Microsoft App Installer. SetupHub does not download or sideload package-manager dependencies itself. Open the official Microsoft Store page now?',
        'WinGet is required',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Information
    )
    if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
        try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch {
            Start-Process 'https://aka.ms/getwinget'
        }
    }
}

function Start-AsyncWork {
    param([Parameter(Mandatory=$true)][string]$Mode, [object[]]$Items=@())
    if ($script:IsBusy) { return }

    if ($Mode -in @('CheckUpdates','UpdateSelected') -and -not $script:WingetPath) {
        Open-WinGetInstallPage
        return
    }
    if ($Mode -eq 'InstallSelected') {
        $hasWinget = @($Items | Where-Object { $_.Type -eq 'Winget' }).Count -gt 0
        if ($hasWinget -and -not $script:WingetPath) {
            Open-WinGetInstallPage
            return
        }
    }

    $script:IsBusy = $true
    if ($script:ProgressBar) { $script:ProgressBar.IsIndeterminate = $true; $script:ProgressBar.Visibility = 'Visible' }
    foreach ($control in $script:BusyControls) { $control.IsEnabled = $false }
    if ($script:StatusLabel) { $script:StatusLabel.Text = 'Starting...' }

    $worker = New-Object System.ComponentModel.BackgroundWorker
    $worker.WorkerReportsProgress = $true
    $worker.add_DoWork({
        param($sender, $eventArgs)
        $job = $eventArgs.Argument
        switch ([string]$job.Mode) {
            'CheckUpdates' {
                $sender.ReportProgress(0, 'Checking installed apps for available updates...')
                $scan = Invoke-ExternalCommand -FilePath $script:WingetPath -Arguments @('list','--upgrade-available','--accept-source-agreements','--disable-interactivity')
                $combined = [string]$scan.StdOut + "`r`n" + [string]$scan.StdErr
                $updates = @(Parse-WinGetUpgradeOutput -Text $combined)
                if ($scan.ExitCode -ne 0 -and $updates.Count -eq 0) {
                    $details = $combined.Trim()
                    if ($details.Length -gt 1200) { $details = $details.Substring(0,1200) }
                    throw "WinGet failed to check for updates (exit code $($scan.ExitCode)). $details"
                }
                $eventArgs.Result = [pscustomobject]@{ Mode='CheckUpdates'; Items=$updates; Results=@(); ExitCode=$scan.ExitCode }
                Write-SetupLog "Upgrade scan completed. Parsed $($updates.Count) package(s); exit code $($scan.ExitCode)."
            }
            'InstallSelected' {
                $results = New-Object System.Collections.ArrayList
                $total = @($job.Items).Count
                $index = 0
                foreach ($item in @($job.Items)) {
                    $index++
                    $sender.ReportProgress(0, "Installing $($item.Name) ($index of $total)...")
                    try {
                        if ($item.Type -eq 'Winget') {
                            $result = Invoke-ExternalCommand -FilePath $script:WingetPath -Arguments @('install','--id',[string]$item.Id,'--exact','--silent','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
                            $code = [int]$result.ExitCode
                            if ($code -notin @(0, 3010, 1641)) {
                                $details = ([string]$result.StdErr + ' ' + [string]$result.StdOut).Trim()
                                if ($details.Length -gt 260) { $details = $details.Substring(0,260) }
                                throw "WinGet returned exit code $code. $details"
                            }
                        } else {
                            Install-CustomPackage -Item $item -Worker $sender
                        }
                        [void]$results.Add([pscustomobject]@{ Name=$item.Name; Success=$true; Message='Installed successfully' })
                        Write-SetupLog "Install success: $($item.Name)"
                    } catch {
                        [void]$results.Add([pscustomobject]@{ Name=$item.Name; Success=$false; Message=$_.Exception.Message })
                        Write-SetupLog "Install failed: $($item.Name) :: $($_.Exception.Message)"
                    }
                }
                $eventArgs.Result = [pscustomobject]@{ Mode='InstallSelected'; Items=@(); Results=@($results.ToArray()) }
            }
            'UpdateSelected' {
                $results = New-Object System.Collections.ArrayList
                $total = @($job.Items).Count
                $index = 0
                foreach ($item in @($job.Items)) {
                    $index++
                    $sender.ReportProgress(0, "Updating $($item.Name) ($index of $total)...")
                    try {
                        $result = Invoke-ExternalCommand -FilePath $script:WingetPath -Arguments @('upgrade','--id',[string]$item.Id,'--exact','--silent','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
                        $code = [int]$result.ExitCode
                        if ($code -notin @(0, 3010, 1641)) {
                            $details = ([string]$result.StdErr + ' ' + [string]$result.StdOut).Trim()
                            if ($details.Length -gt 260) { $details = $details.Substring(0,260) }
                            throw "WinGet returned exit code $code. $details"
                        }
                        [void]$results.Add([pscustomobject]@{ Name=$item.Name; Success=$true; Message='Updated successfully' })
                        Write-SetupLog "Update success: $($item.Name)"
                    } catch {
                        [void]$results.Add([pscustomobject]@{ Name=$item.Name; Success=$false; Message=$_.Exception.Message })
                        Write-SetupLog "Update failed: $($item.Name) :: $($_.Exception.Message)"
                    }
                }
                $eventArgs.Result = [pscustomobject]@{ Mode='UpdateSelected'; Items=@(); Results=@($results.ToArray()) }
            }
        }
    })

    $worker.add_ProgressChanged({
        param($sender, $eventArgs)
        if ($script:StatusLabel -and $eventArgs.UserState) { $script:StatusLabel.Text = [string]$eventArgs.UserState }
    })

    $worker.add_RunWorkerCompleted({
        param($sender, $eventArgs)
        $script:IsBusy = $false
        if ($script:ProgressBar) { $script:ProgressBar.IsIndeterminate = $false; $script:ProgressBar.Visibility = 'Collapsed'; $script:ProgressBar.Value = 0 }
        foreach ($control in $script:BusyControls) { $control.IsEnabled = $true }

        if ($eventArgs.Error) {
            $message = $eventArgs.Error.Exception.Message
            if ($script:StatusLabel) { $script:StatusLabel.Text = "Operation failed: $message" }
            Write-SetupLog "Worker error: $message"
            [System.Windows.MessageBox]::Show($message, 'SetupHub error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            return
        }
        $result = $eventArgs.Result
        if ($result.Mode -eq 'CheckUpdates') {
            $script:UpgradeItems = @($result.Items)
            Build-UpdateList
            if ($script:StatusLabel) { $script:StatusLabel.Text = if ($script:UpgradeItems.Count -eq 0) { 'Scan complete. No available updates were found.' } else { "Scan complete. $($script:UpgradeItems.Count) update(s) available." } }
        } else {
            $items = @($result.Results)
            $successes = @($items | Where-Object { $_.Success }).Count
            $failures = @($items | Where-Object { -not $_.Success }).Count
            if ($script:StatusLabel) { $script:StatusLabel.Text = "Finished: $successes succeeded, $failures failed. See $script:LogPath for details." }
            if ($failures -gt 0) {
                $failureLines = @($items | Where-Object { -not $_.Success } | ForEach-Object { "• $($_.Name): $($_.Message)" }) -join "`r`n"
                if ($failureLines.Length -gt 1800) { $failureLines = $failureLines.Substring(0,1800) + "`r`n..." }
                [System.Windows.MessageBox]::Show("Completed with $failures failure(s).`r`n`r`n$failureLines`r`n`r`nFull log: $script:LogPath", 'SetupHub results', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("All $successes task(s) completed successfully.", 'SetupHub results', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            }
            if ($result.Mode -eq 'UpdateSelected') {
                # Re-scan after updates so the displayed list reflects the current state.
                Start-AsyncWork -Mode 'CheckUpdates' -Items @()
            }
        }
    })

    $script:ActiveWorker = $worker
    $worker.RunWorkerAsync([pscustomobject]@{ Mode=$Mode; Items=@($Items) })
}

function Install-CustomPackage {
    param($Item, $Worker)
    $url = [string]$Item.Url
    if ($url -notmatch '^https://') { throw 'Custom installer URL must use HTTPS.' }
    $packageType = ([string]$Item.PackageType).ToUpperInvariant()
    if ($packageType -notin @('EXE','MSI','MSIX','MSIXBUNDLE')) { throw "Unsupported installer type: $packageType" }
    if ($packageType -eq 'EXE' -and [string]::IsNullOrWhiteSpace([string]$Item.SilentArgs)) {
        throw 'Add the installer vendor's documented silent arguments before installing this EXE.'
    }

    $downloadRoot = Join-Path $script:DataRoot 'Downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $target = Join-Path $downloadRoot (([guid]::NewGuid().ToString('N')) + '.' + $packageType.ToLowerInvariant())
    $Worker.ReportProgress(0, "Downloading $($Item.Name)...")
    Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 240 -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -le 0) {
        throw 'The download was empty or failed.'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Item.Sha256)) {
        $expected = ([string]$Item.Sha256).Trim().ToUpperInvariant()
        if ($expected -notmatch '^[A-F0-9]{64}$') {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw 'The expected SHA-256 must contain exactly 64 hexadecimal characters.'
        }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch. Expected $expected, received $actual. Installer was not run."
        }
    }

    $Worker.ReportProgress(0, "Running silent installer for $($Item.Name)...")
    try {
        switch ($packageType) {
            'EXE' {
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = $target
                $startInfo.Arguments = [string]$Item.SilentArgs
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $startInfo
                try {
                    if (-not $process.Start()) { throw 'The installer process did not start.' }
                    $outTask = $process.StandardOutput.ReadToEndAsync()
                    $errTask = $process.StandardError.ReadToEndAsync()
                    $process.WaitForExit()
                    $exit = [int]$process.ExitCode
                    $null = $outTask.GetAwaiter().GetResult()
                    $err = [string]$errTask.GetAwaiter().GetResult()
                    if ($exit -notin @(0, 3010, 1641)) { throw "Installer returned exit code $exit. $err" }
                } finally { $process.Dispose() }
            }
            'MSI' {
                $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
                $result = Invoke-ExternalCommand -FilePath $msiexec -Arguments @('/i',$target,'/qn','/norestart')
                if ([int]$result.ExitCode -notin @(0, 3010, 1641)) { throw "MSI installer returned exit code $($result.ExitCode). $($result.StdErr)" }
            }
            'MSIX' {
                Add-AppxPackage -Path $target -ErrorAction Stop
            }
            'MSIXBUNDLE' {
                Add-AppxPackage -Path $target -ErrorAction Stop
            }
        }
    } finally {
        # Keep custom installers in the local Downloads folder only if an install failed.
        # Cleanup on success is handled by the success path below.
    }
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
}

function Save-CustomAppFromDialog {
    param($Dialog, $Fields, $TypeBox)
    $values = @{}
    foreach ($field in $Fields) { $values[$field.Key] = [string]$field.Control.Text.Trim() }
    $packageType = [string]$TypeBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($values.Name)) {
        [System.Windows.MessageBox]::Show('Enter a program name.', 'Missing name', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    $parsedUri = $null
    if (-not [Uri]::TryCreate($values.Url, [UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -ne 'https') {
        [System.Windows.MessageBox]::Show('Enter a valid HTTPS download URL.', 'Invalid URL', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    if ($packageType -eq 'EXE' -and [string]::IsNullOrWhiteSpace($values.SilentArgs)) {
        [System.Windows.MessageBox]::Show('Enter the installer vendor's documented silent arguments for this EXE. There is no universal silent flag.', 'Silent arguments required', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($values.IconUrl)) {
        $iconUri = $null
        if (-not [Uri]::TryCreate($values.IconUrl, [UriKind]::Absolute, [ref]$iconUri) -or $iconUri.Scheme -ne 'https') {
            [System.Windows.MessageBox]::Show('The logo URL must also use HTTPS.', 'Invalid logo URL', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($values.Sha256) -and $values.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        [System.Windows.MessageBox]::Show('The SHA-256 must be exactly 64 hexadecimal characters, or left empty.', 'Invalid SHA-256', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    if (@($script:AppItems | Where-Object { $_.Name -eq $values.Name }).Count -gt 0) {
        [System.Windows.MessageBox]::Show('A program with this name already exists.', 'Duplicate program', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    [void]$script:AppItems.Add([pscustomobject]@{
        Name=$values.Name; Description='Custom installer link'; Id=$null; Type='Custom'; Category='Custom'; Selected=$false
        Url=$values.Url; PackageType=$packageType; SilentArgs=$values.SilentArgs; IconUrl=$values.IconUrl; Sha256=$values.Sha256.ToUpperInvariant(); CatalogSource='Local'
    })
    Save-CustomCatalog
    Build-AppList
    Write-SetupLog "Custom program added: $($values.Name)"
    $Dialog.DialogResult = $true
    $Dialog.Close()
}

function Show-AddCustomDialog {
    $dialog = New-Object System.Windows.Window
    $dialog.Title = 'Add a custom installer'
    $dialog.Width = 620; $dialog.Height = 610
    $dialog.MinWidth = 580; $dialog.MinHeight = 560
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Owner = $script:Window
    $dialog.Background = New-UiBrush '#12151A'
    $dialog.Foreground = New-UiBrush '#E5E7EB'
    $dialog.FontFamily = 'Segoe UI'

    $title = New-TextBlock -Text 'Add your own download link' -Size 20 -Color '#F4F6FA' -Bold $true
    $title.Margin = [System.Windows.Thickness]::new(0,0,0,5)
    $note = New-TextBlock -Text 'Only add installers you trust. EXE silent flags differ by vendor; use the vendor-documented arguments. HTTPS is required.' -Size 12 -Color '#A4ADBA'
    $note.Margin = [System.Windows.Thickness]::new(0,0,0,14)

    function New-DialogTextBox([string]$Initial='') {
        $box = New-Object System.Windows.Controls.TextBox
        $box.Text = $Initial
        $box.Height = 32
        $box.Padding = [System.Windows.Thickness]::new(9,6,9,5)
        $box.Background = New-UiBrush '#1C2129'
        $box.Foreground = New-UiBrush '#F0F3F7'
        $box.BorderBrush = New-UiBrush '#3A414D'
        $box.CaretBrush = New-UiBrush '#FFFFFF'
        $box.FontFamily = 'Segoe UI'
        $box.FontSize = 13
        return $box
    }

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Vertical'
    $panel.Margin = [System.Windows.Thickness]::new(22)
    [void]$panel.Children.Add($title)
    [void]$panel.Children.Add($note)

    $fields = @()
    $rows = @(
        @{Label='Program name *'; Key='Name'; Initial=''},
        @{Label='Direct download URL (HTTPS) *'; Key='Url'; Initial='https://'},
        @{Label='Logo URL (HTTPS, optional)'; Key='IconUrl'; Initial=''},
        @{Label='Silent arguments (required for EXE)'; Key='SilentArgs'; Initial=''},
        @{Label='Expected SHA-256 (optional, recommended)'; Key='Sha256'; Initial=''}
    )
    foreach ($field in $rows) {
        $label = New-TextBlock -Text $field.Label -Size 12 -Color '#C1C8D2' -Bold $true
        $label.Margin = [System.Windows.Thickness]::new(0,0,0,5)
        [void]$panel.Children.Add($label)
        $box = New-DialogTextBox $field.Initial
        $box.Margin = [System.Windows.Thickness]::new(0,0,0,11)
        [void]$panel.Children.Add($box)
        $fields += ,([pscustomobject]@{Key=$field.Key; Control=$box})
    }
    $typeLabel = New-TextBlock -Text 'Installer type *' -Size 12 -Color '#C1C8D2' -Bold $true
    $typeLabel.Margin = [System.Windows.Thickness]::new(0,0,0,5)
    [void]$panel.Children.Add($typeLabel)
    $typeBox = New-Object System.Windows.Controls.ComboBox
    $typeBox.Items.Add('EXE') | Out-Null; $typeBox.Items.Add('MSI') | Out-Null; $typeBox.Items.Add('MSIX') | Out-Null; $typeBox.Items.Add('MSIXBUNDLE') | Out-Null
    $typeBox.SelectedIndex = 0
    $typeBox.Height = 32; $typeBox.Padding = [System.Windows.Thickness]::new(7,4,7,4)
    $typeBox.Background = New-UiBrush '#1C2129'; $typeBox.Foreground = New-UiBrush '#F0F3F7'
    $typeBox.BorderBrush = New-UiBrush '#3A414D'
    $typeBox.Margin = [System.Windows.Thickness]::new(0,0,0,14)
    [void]$panel.Children.Add($typeBox)
    $buttonRow = New-Object System.Windows.Controls.StackPanel
    $buttonRow.Orientation = 'Horizontal'; $buttonRow.HorizontalAlignment = 'Right'
    $saveButton = New-SetupButton -Text 'Add program' -Background '#D97706' -Foreground '#FFFFFF' -Border '#D97706'
    $cancelButton = New-SetupButton -Text 'Cancel'
    [void]$buttonRow.Children.Add($saveButton); [void]$buttonRow.Children.Add($cancelButton)
    [void]$panel.Children.Add($buttonRow)
    $dialog.Content = $panel

    $cancelButton.Tag = $dialog
    $cancelButton.Add_Click({
        $targetDialog = $args[0].Tag
        $targetDialog.DialogResult = $false
        $targetDialog.Close()
    })
    $saveButton.Tag = [pscustomobject]@{ Dialog=$dialog; Fields=$fields; TypeBox=$typeBox }
    $saveButton.Add_Click({
        $context = $args[0].Tag
        Save-CustomAppFromDialog -Dialog $context.Dialog -Fields $context.Fields -TypeBox $context.TypeBox
    })

    $null = $dialog.ShowDialog()
}

Load-CustomCatalog

$script:WingetPath = Get-WinGetPath
$wingetVersion = $null
if ($script:WingetPath) {
    try {
        $versionResult = Invoke-ExternalCommand -FilePath $script:WingetPath -Arguments @('--version')
        $wingetVersion = ([string]$versionResult.StdOut).Trim()
    } catch { }
}

$window = New-Object System.Windows.Window
$script:Window = $window
$window.Title = 'SetupHub'
$window.Width = 1040; $window.Height = 790
$window.MinWidth = 850; $window.MinHeight = 650
$window.WindowStartupLocation = 'CenterScreen'
$window.Background = New-UiBrush '#111419'
$window.Foreground = New-UiBrush '#E5E7EB'
$window.FontFamily = 'Segoe UI'
$window.UseLayoutRounding = $true

$root = New-Object System.Windows.Controls.Grid
$root.Margin = [System.Windows.Thickness]::new(22)
Add-GridRow $root ([System.Windows.GridLength]::Auto)
Add-GridRow $root ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))
Add-GridRow $root ([System.Windows.GridLength]::Auto)

$header = New-Object System.Windows.Controls.Grid
Add-GridColumn $header ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))
Add-GridColumn $header ([System.Windows.GridLength]::Auto)
$headingStack = New-Object System.Windows.Controls.StackPanel
$headingStack.Orientation = 'Vertical'
$heading = New-TextBlock -Text 'SetupHub' -Size 26 -Color '#F7F8FA' -Bold $true
$subtitle = New-TextBlock -Text 'Install the apps you choose. Check and apply WinGet updates.' -Size 12.5 -Color '#9AA4B2'
$subtitle.Margin = [System.Windows.Thickness]::new(0,4,0,17)
[void]$headingStack.Children.Add($heading); [void]$headingStack.Children.Add($subtitle)
[System.Windows.Controls.Grid]::SetColumn($headingStack,0); [void]$header.Children.Add($headingStack)
$headerRight = New-Object System.Windows.Controls.StackPanel
$headerRight.Orientation = 'Vertical'; $headerRight.HorizontalAlignment = 'Right'
$script:WingetStatusText = New-TextBlock -Text $(if ($script:WingetPath) { "WinGet $wingetVersion" } else { 'WinGet is not installed' }) -Size 11.5 -Color $(if ($script:WingetPath) { '#8ED6A8' } else { '#F0B35D' }) -Bold $true
$script:WingetStatusText.HorizontalAlignment = 'Right'
[void]$headerRight.Children.Add($script:WingetStatusText)
$getWingetButton = New-SetupButton -Text 'Get WinGet' -Background '#242A33' -Foreground '#E5E7EB' -Border '#3A414D'
$getWingetButton.HorizontalAlignment = 'Right'; $getWingetButton.Margin = [System.Windows.Thickness]::new(0,8,0,14)
$getWingetButton.Add_Click({ Open-WinGetInstallPage })
[void]$headerRight.Children.Add($getWingetButton)
[System.Windows.Controls.Grid]::SetColumn($headerRight,1); [void]$header.Children.Add($headerRight)
[System.Windows.Controls.Grid]::SetRow($header,0); [void]$root.Children.Add($header)

$tabs = New-Object System.Windows.Controls.TabControl
$tabs.Background = New-UiBrush '#111419'
$tabs.Foreground = New-UiBrush '#E5E7EB'
$tabs.BorderBrush = New-UiBrush '#2B313B'
$tabs.BorderThickness = [System.Windows.Thickness]::new(1)

# Tab 1: application selection and installation.
$installTab = New-Object System.Windows.Controls.TabItem
$installTab.Header = 'Install apps'
$installTab.Padding = [System.Windows.Thickness]::new(15,8,15,8)
$installRoot = New-Object System.Windows.Controls.Grid
$installRoot.Margin = [System.Windows.Thickness]::new(13)
Add-GridRow $installRoot ([System.Windows.GridLength]::Auto)
Add-GridRow $installRoot ([System.Windows.GridLength]::Auto)
Add-GridRow $installRoot ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))

$searchRow = New-Object System.Windows.Controls.Grid
Add-GridColumn $searchRow ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))
Add-GridColumn $searchRow ([System.Windows.GridLength]::Auto)
$script:SearchBox = New-Object System.Windows.Controls.TextBox
$script:SearchBox.Height = 38; $script:SearchBox.Padding = [System.Windows.Thickness]::new(11,8,11,7)
$script:SearchBox.Background = New-UiBrush '#1A1E25'; $script:SearchBox.Foreground = New-UiBrush '#F0F3F7'
$script:SearchBox.BorderBrush = New-UiBrush '#343B46'; $script:SearchBox.CaretBrush = New-UiBrush '#FFFFFF'
$script:SearchBox.FontFamily = 'Segoe UI'; $script:SearchBox.FontSize = 13
$script:SearchBox.Margin = [System.Windows.Thickness]::new(0,0,10,9)
[System.Windows.Controls.Grid]::SetColumn($script:SearchBox,0); [void]$searchRow.Children.Add($script:SearchBox)
$addCustomButton = New-SetupButton -Text '+ Add custom app' -Background '#252B34' -Foreground '#EDF1F7' -Border '#3A414D'
$addCustomButton.Height = 38; $addCustomButton.Margin = [System.Windows.Thickness]::new(0,0,0,9)
$addCustomButton.Add_Click({ Show-AddCustomDialog })
[System.Windows.Controls.Grid]::SetColumn($addCustomButton,1); [void]$searchRow.Children.Add($addCustomButton)
[System.Windows.Controls.Grid]::SetRow($searchRow,0); [void]$installRoot.Children.Add($searchRow)

$installCommands = New-Object System.Windows.Controls.DockPanel
$installCommands.LastChildFill = $false
$selectAppsButton = New-SetupButton -Text 'Select all'
$installSelectedButton = New-SetupButton -Text 'Install selected' -Background '#D97706' -Foreground '#FFFFFF' -Border '#D97706'
$installSelectedButton.Margin = [System.Windows.Thickness]::new(0,0,0,10)
$selectAppsButton.Margin = [System.Windows.Thickness]::new(0,0,8,10)
[void]$installCommands.Children.Add($selectAppsButton)
[void]$installCommands.Children.Add($installSelectedButton)
$smallText = New-TextBlock -Text 'Custom installers run with the silent arguments you provide.' -Size 11.5 -Color '#8F99A8'
$smallText.VerticalAlignment = 'Center'; $smallText.Margin = [System.Windows.Thickness]::new(8,0,0,10)
[System.Windows.Controls.DockPanel]::SetDock($smallText,[System.Windows.Controls.Dock]::Right)
[void]$installCommands.Children.Add($smallText)
[System.Windows.Controls.Grid]::SetRow($installCommands,1); [void]$installRoot.Children.Add($installCommands)

$appScroll = New-Object System.Windows.Controls.ScrollViewer
$appScroll.VerticalScrollBarVisibility = 'Auto'; $appScroll.HorizontalScrollBarVisibility = 'Disabled'
$appScroll.Background = New-UiBrush '#111419'
$script:AppListPanel = New-Object System.Windows.Controls.StackPanel
$script:AppListPanel.Orientation = 'Vertical'
$appScroll.Content = $script:AppListPanel
[System.Windows.Controls.Grid]::SetRow($appScroll,2); [void]$installRoot.Children.Add($appScroll)
$installTab.Content = $installRoot
[void]$tabs.Items.Add($installTab)

# Tab 2: WinGet upgrades.
$updateTab = New-Object System.Windows.Controls.TabItem
$updateTab.Header = 'App updates'
$updateTab.Padding = [System.Windows.Thickness]::new(15,8,15,8)
$updateRoot = New-Object System.Windows.Controls.Grid
$updateRoot.Margin = [System.Windows.Thickness]::new(13)
Add-GridRow $updateRoot ([System.Windows.GridLength]::Auto)
Add-GridRow $updateRoot ([System.Windows.GridLength]::Auto)
Add-GridRow $updateRoot ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))

$updateNote = New-TextBlock -Text 'Find available upgrades, select specific apps, and install updates silently. Detection depends on what WinGet can match to its package sources.' -Size 12 -Color '#9AA4B2'
$updateNote.Margin = [System.Windows.Thickness]::new(0,0,0,12)
[System.Windows.Controls.Grid]::SetRow($updateNote,0); [void]$updateRoot.Children.Add($updateNote)
$updateCommands = New-Object System.Windows.Controls.StackPanel
$updateCommands.Orientation = 'Horizontal'
$checkUpdatesButton = New-SetupButton -Text 'Check for updates' -Background '#D97706' -Foreground '#FFFFFF' -Border '#D97706'
$selectUpdatesButton = New-SetupButton -Text 'Select all'
$updateSelectedButton = New-SetupButton -Text 'Update selected' -Background '#252B34' -Foreground '#F3F5F8' -Border '#3A414D'
[void]$updateCommands.Children.Add($checkUpdatesButton)
[void]$updateCommands.Children.Add($selectUpdatesButton)
[void]$updateCommands.Children.Add($updateSelectedButton)
[System.Windows.Controls.Grid]::SetRow($updateCommands,1); [void]$updateRoot.Children.Add($updateCommands)
$updateScroll = New-Object System.Windows.Controls.ScrollViewer
$updateScroll.VerticalScrollBarVisibility = 'Auto'; $updateScroll.HorizontalScrollBarVisibility = 'Disabled'
$updateScroll.Background = New-UiBrush '#111419'
$script:UpdateListPanel = New-Object System.Windows.Controls.StackPanel
$script:UpdateListPanel.Orientation = 'Vertical'
$updateScroll.Content = $script:UpdateListPanel
[System.Windows.Controls.Grid]::SetRow($updateScroll,2); [void]$updateRoot.Children.Add($updateScroll)
$updateTab.Content = $updateRoot
[void]$tabs.Items.Add($updateTab)

[System.Windows.Controls.Grid]::SetRow($tabs,1); [void]$root.Children.Add($tabs)

$footer = New-Object System.Windows.Controls.Grid
Add-GridColumn $footer ([System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star))
Add-GridColumn $footer ([System.Windows.GridLength]::Auto)
$script:StatusLabel = New-TextBlock -Text $(if ($script:WingetPath) { 'Ready.' } else { 'Ready. WinGet is required for WinGet-based installs and app updates.' }) -Size 11.5 -Color '#9AA4B2'
$script:StatusLabel.Margin = [System.Windows.Thickness]::new(0,12,10,0)
[System.Windows.Controls.Grid]::SetColumn($script:StatusLabel,0); [void]$footer.Children.Add($script:StatusLabel)
$script:ProgressBar = New-Object System.Windows.Controls.ProgressBar
$script:ProgressBar.Width = 120; $script:ProgressBar.Height = 5
$script:ProgressBar.Margin = [System.Windows.Thickness]::new(0,17,0,0)
$script:ProgressBar.IsIndeterminate = $false; $script:ProgressBar.Visibility = 'Collapsed'
$script:ProgressBar.Foreground = New-UiBrush '#D97706'; $script:ProgressBar.Background = New-UiBrush '#2A3039'
[System.Windows.Controls.Grid]::SetColumn($script:ProgressBar,1); [void]$footer.Children.Add($script:ProgressBar)
[System.Windows.Controls.Grid]::SetRow($footer,2); [void]$root.Children.Add($footer)

$window.Content = $root
$script:BusyControls = @($addCustomButton,$selectAppsButton,$installSelectedButton,$checkUpdatesButton,$selectUpdatesButton,$updateSelectedButton,$getWingetButton)

$script:SearchBox.Add_TextChanged({ Build-AppList })
$selectAppsButton.Add_Click({
    foreach ($item in $script:AppItems) { $item.Selected = $true }
    Build-AppList
})
$installSelectedButton.Add_Click({
    $selected = @($script:AppItems | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Select at least one app first.', 'Nothing selected', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $custom = @($selected | Where-Object { $_.Type -eq 'Custom' })
    if ($custom.Count -gt 0) {
        $names = @($custom | ForEach-Object { "• $($_.Name) — $($_.Url)" }) -join "`r`n"
        $choice = [System.Windows.MessageBox]::Show("You selected custom installers. They will be downloaded and executed using their configured installer type/arguments. Only continue if you trust the publisher and URL.`r`n`r`n$names`r`n`r`nContinue?", 'Review custom installers', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    Start-AsyncWork -Mode 'InstallSelected' -Items $selected
})
$checkUpdatesButton.Add_Click({ Start-AsyncWork -Mode 'CheckUpdates' -Items @() })
$selectUpdatesButton.Add_Click({
    foreach ($item in $script:UpgradeItems) { $item.Selected = $true }
    Build-UpdateList
})
$updateSelectedButton.Add_Click({
    $selected = @($script:UpgradeItems | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Check for updates and select at least one app first.', 'Nothing selected', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    Start-AsyncWork -Mode 'UpdateSelected' -Items $selected
})

Build-AppList
Build-UpdateList
Write-SetupLog "SetupHub started. WinGet path: $script:WingetPath"

$app = [System.Windows.Application]::Current
if ($null -eq $app) { $app = New-Object System.Windows.Application }
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
[void]$app.Run($window)
