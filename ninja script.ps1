#==============================================================================
# Sysmon Deployment Script for Ninja RMM
#==============================================================================
# Description: Installs or updates Sysmon with the latest configuration
# Features:
#   - Installs Sysmon if not present
#   - Forces config update on every run (idempotent)
#   - Verifies Microsoft signature on binary
#   - Cleans up legacy installation artifacts
#   - Exit 0 on success, 1 on failure
#==============================================================================

$ErrorActionPreference = 'Stop'

#region Configuration
$SysmonUrl = 'https://live.sysinternals.com/Sysmon64.exe'
$ConfigUrl = 'https://raw.githubusercontent.com/modhash/sysmon/main/sysmonconfig-export.xml'
$WorkDir   = 'C:\ProgramData\sysmon'
$SysmonExe = Join-Path $WorkDir 'Sysmon64.exe'
$ConfigFile = Join-Path $WorkDir 'sysmonconfig-export.xml'
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
    Write-Output "[✓] Downloaded to: $Dest"
  }
  catch {
    Remove-Item $Dest -Force -ErrorAction SilentlyContinue
    throw "Download failed: $($_.Exception.Message)"
  }
}

function Test-ValidXml($Path) {
  try {
    Write-Output "[+] Validating XML file: $Path"
    $xml = [xml](Get-Content $Path -Raw -ErrorAction Stop)
    if ($xml.Sysmon -or $xml.SelectSingleNode("//Sysmon")) {
      Write-Output "[✓] XML is a valid Sysmon config"
      return $true
    }
    Write-Output "[X] XML is not a valid Sysmon config (missing <Sysmon> root element)"
    return $false
  }
  catch {
    Write-Output "[X] XML validation failed: $($_.Exception.Message)"
    return $false
  }
}

function Test-MicrosoftSignature($Path) {
  Write-Output "[+] Verifying digital signature for: $Path"
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

function Remove-LegacyInstallation {
  Write-Output "[+] Checking for legacy installation artifacts..."
  $cleanupPerformed = $false
  
  # Remove legacy scheduled task
  $task = Get-ScheduledTask -TaskName 'Update_Sysmon_Rules' -ErrorAction SilentlyContinue
  if ($task) {
    Write-Output "    [→] Removing scheduled task: Update_Sysmon_Rules"
    Unregister-ScheduledTask -TaskName 'Update_Sysmon_Rules' -Confirm:$false -ErrorAction SilentlyContinue
    $cleanupPerformed = $true
  }
  
  # Remove legacy batch files
  $legacyFiles = @('Auto_Update.bat', 'Install Sysmon.bat')
  foreach ($file in $legacyFiles) {
    $filePath = Join-Path $WorkDir $file
    if (Test-Path $filePath) {
      Write-Output "    [→] Removing legacy file: $file"
      Remove-Item $filePath -Force -ErrorAction SilentlyContinue
      $cleanupPerformed = $true
    }
  }
  
  if ($cleanupPerformed) {
    Write-Output "[✓] Legacy installation artifacts cleaned up"
  } else {
    Write-Output "[=] No legacy artifacts found"
  }
}

#endregion

#region Main Execution

try {
  Write-Output "=================================================="
  Write-Output "Starting Sysmon Deployment Script"
  Write-Output "=================================================="
  
  # Step 1: Clean up legacy installation method
  Remove-LegacyInstallation
  
  # Step 2: Determine config source and copy to working directory
  $LocalConfigPath = Join-Path $PSScriptRoot 'sysmonconfig-export.xml'
  if (Test-Path $LocalConfigPath) {
    Write-Output "[+] Found local config file: $LocalConfigPath"
    Write-Output "[+] Copying to working directory..."
    Copy-Item -Path $LocalConfigPath -Destination $ConfigFile -Force
  } else {
    Write-Output "[!] Local config not found at: $LocalConfigPath"
    Write-Output "[+] Downloading from GitHub..."
    Download $ConfigUrl $ConfigFile
  }

  # Step 3: Validate configuration
  if (-not (Test-ValidXml $ConfigFile)) {
    Remove-Item $ConfigFile -Force -ErrorAction SilentlyContinue
    throw "Configuration file is not valid Sysmon XML"
  }
  
  # Step 4: Verify Sysmon executable exists
  if (-not (Test-Path $SysmonExe)) {
    Write-Output "[+] Sysmon binary not found, downloading..."
    Download $SysmonUrl $SysmonExe
    
    # Verify signature
    if (-not (Test-MicrosoftSignature $SysmonExe)) {
      Remove-Item $SysmonExe -Force -ErrorAction SilentlyContinue
      throw "Downloaded Sysmon binary failed signature verification"
    }
  } else {
    Write-Output "[=] Sysmon binary found at: $SysmonExe"
    
    # Verify signature of existing binary
    if (-not (Test-MicrosoftSignature $SysmonExe)) {
      Remove-Item $SysmonExe -Force -ErrorAction SilentlyContinue
      throw "Existing Sysmon binary failed signature verification"
    }
  }

  # Step 5: Install or update Sysmon
  $svc = Get-Service -Name 'Sysmon64' -ErrorAction SilentlyContinue

  if (-not $svc) {
    #--- Fresh Installation ---
    Write-Output "[+] Sysmon service not found. Starting fresh installation..."
    & $SysmonExe -accepteula -i $ConfigFile
    
    if ($LASTEXITCODE -ne 0) {
      throw "Installation failed with exit code $LASTEXITCODE"
    }
    
    Start-Sleep -Seconds 2
    $svcCheck = Get-Service Sysmon64 -ErrorAction Stop
    if ($svcCheck.Status -ne 'Running') {
      throw "Service exists but is not running after install"
    }
    Write-Output "[✓] Service is running"
    
    # Configure automatic recovery
    Write-Output "[+] Configuring service auto-recovery..."
    & sc.exe failure Sysmon64 actions= restart/10000/restart/10000// reset= 120 | Out-Null
    
    Write-Output "[✓] Sysmon installed successfully"
  }
  else {
    #--- Update Existing Installation ---
    Write-Output "[=] Sysmon service detected. Forcing configuration update..."
    
    & $SysmonExe -c $ConfigFile
    
    if ($LASTEXITCODE -ne 0) {
      throw "Config update failed with exit code $LASTEXITCODE"
    }
    
    # Verify service still running
    Start-Sleep -Seconds 1
    $svcCheck = Get-Service Sysmon64 -ErrorAction Stop
    if ($svcCheck.Status -ne 'Running') {
      throw "Service stopped after config update"
    }
    Write-Output "[✓] Service is still running"
    
    Write-Output "[✓] Config updated successfully"
  }

  Write-Output "=================================================="
  Write-Output "Sysmon Deployment Script Finished Successfully"
  Write-Output "=================================================="
  exit 0
}
catch {
  Write-Error "[X] FATAL ERROR: $($_.Exception.Message)"
  Write-Output "=================================================="
  Write-Output "Sysmon Deployment Script Finished with Errors"
  Write-Output "=================================================="
  exit 1
}

#endregion
