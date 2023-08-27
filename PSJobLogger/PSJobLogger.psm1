using namespace System.Collections
using namespace System.Collections.Concurrent

$setVariableOpts = @{
    Option = 'Constant'
    Scope = 'Global'
    ErrorAction = 'SilentlyContinue'
}
Set-Variable PSJobLoggerStreamSuccess @setVariableOpts -Value ([int]0)
Set-Variable PSJobLoggerStreamError @setVariableOpts -Value ([int]1)
Set-Variable PSJobLoggerStreamWarning @setVariableOpts -Value ([int]2)
Set-Variable PSJobLoggerStreamVerbose @setVariableOpts -Value ([int]3)
Set-Variable PSJobLoggerStreamDebug @setVariableOpts -Value ([int]4)
Set-Variable PSJobLoggerStreamInformation @setVariableOpts -Value ([int]5)
Set-Variable PSJobLoggerStreamProgress @setVariableOpts -Value ([int]6)
Set-Variable PSJobLoggerLogStreams @setVariableOpts -Value @{
    $PSJobLoggerStreamSuccess = 'Success'
    $PSJobLoggerStreamError = 'Error'
    $PSJobLoggerStreamWarning = 'Warning'
    $PSJobLoggerStreamVerbose = 'Verbose'
    $PSJobLoggerStreamDebug = 'Debug'
    $PSJobLoggerStreamInformation = 'Information'
    $PSJobLoggerStreamProgress = 'Progress'
}

# Fixed by: https://github.com/PowerShell/PowerShell/pull/18138
#[NoRunspaceAffinity()]
class PSJobLogger {
    <#
    Constant values used as an output stream identifier
    #>
    static [int]$StreamSuccess = 0
    static [int]$StreamError = 1
    static [int]$StreamWarning = 2
    static [int]$StreamVerbose = 3
    static [int]$StreamDebug = 4
    static [int]$StreamInformation = 5
    static [int]$StreamProgress = 6
    <#
    A list of available output streams
    #>
    static [Hashtable]$LogStreams = @{
        [PSJobLogger]::StreamSuccess = 'Success';
        [PSJobLogger]::StreamError = 'Error';
        [PSJobLogger]::StreamWarning = 'Warning';
        [PSJobLogger]::StreamVerbose = 'Verbose';
        [PSJobLogger]::StreamDebug = 'Debug';
        [PSJobLogger]::StreamInformation = 'Information';
        [PSJobLogger]::StreamProgress = 'Progress'
    }

    # The name of the logger; used to construct a "prefix" that is prepended to each message
    [String]$Name = ''
    # A thread-safe dictionary that holds thread-safe collections for each output stream
    [ConcurrentDictionary[int, ICollection]]$Streams
    # The logger prefix string; it is prepended to each message
    [String]$Prefix = ''
    # The file in which to additionally log all messages
    [String]$Logfile = ''
    # Indicates that message queues should be used
    [Boolean]$UseQueues = $false
    # Contains the Id of the parent Progress bar
    [int]$ProgressParentId = -1

