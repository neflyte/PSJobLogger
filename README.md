# PSJobLogger

PSJobLogger is a wrapper around a set of .Net `ConcurrentDictionary` and `ConcurrentQueue` objects
which allow for access to logging facilities (e.g. Write-Output, Write-Debug, Write-Progress) in
a thread-safe manner. It is implemented as a PowerShell class.

## Installation

Copy the `PSJobLogger` directory to your PowerShell modules directory, or create a SymbolicLink from the `PSJobLogger`
directory into your PowerShell modules directory.

## Basic usage

```powershell
Import-Module PSJobLogger -Force
$jobLog = Initialize-PSJobLogger -Name 'MyLogger'
$job = $dataToProcess | ForEach-Object -ThreadLimit 4 -AsJob -Parallel {
    $log = $using:jobLog
    $log.Debug("Starting to process $($_.Name)")
    $log.Progress($_.Id, @{ Id = $_.Id; Activity = 'My Job Name'; Status = 'Processing'; PercentComplete = 0 })
    <#
        perform some data processing tasks here
    #>
    $log.Verbose("Finished processing $($_.Name)")
    $log.Progress($_.Id, @{ Completed = $true })
}
while ($job.State -eq 'Running') {
    # write messages to the various output streams
    $jobLog.FlushStreams()
    # short sleep to not overload the UI
    Start-Sleep -Seconds 0.25
}
# write any remaining messages
$jobLog.FlushStreams()
```

## License

MIT
