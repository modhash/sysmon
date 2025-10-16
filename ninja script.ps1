<parameter name="newString">#==============================================================================
# Sysmon Deployment Script for Ninja RMM
#==============================================================================
# Description: Idempotent Sysmon installer/updater with signature validation
# Features:
#   - Installs Sysmon if not present
#   - Updates config only when changed (hash comparison)
#   - Verifies Microsoft signature on every run
#   - Cleans up old GitHub-based installation artifacts
#   - Exit 0 on success, 1 on failure (Ninja compatible)
#==============================================================================

$ErrorActionPreference = 'Stop'

#region Configuration
$SysmonUrl = 'https://live.sysinternals.com/Sysmon64.exe'
$ConfigUrl = 'https://raw.githubusercontent.com/modhash/sysmon/main/sysmonconfig-export.xml'
$WorkDir   = 'C:\ProgramData\sysmon'
$SysmonExe = Join-Path $WorkDir 'Sysmon64.exe'
$NewCfg    = Join-Path $WorkDir 'sysmonconfig-export.xml'
$HashFile  = Join-Path $WorkDir 'config.hash'
$SysmonUpdateDays = 30  # Re-download Sysmon binary every X days
#endregion

#region Initialization
try { 
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 
} catch { 
  # TLS 1.2 already enabled or not needed
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
#endregion

#region Helper Functions

function Download($Url, $Dest) {
  Write-Output "[+] Downloading: $Url"
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest -TimeoutSec 180
    if (-not (Test-Path $Dest)) {
      throw "File not created after download"
    }
  }
  catch {
    Remove-Item $Dest -Force -ErrorAction SilentlyContinue
    throw "Download failed: $($_.Exception.Message)"
  }
}

function Get-Sha256Hash($Path) {
  if (Test-Path $Path) { 
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant() 
  } else { 
    $null 
  }
}

function Test-SysmonBinaryNeedsUpdate {
  if (-not (Test-Path $SysmonExe)) {
    Write-Output "[+] Sysmon binary not found, will download"
    return $true
  }
  
  # Check file age
  $fileAge = (Get-Item $SysmonExe).LastWriteTime
  $daysSinceUpdate = (New-TimeSpan -Start $fileAge -End (Get-Date)).Days
  
  if ($daysSinceUpdate -ge $SysmonUpdateDays) {
    Write-Output "[+] Sysmon binary is $daysSinceUpdate days old, will update"
    return $true
  }
  
  return $false
}

function Test-ValidXml($Path) {
  try {
    $xml = [xml](Get-Content $Path -Raw -ErrorAction Stop)
    if ($xml.Sysmon -or $xml.SelectSingleNode("//Sysmon")) {
      return $true
    }
    return $false
  }
  catch {
    return $false
  }
}

function Test-MicrosoftSignature($Path) {
  Write-Output "[+] Verifying digital signature..."
  try {
    $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    if ($sig.Status -ne 'Valid') {
      throw "Invalid signature status: $($sig.Status)"
    }
    $subject = $sig.SignerCertificate.Subject
    if ($subject -notmatch 'Microsoft|Sysinternals') {
      throw "Not signed by Microsoft. Subject: $subject"
    }
    Write-Output "[✓] Signature verified: $subject"
    return $true
  }
  catch {
    Write-Output "[X] Signature verification failed: $($_.Exception.Message)"
    return $false
  }
}

