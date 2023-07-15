# PSJobLogger

PSJobLogger is a wrapper around a set of ConcurrentDictionary and ConcurrentQueue objects
which allow for access to logging facilities (e.g. Write-Output, Write-Debug) in a thread-safe
manner. It is implemented as a set of functions, and as PowerShell class.

Note that PowerShell classes are not thread-safe due to session affinity. PowerShell 7.4+
has a workaround for thread-safety of classes; the class version of PSJobLogger can be used
safely in that environment.

## Installation

### Install from the PowerShell Gallery

```powershell
Install-Module PSJobLogger
```

### Manual installation

Copy the `PSJobLogger` directory to your PowerShell modules directory, or create a SymbolicLink from the `PSJobLogger`
directory into your PowerShell modules directory.

## Basic usage

```powershell
Import-Module PSJobLogger -Force
# Create a list of some 'data to process'
$dataToProcess = @()
# Initialize a new logger
$jobLog = Initialize-PSJobLoggerDict -Name 'MyLogger'
# Start parallel jobs
$job = $dataToProcess | ForEach-Object -ThreadLimit 4 -AsJob -Parallel {
    Import-Module PSJobLogger -Force  # If the module is not in your $PSModulePath
    $log = $using:jobLog
    Write-LogDebug -LogDict $log -Message "Starting to process $($_.Name)"
    Write-LogProgress -LogDict $log -Id $_.Id -ArgumentMap @{ Id = $_.Id; Activity = 'My Job Name'; Status = 'Processing'; PercentComplete = 0 }
    <#
        perform some data processing tasks here
    #>
    Write-LogVerbose -LogDict $log -Message "Finished processing $($_.Name)"
    Write-LogProgress -LogDict $log -Id $_.Id -ArgumentMap @{ Completed = $true }
}
# Monitor job state and show log messages while jobs are running
while ($job.State -eq 'Running') {
    # write messages to the various output streams
    Show-Log -LogDict $jobLog
    # short sleep to not overload the UI
    Start-Sleep -Seconds 0.25
}
# Show any remaining messages
Show-Log -LogDict $jobLog
# Show the job output and clean up finshed jobs
Receive-Job -Job $job -Wait -AutoRemoveJob
```

## License

MIT
