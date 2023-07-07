[CmdletBinding()]
param(
    [String]$Directory = $PWD,
    [String]$Logfile,
    [int]$Threads = 4
)

function Logtofile {
    param(
        [String]$Logfile,
        [String]$Message
    )
    Out-File -FilePath $Logfile -Append -InputObject $Message
}

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
Write-Output "Found $($mp3Files.Count) MP3 files"
$filesToProcess = @()
$counter = 0
$mp3Files | ForEach-Object {
    $filesToProcess += @(@{
        Id = $counter
        Name = $_.Name
        FullName = $_.FullName
    })
    $counter++
}
Write-Output "Processing $($filesToProcess.Count) files using ${Threads} threads"
$jobLog = Initialize-PSJobLogger -Name 'Process-Mp3Files' -Logfile $Logfile
$job = $filesToProcess | ForEach-Object -ThrottleLimit $Threads -AsJob -Parallel {
    $log = $using:jobLog

    $id = $_.Id
    $name = $_.Name
    $fullName = $_.FullName

    $mp3gainArgs = @('-e', '-r', '-c', '-k' <#,'-s','r'#>, $fullName)
    $log.Debug("mp3gain ${mp3gainArgs} 2>&1")
    $log.Progress($fullName, @{ Id = $id; Activity = $name; Status = 'Processing'; PercentComplete = -1 })
    try {
        $log.Debug("try start ${name}")
        $ErrorActionPreference = 'SilentlyContinue'
        mp3gain $mp3gainArgs 2>&1 | ForEach-Object {
            $log.Debug("mp3gain: $($_)")
            if ($_ -match '([0-9]+)% of ([0-9]+) bytes analyzed') {
                $log.Progress($fullName, @{ PercentComplete = [int]$Matches[1]; Status = "Analyzing $($Matches[2]) bytes" })
            }
        }
        $log.Debug("LASTEXITCODE ${name}: ${LASTEXITCODE}")
        $log.Debug("try end ${name}")
    } catch {
        $log.Debug("try end ${name} ERROR: $($_)")
        $log.Error("error running mp3gain: $($_)")
    } finally {
        $log.Debug("finally ${name}")
        $log.Progress($fullName, @{ Completed = $true })
    }
    $log.Debug("DONE ${name}")
}
while ($job.State -eq 'Running') {
    # show job state
    $childJobCount = $job.ChildJobs.Count
    $finishedJobs = ($job.ChildJobs | Where-Object State -EQ 'Completed').Count
    $runningJobs = ($job.ChildJobs | Where-Object State -EQ 'Running').Count
    $pendingJobs = ($job.ChildJobs | Where-Object State -EQ 'Pending').Count
    Write-Host "child jobs: ${childJobCount}; finished=${finishedJobs}, running=${runningJobs}, pending=${pendingJobs}"
    # flush streams
    $jobLog.FlushStreams()
    # small sleep to not overload the ui
    Start-Sleep -Seconds 0.25
}
$jobLog.Output("jobs finished; job.State=$($job.State)")
Write-Output "Waiting for jobs to finish"
$job | Wait-Job | Remove-Job -Force
Write-Output "Jobs complete."
# flush any remaining logs
$jobLog.FlushStreams()
# all done.
Write-Output 'done.'
