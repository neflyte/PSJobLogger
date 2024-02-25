#requires -modules PSJobLogger
[CmdletBinding()]
param(
    [String]$Directory = $PWD,
    [String]$Logfile,
    [int]$Threads = 4
)
if ($Threads -lt 1) {
    Write-Error 'must use at least one thread'
    exit
}
if ($Directory -eq '' -or -not(Test-Path $Directory)) {
    Write-Error 'must specify a valid directory'
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
foreach ($mp3File in $mp3Files) {
    $filesToProcess += @{
        Id = $counter
        Name = $mp3File.Name
        FullName = $mp3File.FullName
    }
    $counter++
}
Write-Output "Processing $($filesToProcess.Count) files using ${Threads} threads"
# $mp3gainDefaultArgs = '-e', '-r', '-c', '-k'
$mp3gainDefaultArgs = '-e', '-r', '-c', '-k', '-s', 'r'
# $jobLog = Initialize-PSJobLoggerDict -Name 'Process-Mp3Files' -Logfile $Logfile -ProgressParentId 0 -EstimatedThreads $Threads
$jobLog = Initialize-PSJobLogger -Name 'Process-Mp3Files' -Logfile $Logfile -ProgressParentId 0 -EstimatedThreads $Threads
$dictLog = $jobLog.asDictLogger()
Write-Progress -Id 0 -Activity 'Processing' -Status 'Starting jobs'
$job = $filesToProcess | ForEach-Object -ThrottleLimit $Threads -AsJob -Parallel {
    Import-Module (Join-Path -Path $using:PSScriptRoot -ChildPath '..' -AdditionalChildPath 'PSJobLogger') -Force
    $DebugPreference = $using:DebugPreference
    $VerbosePreference = $using:VerbosePreference

    # $log = $using:jobLog
    $log = ConvertFrom-DictLogger -DictLogger $using:dictLog
    $mp3gainDefaultArgs = $using:mp3gainDefaultArgs

    function parseMp3gainOutput {
        [CmdletBinding()]
        param([Hashtable]$Data)
        if ($Data.Message -match '([0-9]+)% of ([0-9]+) bytes analyzed') {
            # Write-LogProgress -LogDict $Log -Id $FullName -ArgumentMap @{
            #     Id = $ProgressId
            #     Activity = $Name
            #     PercentComplete = [int]$Matches[1]
            #     Status = "Analyzing $($Matches[2]) bytes"
            # }
            $Data.Log.Progress($Data.FullName, @{
                Id = $Data.ProgressId
                Activity = $Data.Name
                PercentComplete = [int]$Matches[1]
                Status = "Analyzing $($Matches[2]) bytes"
            })
        }
    }

    $id = $_.Id
    $name = $_.Name
    $fullName = $_.FullName
    $mp3gainArgs = @() + $mp3gainDefaultArgs + @($fullName)
    # Write-LogDebug -LogDict $log -Message "mp3gain ${mp3gainArgs} 2>&1"
    $log.Debug("mp3gain ${mp3gainArgs} 2>&1")
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        mp3gain $mp3gainArgs 2>&1 | ForEach-Object {
            parseMp3gainOutput(@{
                Log = $log
                ProgressId = $id
                Name = $name
                FullName = $fullName
                Message = $_
            })
        }
        if ($LASTEXITCODE -ne 0) {
            # Write-LogError -LogDict $log "mp3gain exited with code ${LASTEXITCODE}"
            # Write-LogProgress -LogDict $log -Id $fullName -ArgumentMap @{
            #     Id = $id
            #     Activity = $name
            #     PercentComplete = 100
            #     Status = 'ERROR'
            # }
            $log.Error("mp3gain exited with code ${LASTEXITCODE}")
            $log.Progress($fullName, @{
                Id = $id
                Activity = $name
                PercentComplete = 100
                Status = 'ERROR'
            })
        }
    } finally {
        # Write-LogProgress -LogDict $log -Id $fullName -ArgumentMap @{ Completed = $true }
        $log.Progress($fullName, @{ Completed = $true })
    }
}
while ($job.State -eq 'Running') {
    # show progress of jobs
    $childJobCount = $job.ChildJobs.Count
    if ($childJobCount -gt 0) {
        $finishedJobs = $job.ChildJobs.Where{ $_.State -eq 'Completed' }
        $finishedJobCount = $finishedJobs.Count
        Write-Progress -Id 0 -Activity 'Processing' -Status "${finishedJobCount}/${childJobCount} files" -PercentComplete (($finishedJobCount / $childJobCount) * 100)
    }
    # flush progress stream
    # Show-LogProgress -LogDict $jobLog
    $jobLog.FlushProgressStream()
    # small sleep to not overload the ui
    Start-Sleep -Seconds 0.1
}
# show job output
Write-Output "Job output:"
Receive-Job -Job $job -Wait -AutoRemoveJob
# flush any remaining logs
# Show-LogProgress -LogDict $jobLog
$jobLog.FlushProgressStream()
# dismiss the parent progress bar
Write-Progress -Id 0 -Activity 'Processing' -Completed
Write-Output "---"
# all done.
Write-Output 'done.'
