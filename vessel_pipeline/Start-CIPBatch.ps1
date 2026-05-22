<#
.SYNOPSIS
    Resource-aware CIP vessel pipeline batch launcher for WSL2.
.PARAMETER DataDir
    Path to directory containing .nii.gz participant scans.
.PARAMETER ReserveRAM_GB
    RAM in GB to keep for Windows. Default: 4.
.PARAMETER ReserveCores
    CPU cores to keep for Windows. Default: 2.
.PARAMETER RunsPerParticipant
    Extraction runs per scan. Default: 1.
.PARAMETER Region
    CIP lung region. Default: WholeLung.
.PARAMETER DryRun
    Print config without making changes or launching.
.PARAMETER ForceParallel
    Override auto-calculated parallelism.
.PARAMETER Cleanup
    Cleanup policy: none|light|all. Default: light.
.EXAMPLE
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry"
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -DryRun
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -RunsPerParticipant 2
#>
param(
    [Parameter(Mandatory=$true)][string]$DataDir,
    [int]$ReserveRAM_GB      = 4,
    [int]$ReserveCores       = 2,
    [int]$RunsPerParticipant = 1,
    [string]$Region          = "WholeLung",
    [switch]$DryRun,
    [int]$ForceParallel      = 0,
    [string]$Cleanup         = "light"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CIP Vessel Pipeline - Resource Probe  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Resource probe
$totalRAM_GB  = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$availRAM_GB  = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB / 1GB, 1)
$cpuInfo      = Get-CimInstance Win32_Processor
$totalCores   = ($cpuInfo | Measure-Object -Property NumberOfCores -Sum).Sum
$totalLogical = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$cpuUsage = try {
    [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 `
        -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue, 1)
} catch { 0 }

$gpuHogs = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'llama|ollama|cuda|python' -and $_.WorkingSet64 -gt 1GB }
$gpuHogRAM_GB = 0
if ($gpuHogs) {
    $gpuHogRAM_GB = [math]::Round(($gpuHogs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 1)
}
$wslProcs = Get-Process -Name "vmmem*" -ErrorAction SilentlyContinue
$wslCurrentRAM_GB = 0
if ($wslProcs) {
    $wslCurrentRAM_GB = [math]::Round(($wslProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 1)
}

Write-Host "System Resources:" -ForegroundColor Yellow
Write-Host "  Total RAM:        $totalRAM_GB GB"
Write-Host "  Available RAM:    $availRAM_GB GB"
Write-Host "  CPU cores:        $totalCores physical / $totalLogical logical"
Write-Host "  CPU usage:        $cpuUsage%"
Write-Host "  WSL2 current:     $wslCurrentRAM_GB GB"
if ($gpuHogRAM_GB -gt 0) {
    Write-Host "  GPU/ML processes: $gpuHogRAM_GB GB" -ForegroundColor Red
}
Write-Host ""

# Allocation math
$wslRAM_GB   = [math]::Max([math]::Min([math]::Floor($totalRAM_GB - $ReserveRAM_GB - $gpuHogRAM_GB), $totalRAM_GB - 2), 4)
$wslSwap_GB  = [math]::Max([math]::Floor($wslRAM_GB / 2), 2)
$wslCores    = [math]::Max($totalLogical - $ReserveCores, 2)
$maxByRAM    = [math]::Floor(($wslRAM_GB - 2) / 4)
$maxByCPU    = [math]::Floor($wslCores / 4)
$maxParallel = [math]::Max([math]::Min($maxByRAM, $maxByCPU), 1)
$coresPerJob = [math]::Max([math]::Floor($wslCores / $maxParallel), 1)

if ($ForceParallel -gt 0) {
    $maxParallel = $ForceParallel
    Write-Host "  *** Parallelism forced to $ForceParallel ***" -ForegroundColor Red
}
if ($gpuHogRAM_GB -gt 1) {
    $maxWithoutHogs = [math]::Floor(($wslRAM_GB + $gpuHogRAM_GB - 2) / 4)
    Write-Host "WARNING: GPU/ML processes use $gpuHogRAM_GB GB." -ForegroundColor Red
    Write-Host "  Without them: $maxWithoutHogs parallel jobs possible." -ForegroundColor Red
    Write-Host ""
}
if (-not (Test-Path $DataDir -PathType Container)) {
    throw "DataDir not found: $DataDir"
}
$participants = (Get-ChildItem -Path $DataDir -Filter "*.nii.gz" -Recurse -ErrorAction SilentlyContinue).Count
$totalRuns    = $participants * $RunsPerParticipant
$estHours     = [math]::Round([double]$totalRuns / $maxParallel * 40 / 60, 1)

Write-Host "Allocation Plan:" -ForegroundColor Yellow
Write-Host "  WSL2 RAM:         $wslRAM_GB GB  (reserve $ReserveRAM_GB GB for Windows)"
Write-Host "  WSL2 swap:        $wslSwap_GB GB"
Write-Host "  WSL2 cores:       $wslCores  (reserve $ReserveCores for Windows)"
Write-Host "  Max parallel:     $maxParallel"
Write-Host "  Cores per job:    $coresPerJob"
Write-Host "  Scans found:      $participants"
Write-Host "  Runs/scan:        $RunsPerParticipant"
Write-Host "  Total runs:       $totalRuns"
Write-Host "  Est. time:        ~$estHours hrs"
Write-Host ""

# .wslconfig handling
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$wslConfigContent = "[wsl2]`nmemory=${wslRAM_GB}GB`nswap=${wslSwap_GB}GB`nprocessors=$wslCores`nlocalhostForwarding=true"

Write-Host "WSL2 config ($wslConfigPath):" -ForegroundColor Yellow
Write-Host $wslConfigContent
Write-Host ""

if ($DryRun) {
    Write-Host "=== DRY RUN - no changes made ===" -ForegroundColor Magenta
    exit 0
}

$needsRestart = $false
$currentConfig = if (Test-Path $wslConfigPath) { Get-Content $wslConfigPath -Raw } else { "" }
if ($currentConfig.Trim() -ne $wslConfigContent.Trim()) {
    if (Test-Path $wslConfigPath) {
        Copy-Item $wslConfigPath "$wslConfigPath.bak" -Force
        Write-Host "  Backed up existing .wslconfig to .wslconfig.bak"
    }
    $wslConfigContent | Out-File -FilePath $wslConfigPath -Encoding utf8 -NoNewline
    Write-Host "  Written new .wslconfig" -ForegroundColor Green
    $needsRestart = $true
} else {
    Write-Host ".wslconfig already matches - no restart needed." -ForegroundColor Green
}

if ($needsRestart) {
    $confirm = Read-Host "WSL2 needs restart for new memory settings. Restart now? (y/n) - batch proceeds either way, watchdog handles memory pressure"
    if ($confirm -ieq 'y') {
        Write-Host "Restarting WSL2..."
        wsl --shutdown
        Start-Sleep -Seconds 3
        Write-Host "WSL2 restarted." -ForegroundColor Green
    } else {
        # Check current WSL RAM and degrade if insufficient
        $wslMemLine = (wsl free -m 2>$null) | Where-Object { $_ -match '^Mem:' } | Select-Object -First 1
        if ($wslMemLine) {
            $currentWSLRAM_GB = [math]::Floor([int]($wslMemLine -split '\s+')[1] / 1024)
        } else {
            $currentWSLRAM_GB = $wslCurrentRAM_GB
        }
        if ($currentWSLRAM_GB -ge $wslRAM_GB) {
            Write-Host "Current WSL RAM: ${currentWSLRAM_GB}GB - sufficient, proceeding normally." -ForegroundColor Green
        } else {
            $degradedParallel = [math]::Max([math]::Floor($currentWSLRAM_GB / 4), 1)
            Write-Host "WARNING: Current WSL RAM: ${currentWSLRAM_GB}GB, need ${wslRAM_GB}GB for $maxParallel parallel jobs." -ForegroundColor Yellow
            Write-Host "  Proceeding with $degradedParallel parallel job(s) instead." -ForegroundColor Yellow
            $maxParallel = $degradedParallel
            $coresPerJob = [math]::Max([math]::Floor($wslCores / $maxParallel), 1)
        }
    }
}

# WSL path conversion: C:\Users\tcher\Desktop\dry -> /mnt/c/Users/tcher/Desktop/dry
function ConvertTo-WslPath([string]$winPath) {
    $p = $winPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)') {
        return '/mnt/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $p
}

$wslDataDir     = ConvertTo-WslPath $DataDir
$wslDesktopPath = ConvertTo-WslPath "$env:USERPROFILE\Desktop"

Write-Host ""
Write-Host "Launching batch in WSL2..." -ForegroundColor Green
Write-Host "  Data:     $wslDataDir"
Write-Host "  Parallel: $maxParallel"
Write-Host "  Cores:    $coresPerJob"
Write-Host "  Runs:     $RunsPerParticipant"
Write-Host "  Region:   $Region"
Write-Host ""

$orchestrator = "~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh"
$wslArgs = @($orchestrator, $wslDataDir,
    "--parallel", "$maxParallel", "--cores-per-job", "$coresPerJob",
    "--runs", "$RunsPerParticipant", "--region", "$Region",
    "--cleanup", "$Cleanup",
    "--stage-to", "$wslDesktopPath/vessel_particles")

wsl bash @wslArgs

Write-Host ""
Write-Host "Batch complete." -ForegroundColor Green

# Offer to restore .wslconfig
if ($needsRestart -and (Test-Path "$wslConfigPath.bak")) {
    $restore = Read-Host "Restore previous .wslconfig? (y/n)"
    if ($restore -ieq 'y') {
        Copy-Item "$wslConfigPath.bak" $wslConfigPath -Force
        Write-Host "Restored .wslconfig. Restart WSL2 to apply." -ForegroundColor Yellow
    }
}