    PSJobLogger(
        [String]$Name = 'PSJobLogger',
        [String]$Logfile = '',
        [Switch]$UseQueues = $false,
        [int]$ProgressParentId = -1
    ) {
        $this.SetName($Name)
        if ($Name -eq '') {
            $this.SetName('PSJobLogger')
        }
        if ($Logfile -ne '') {
            $this.SetLogfile($Logfile)
        }
        $this.UseQueues = $UseQueues
        $this.ProgressParentId = $ProgressParentId
        $this.Streams = [ConcurrentDictionary[int, ICollection]]::new()
        foreach ($stream in [PSJobLogger]::LogStreams.Keys) {
            switch ($stream) {
                ([PSJobLogger]::StreamProgress) {
                    if (-not($this.Streams.TryAdd($stream, [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new()))) {
                        Write-Error "unable to add progress stream to stream dict"
                    }
                }
                default {
                    if ($this.UseQueues) {
                        if (-not($this.Streams.TryAdd($stream, [ConcurrentQueue[String]]::new()))) {
                            Write-Error "unable to add stream ${stream} to stream dict"
                        }
                    }
                }
            }
        }
    }

    [void]
    SetStreamsFromDictLogger([ConcurrentDictionary[String, PSObject]]$DictLogger) {
        if ($null -ne $DictLogger -and $DictLogger.ContainsKey('Streams')) {
            $this.Streams = $DictLogger.Streams
        }
    }

    [void]
    SetName([String]$Name) {
        $this.Name = $Name
        $this.Prefix = "${Name}: "
    }

    [void]
    SetLogfile([String]$Logfile) {
        if (-not(Test-Path $Logfile)) {
            $null = New-Item $Logfile -ItemType File -Force
        }
        $this.Logfile = $Logfile
    }

    [void]
    LogToFile([String]$Message) {
        if ($this.Logfile -ne '') {
            $timestamp = Get-Date -Format FileDateTimeUniversal -ErrorAction Continue
            "${timestamp} ${Message}" | Out-File -FilePath $this.Logfile -Append -ErrorAction Continue
        }
    }

    [void]
    Output([String]$Message) {
        $this.EnqueueMessage([PSJobLogger]::StreamSuccess, $Message)
    }

    [void]
    Error([String]$Message) {
        $this.EnqueueMessage([PSJobLogger]::StreamError, $Message)
    }

    [void]
    Warning([String]$Message) {
        $this.EnqueueMessage([PSJobLogger]::StreamWarning, $Message)
    }

    [void]
    Verbose([String]$Message) {
        $this.EnqueueMessage([PSJobLogger]::StreamVerbose, $Message)
    }

    [void]
    Debug([String]$Message) {
        $this.EnqueueMessage([PSJobLogger]::StreamDebug, $Message)
    }

    [void]
    Information([String]$Message) {
        $this.EnqueueMessage([PSJobLogger]::StreamInformation, $Message)
    }

    [void]
    EnqueueMessage([int]$Stream, [String]$Message) {
        # Log the message to a logfile if one is defined
        $this.LogToFile("$($this.Prefix)$([PSJobLogger]::LogStreams.$Stream): ${Message}")
        # Add the message to the desired queue if desired
        if ($this.UseQueues) {
            [ConcurrentQueue[String]]$messageQueue = $this.Streams.$Stream
            if ($null -ne $messageQueue) {
                $messageQueue.Enqueue($Message)
            }
            return
        }
        # Write the message to the appropriate stream
        $this.FlushMessages($Stream, @($Message))
    }

    [void]
    Progress([String]$Id, [Hashtable]$ArgumentMap) {
        if ($null -eq $ArgumentMap -or $ArgumentMap.Count -eq 0) {
            return
        }
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $this.Streams.$([PSJobLogger]::StreamProgress)
        if (-not($progressTable.ContainsKey($Id))) {
            if (-not($progressTable.TryAdd($Id, [ConcurrentDictionary[String, PSObject]]::new()))) {
                Write-Error "unable to add new key for ${Id}"
            }
        }
        [ConcurrentDictionary[String, PSObject]]$progressArgs = $progressTable.$Id
        foreach ($key in $ArgumentMap.Keys) {
            if ($null -eq $ArgumentMap.$key) {
                [PSObject]$removedValue = $null
                if (-not($progressArgs.TryRemove($key, [ref]$removedValue))) {
                    Write-Error "could not remove key ${key} from progress arg map"
                }
                continue
            }
            $progressArgs.$key = $ArgumentMap.$key
        }
        if ($this.ProgressParentId -ge 0) {
            if (-not($progressArgs.ContainsKey('ParentId'))) {
                $null = $progressArgs.TryAdd('ParentId', $this.ProgressParentId)
            } else {
                $progressArgs.ParentId = $this.ProgressParentId
            }
        }
    }

    [void]
    FlushStreams() {
        foreach ($stream in [PSJobLogger]::LogStreams.Keys) {
            $this.FlushOneStream($stream)
        }
    }

    [void]
    FlushProgressStream() {
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressQueue = $this.Streams.$([PSJobLogger]::StreamProgress)
        # write progress records
        foreach ($recordKey in $progressQueue.Keys) {
            if ($null -eq $progressQueue.$recordKey) {
                Write-Warning "FlushProgressStream(): no queue record for ${recordKey}; skipping it"
                continue
            }
            [ConcurrentDictionary[String, PSObject]]$progressArgs = $progressQueue.$recordKey
            if ($null -ne $progressArgs.Id -and $null -ne $progressArgs.Activity -and $progressArgs.Activity -ne '') {
                Write-Progress @progressArgs -ErrorAction 'Continue'
            }
            # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
            if ($progressArgs.GetOrAdd('Completed', $false)) {
                if (-not($progressQueue.TryRemove($recordKey, [ref]@{}))) {
                    Write-Error "FlushProgressStream(): failed to remove progress stream record ${recordKey}"
                }
            }
        }
    }

    [void]
    FlushOneStream([int]$Stream) {
        if (-not($this.Streams.ContainsKey($Stream))) {
            return
        }
        if ($null -eq $this.Streams.$Stream) {
            return
        }
        # The Progress stream is handled elsewhere since it contains a different type of data
        if ($Stream -eq [PSJobLogger]::StreamProgress) {
            $this.FlushProgressStream()
            return
        }
        # If we're not using queues then there's nothing to flush
        if (-not($this.UseQueues)) {
            return
        }
        # Drain the queue for the stream
        [String[]]$messages = @()
        [ConcurrentQueue[String]]$messageQueue = $this.Streams.$Stream
        $dequeuedMessage = ''
        while ($messageQueue.Count -gt 0) {
            if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                Write-Error "FlushOneStream(): unable to dequeue message from $([PSJobLogger]::LogStreams.$Stream); queue count = $($messageQueue.Count)"
                break
            }
            $messages += $dequeuedMessage
        }
        # write messages to the desired stream
        $this.FlushMessages($Stream, $messages)
    }