function Remove-OldGitHubInstallation {
  Write-Output "[+] Cleaning up old installation artifacts..."
  
  # Remove legacy scheduled task
  $task = Get-ScheduledTask -TaskName 'Update_Sysmon_Rules' -ErrorAction SilentlyContinue
  if ($task) {
    Write-Output "    Removing scheduled task: Update_Sysmon_Rules"
    Unregister-ScheduledTask -TaskName 'Update_Sysmon_Rules' -Confirm:$false -ErrorAction SilentlyContinue
  }
  
  # Remove legacy batch files
  @('Auto_Update.bat', 'Install Sysmon.bat') | ForEach-Object {
    $file = Join-Path $WorkDir $_
    if (Test-Path $file) {
      Write-Output "    Removing: $_"
      Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
  }
}

#endregion

#region Main Execution

try {
  # Step 1: Clean up old GitHub-based installation
  Remove-OldGitHubInstallation
  
  # Step 2: Download and validate configuration
  Download $ConfigUrl $NewCfg
  if (-not (Test-ValidXml $NewCfg)) {
    Remove-Item $NewCfg -Force -ErrorAction SilentlyContinue
    throw "Downloaded config is not valid Sysmon XML"
  }
  
  # Step 3: Download or update Sysmon executable
  if (Test-SysmonBinaryNeedsUpdate) {
    Write-Output "[+] Downloading Sysmon binary..."
    $TempExe = "$SysmonExe.tmp"
    Download $SysmonUrl $TempExe
    
    # Verify signature before replacing existing binary
    if (-not (Test-MicrosoftSignature $TempExe)) {
      Remove-Item $TempExe -Force -ErrorAction SilentlyContinue
      throw "Downloaded Sysmon binary failed signature verification"
    }
    
    # Replace existing binary
    if (Test-Path $SysmonExe) {
      Remove-Item $SysmonExe -Force -ErrorAction SilentlyContinue
    }
    Move-Item $TempExe $SysmonExe -Force
    Write-Output "[✓] Sysmon binary updated"
  } else {
    Write-Output "[=] Sysmon binary is current"
  }
  
  # Step 4: Verify executable signature (security critical)
  if (-not (Test-Path $SysmonExe)) {
    throw "Sysmon executable not found"
  }
  if (-not (Test-MicrosoftSignature $SysmonExe)) {
    Remove-Item $SysmonExe -Force -ErrorAction SilentlyContinue
    throw "Sysmon executable failed signature verification"
  }

  # Step 5: Install or update Sysmon
  $svc = Get-Service -Name 'Sysmon64' -ErrorAction SilentlyContinue

  if (-not $svc) {
    #--- Fresh Installation ---
    Write-Output "[+] Installing Sysmon..."
    & $SysmonExe -accepteula -i $NewCfg
    
    if ($LASTEXITCODE -ne 0) {
      throw "Installation failed with exit code $LASTEXITCODE"
    }
    
    Start-Sleep -Seconds 2
    $svcCheck = Get-Service Sysmon64 -ErrorAction Stop
    if ($svcCheck.Status -ne 'Running') {
      throw "Service exists but is not running"
    }
    
    # Configure automatic recovery
    & sc.exe failure Sysmon64 actions= restart/10000/restart/10000// reset= 120 | Out-Null
    
    # Store hash of applied config
    $configHash = Get-Sha256Hash $NewCfg
    Set-Content -Path $HashFile -Value $configHash -Force
    
    Write-Output "[✓] Sysmon installed successfully"
  }
  else {
    #--- Update Existing Installation ---
    Write-Output "[=] Sysmon detected. Checking for config changes..."
    
    # Compare new config hash against stored hash
    $newHash = Get-Sha256Hash $NewCfg
    $storedHash = if (Test-Path $HashFile) { Get-Content $HashFile -Raw -ErrorAction SilentlyContinue } else { $null }
    
    if ($newHash -and ($newHash -ne $storedHash)) {
      Write-Output "[+] Config changed. Updating..."
      Write-Output "    Old hash: $storedHash"
      Write-Output "    New hash: $newHash"
      
      & $SysmonExe -c $NewCfg
      
      if ($LASTEXITCODE -ne 0) {
        throw "Config update failed with exit code $LASTEXITCODE"
      }
      
      # Verify service still running
      Start-Sleep -Seconds 1
      $svcCheck = Get-Service Sysmon64 -ErrorAction Stop
      if ($svcCheck.Status -ne 'Running') {
        throw "Service stopped after config update"
      }
      
      # Store new hash
      Set-Content -Path $HashFile -Value $newHash -Force
      
      Write-Output "[✓] Config updated successfully"
    } else {
      Write-Output "[=] Config unchanged. No action needed."
    }
  }

  exit 0
}
catch {
  Write-Error "[X] Error: $($_.Exception.Message)"
  exit 1
}

#endregion
