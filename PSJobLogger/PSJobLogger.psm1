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
    [ConcurrentDictionary[int, ICollection]]$MessageTables
    # The logger prefix string; it is prepended to each message
    [String]$Prefix = ''
    # Indicates that the class has been initialized and should not be initialized again
    [Boolean]$Initialized = $false
    # The file in which to additionally log all messages
    [String]$Logfile = ''
    # Indicates that message queues should be used
    [Boolean]$UseQueues = $false

    PSJobLogger([String]$Name = 'PSJobLogger', [String]$Logfile = '', [Switch]$UseQueues = $false) {
        $this.SetName($Name)
        if ($Name -eq '') {
            $this.SetName('PSJobLogger')
        }
        if ($Logfile -ne '') {
            $this.SetLogfile($Logfile)
        }
        $this.UseQueues = $UseQueues
        $this.initializeMessageTables()
    }

    [void]
    initializeMessageTables() {
        if ($this.Initialized) {
            return
        }
        $this.MessageTables = [ConcurrentDictionary[int, ICollection]]::new()
        foreach ($stream in [PSJobLogger]::LogStreams.Keys) {
            switch ($stream) {
                ([PSJobLogger]::StreamProgress) {
                    $this.MessageTables.$stream = [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new()
                }
                default {
                    if ($this.UseQueues) {
                        $this.MessageTables.$stream = [ConcurrentQueue[String]]::new()
                    }
                }
            }
        }
        $this.Initialized = $true
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
    Logtofile([String]$Message) {
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
        $this.Logtofile("$($this.Prefix)$([PSJobLogger]::LogStreams.$Stream): ${Message}")
        # Add the message to the desired queue if desired
        if ($this.UseQueues) {
            [ConcurrentQueue[String]]$messageQueue = $this.MessageTables.$Stream
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
        if ($null -eq $ArgumentMap) {
            return
        }
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $this.MessageTables.$([PSJobLogger]::StreamProgress)
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
    }

    [void]
    FlushStreams() {
        foreach ($stream in [PSJobLogger]::LogStreams.Keys) {
            $this.FlushOneStream($stream)
        }
    }

    [void]
    FlushProgressStream() {
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressQueue = $this.MessageTables.$([PSJobLogger]::StreamProgress)
        # write progress records
        foreach ($recordKey in $progressQueue.Keys) {
            if ($null -eq $progressQueue.$recordKey) {
                Write-Warning "FlushProgressStream(): no queue record for ${recordKey}; skipping it"
                continue
            }
            $progressArgs = $progressQueue.$recordKey
            if ($null -ne $progressArgs.Id -and $null -ne $progressArgs.Activity -and $progressArgs.Activity -ne '') {
                $progressError = $null
                Write-Progress @progressArgs -ErrorAction SilentlyContinue -ErrorVariable progressError
                if ($progressError) {
                    foreach ($error in $progressError) {
                        Write-Error $error
                    }
                }
            }
            # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
            if ($null -ne $progressArgs.Completed -and [Boolean]$progressArgs.Completed) {
                if (-not($progressQueue.TryRemove($recordKey, [ref]@{}))) {
                    Write-Error "FlushProgressStream(): failed to remove progress stream record ${recordKey}"
                }
            }
        }
    }

    [void]
    FlushOneStream([int]$Stream) {
        if ($null -eq $this.MessageTables.$Stream) {
            return
        }
        # The Progress stream is handled elsewhere since it contains a different type of data
        if ($Stream -eq [PSJobLogger]::StreamProgress -and $null -ne $this.MessageTables.$Stream) {
            $this.FlushProgressStream()
            return
        }
        if (-not($this.UseQueues)) {
            return
        }
        # Drain the queue for the stream
        [String[]]$messages = @()
        [ConcurrentQueue[String]]$messageQueue = $this.MessageTables.$Stream
        $dequeuedMessage = ''
        while ($messageQueue.Count -gt 0) {
            if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                Write-Error "FlushOneStream(): unable to dequeue message from $([PSJobLogger]::LogStreams.$Stream); queue count = $($messageQueue.Count)"
                break
            }
            $messages += @($dequeuedMessage)
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
                }
                default {
                    Write-Error "FlushMessages(): unexpected stream ${Stream}"
                }
            }
        }
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
.EXAMPLE
    PS> $jobLog = Initialize-PSJobLogger -Name MyLogger -Logfile messages.log
#>
function Initialize-PSJobLogger {
    [OutputType([PSJobLogger])]
    param(
        [String]$Name = 'PSJobLogger',
        [String]$Logfile = '',
        [Switch]$UseQueues
    )
    return [PSJobLogger]::new($Name, $Logfile, $UseQueues)
}
