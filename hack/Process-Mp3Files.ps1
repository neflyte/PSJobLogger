#requires -modules PSJobLogger
[CmdletBinding()]
param(
    [String]$Directory = $PWD,
    [String]$Logfile,
    [int]$Threads = 4
)
if ($Threads -lt 1) {
    Write-Error "must use at least one thread"
    exit
}
if ($Directory -eq '' -or -not(Test-Path $Directory)) {
    Write-Error "must specify a valid directory"
    exit
}
Write-Output "Collecting MP3 files in ${Directory}"
$mp3Files = Get-ChildItem -Path $Directory -Attributes !Directory -Recurse -Filter '*.mp3'
if ($mp3Files.Length -eq 0) {
    Write-Error "no MP3 files found in ${Directory}"
    exit
}
$filesToProcess = @()
$counter = 1
$mp3Files | ForEach-Object {
    $filesToProcess += @{
        Id = $counter
        Name = $_.Name
        FullName = $_.FullName
    }
    $counter++
}
Write-Output "Processing $($filesToProcess.Count) files using ${Threads} threads"
$mp3gainDefaultArgs = @('-e', '-r', '-c', '-k')
$jobLog = Initialize-PSJobLoggerDict -Name 'Process-Mp3Files' -Logfile $Logfile
Write-Progress -Id 0 -Activity 'Processing' -Status 'Starting jobs'
$job = $filesToProcess | ForEach-Object -ThrottleLimit $Threads -AsJob -Parallel {
    Import-Module ../PSJobLogger -Force

    $log = $using:jobLog
    $mp3gainDefaultArgs = $using:mp3gainDefaultArgs
    $DebugPreference = $using:DebugPreference
    $VerbosePreference = $using:VerbosePreference

    $id = $_.Id
    $name = $_.Name
    $fullName = $_.FullName
    $mp3gainArgs = @() + $mp3gainDefaultArgs + @($fullName)
    Write-LogDebug -LogDict $log -Message "mp3gain ${mp3gainArgs} 2>&1"
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        mp3gain $mp3gainArgs 2>&1 | ForEach-Object {
            if ($_ -match '([0-9]+)% of ([0-9]+) bytes analyzed') {
                Write-LogProgress -LogDict $log -Id $fullName -ArgumentMap @{
                    Id = $id
                    Activity = $name
                    PercentComplete = [int]$Matches[1]
                    Status = "Analyzing $($Matches[2]) bytes"
                }
            }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError -LogDict $log "mp3gain exited with code ${LASTEXITCODE}"
            Write-LogProgress -LogDict $log -Id $fullName -ArgumentMap @{
                Id = $id
                Activity = $name
                PercentComplete = 100
                Status = 'ERROR'
            }
        }
    } finally {
        Write-LogProgress -LogDict $log -Id $fullName -ArgumentMap @{ Completed = $true }
    }
}
while ($job.State -eq 'Running') {
    # show progress of jobs
    $childJobCount = $job.ChildJobs.Count
    $finishedJobs = ($job.ChildJobs | Where-Object State -EQ 'Completed').Count
    Write-Progress -Id 0 -Activity 'Processing' -Status "${finishedJobs}/${childJobCount} files" -PercentComplete (($finishedJobs / $childJobCount) * 100)
    # flush progress stream
    Show-LogProgress -LogDict $jobLog
    # small sleep to not overload the ui
    Start-Sleep -Seconds 0.25
}
# flush any remaining logs
Show-LogProgress -LogDict $jobLog
# dismiss the parent progress bar
Write-Progress -Id 0 -Activity 'Processing' -Completed
# show job output
Write-Output "Job output:"
Receive-Job -Job $job -Wait -AutoRemoveJob
Write-Output "---"
# all done.
Write-Output 'done.'
