[CmdletBinding()]
param(
    [String]$Directory = $PWD
)
Import-Module '../PSJobLogger' -Force
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
Write-Output "Processing $($filesToProcess.Count) files using 4 threads"
$jobLog = Initialize-PSJobLogger -Name 'Process-Mp3Files'
$job = $filesToProcess | ForEach-Object -ThrottleLimit 4 -AsJob -Parallel {
    $log = $using:jobLog

    $id = $_.Id
    $name = $_.Name
    $fullName = $_.FullName

    $log.Progress($fullName, @{ Id = $id; Activity = $name; Status = 'Processing'; PercentComplete = -1 })

    $mp3gainArgs = @('-e','-r','-c','-k' <#,'-s','r'#> ,$fullName)
    $log.Debug("mp3gain ${mp3gainArgs} 2>&1")
    mp3gain $mp3gainArgs 2>&1 | ForEach-Object {
        if ($_ -match "([0-9]+)% of ([0-9]+) bytes analyzed") {
            $log.Progress($fullName, @{ PercentComplete = [int]$Matches[1]; Status = "Analyzing $($Matches[2]) bytes" })
        }
    }

    $log.Progress($fullName, @{ Completed = $true })
}
while ($job.State -eq 'Running') {
    # flush logs
    $jobLog.FlushStreams()
    # small sleep to not overload the ui
    Start-Sleep -Seconds 0.25
}
Write-Output "Waiting for jobs to finish"
$null = Wait-Job $job.Id
Write-Output "Jobs complete."
# flush any remaining logs
$jobLog.FlushStreams()
# all done.
Write-Output 'done.'
