[CmdletBinding()]
param(
    [String]$Directory = $PWD,
    [String]$Logfile,
    [int]$Threads = 4
)
Import-Module '../PSJobLogger' -Force
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
$jobLog = Initialize-PSJobLogger -Name 'Process-Mp3Files' -Logfile $Logfile
$job = $filesToProcess | ForEach-Object -ThrottleLimit $Threads -AsJob -Parallel {
    $log = $using:jobLog

    $id = $_.Id
    $name = $_.Name
    $fullName = $_.FullName
    $mp3gainArgs = @('-e', '-r', '-c', '-k', $fullName)
    Write-Debug "mp3gain ${mp3gainArgs} 2>&1"
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        mp3gain $mp3gainArgs 2>&1 | ForEach-Object {
            if ($_ -match '([0-9]+)% of ([0-9]+) bytes analyzed') {
                $log.Progress($fullName, @{ 
                    Id = $id
                    Activity = $name
                    PercentComplete = [int]$Matches[1]
                    Status = "Analyzing $($Matches[2]) bytes"
                })
            }
        }
    } catch {
        throw $_
    } finally {
        $log.Progress($fullName, @{ Completed = $true })
    }
}
while ($job.State -eq 'Running') {
    # show progress of jobs
    $childJobCount = $job.ChildJobs.Count
    $finishedJobs = ($job.ChildJobs | Where-Object State -EQ 'Completed').Count
    Write-Progress -Id 0 -Activity 'Processing' -Status "${finishedJobs}/${childJobCount} files" -PercentComplete (($finishedJobs / $childJobCount) * 100)
    # flush progress stream
    $jobLog.FlushProgressStream()
    # small sleep to not overload the ui
    Start-Sleep -Seconds 0.25
}
# flush any remaining logs
$jobLog.FlushProgressStream()
Write-Progress -Id 0 -Activity 'Processing' -Completed
Write-Output "Waiting for jobs to finish"
$null = $job | Wait-Job
Write-Output "Job output:"
$job | Receive-Job
Write-Output "---"
Write-Output "Cleaning up jobs"
$job | Remove-Job -Force
# all done.
Write-Output 'done.'