    [void]
    FlushMessages([int]$Stream, [String[]]$Messages) {
        $streamLabel = [PSJobLogger]::LogStreams.$Stream
        foreach ($message in $Messages) {
            $messageWithPrefix = "$( $this.Prefix )${streamLabel}: ${message}"
            switch ($Stream) {
                ([PSJobLogger]::StreamSuccess) {
                    $outputError = $null
                    $null = Write-Output -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable outputError
                    if ($outputError) {
                        $outputError | ForEach-Object { Write-Error $_ }
                    }
                }
                ([PSJobLogger]::StreamError) {
                    $errorstreamError = $null
                    Write-Error -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable errorstreamError
                    if ($errorstreamError) {
                        $errorstreamError | ForEach-Object { Write-Error $_ }
                    }
                }
                ([PSJobLogger]::StreamWarning) {
                    $warningError = $null
                    Write-Warning -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable warningError
                    if ($warningError) {
                        $warningError | ForEach-Object { Write-Error $_ }
                    }
                }
                ([PSJobLogger]::StreamVerbose) {
                    $verboseError = $null
                    Write-Verbose -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable verboseError
                    if ($verboseError) {
                        $verboseError | ForEach-Object { Write-Error $_ }
                    }
                }
                ([PSJobLogger]::StreamDebug) {
                    $debugError = $null
                    Write-Debug -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable debugError
                    if ($debugError) {
                        $debugError | ForEach-Object { Write-Error $_ }
                    }
                }
                ([PSJobLogger]::StreamInformation) {
                    $informationError = $null
                    Write-Information -MessageData $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable informationError
                    if ($informationError) {
                        $informationError | ForEach-Object { Write-Error $_ }
                    }
                }
                ([PSJobLogger]::StreamProgress) {
                    # This should never be reached, but it's here just in case.
                    Write-Error "reached StreamProgress in FlushMessages; this is unexpected"
                }
                default {
                    Write-Error "FlushMessages(): unexpected stream ${Stream}"
                }
            }
        }
    }

    [ConcurrentDictionary[String,PSObject]]
    asDictLogger() {
        $dictLogger = [ConcurrentDictionary[String, PSObject]]::new()
        $dictElements = @{
            Name = $this.Name
            Prefix = $this.Prefix
            Logfile = $this.Logfile
            UseQueues = $this.UseQueues
            ProgressParentId = $this.ProgressParentId
            Streams = $this.Streams
        }
        foreach ($key in $dictElements.Keys) {
            if (-not($dictLogger.TryAdd($key, $dictElements.$key))) {
                Write-Error "unable to add key ${key} to dict"
            }
        }
        return $dictLogger
    }
}


<#
.SYNOPSIS
    Return a newly-initialized PSJobLogger class
.PARAMETER Name
    The name of the logger; defaults to 'PSJobLogger'
.PARAMETER Logfile
    The path and name of a file in which to write log messages (optional)
.PARAMETER UseQueues
    Indicates that messages should be added to queues for each output stream;
    defaults to $false (optional)
.PARAMETER ProgressParentId
    The Id of the parent progress bar; defaults to -1 (optional)
.EXAMPLE
    PS> $jobLog = Initialize-PSJobLogger -Name MyLogger -Logfile messages.log -ParentProgressId 0
#>
function Initialize-PSJobLogger {
    [OutputType([PSJobLogger])]
    param(
        [String]$Name = 'PSJobLogger',
        [String]$Logfile = '',
        [Switch]$UseQueues,
        [int]$ProgressParentId = -1
    )
    return [PSJobLogger]::new($Name, $Logfile, $UseQueues, $ProgressParentId)
}

function ConvertFrom-DictLogger {
    [OutputType([PSJobLogger])]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$DictLogger
    )
    if ($null -eq $DictLogger) {
        throw 'cannot convert from a null DictLogger'
    }
    # Get initialization parameters from the DictLogger
    $name = ''
    $null = $DictLogger.TryGetValue('Name', [ref]$name)
    $logfile = ''
    $null = $DictLogger.TryGetValue('Logfile', [ref]$logfile)
    $useQueues = $false
    $null = $DictLogger.TryGetValue('UseQueues', [ref]$useQueues)
    $progressParentId = -1
    $null = $DictLogger.TryGetValue('ProgressParentId', [ref]$progressParentId)
    # Create a new PSJobLogger
    $jobLog = [PSJobLogger]::new($name, $logfile, $useQueues, $progressParentId)
    # Set the message tables to the Streams from the DictLogger
    $jobLog.SetStreamsFromDictLogger($DictLogger)
    return $jobLog
}
