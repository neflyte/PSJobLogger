using namespace System.Collections
using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.IO

<# An enum of the available log streams #>
enum PSJLStreams {
    Success
    Error
    Warning
    Verbose
    Debug
    Information
    Progress
    Host
}

$setVariableOpts = @{
    Option = 'Constant'
    Scope = 'Global'
    ErrorAction = 'SilentlyContinue'
}
Set-Variable @setVariableOpts -Name PSJLLogStreams -Value @(
    [PSJLStreams]::Success,
    [PSJLStreams]::Error,
    [PSJLStreams]::Warning,
    [PSJLStreams]::Verbose,
    [PSJLStreams]::Debug,
    [PSJLStreams]::Information,
    [PSJLStreams]::Progress,
    [PSJLStreams]::Host
)
Set-Variable @setVariableOpts -Name PSJLPlainTextLogStreams -Value @(
    [PSJLStreams]::Success,
    [PSJLStreams]::Error,
    [PSJLStreams]::Warning,
    [PSJLStreams]::Verbose,
    [PSJLStreams]::Debug,
    [PSJLStreams]::Information,
    [PSJLStreams]::Host
)

class PSJobLogger {
    <# The name of the logger; used to construct a "prefix" that is prepended to each message #>
    [String]$Name = ''
    <# A thread-safe dictionary that holds thread-safe collections for each output stream #>
    [ConcurrentDictionary[int, ICollection]]$Streams
    <# The file in which to additionally log all messages #>
    [String]$Logfile = ''
    <# Indicates that a log file has been defined #>
    [Boolean]$ShouldLogToFile = $false
    <# Indicates that message queues should be used #>
    [Boolean]$UseQueues = $false
    <# Contains the Id of the parent Progress bar #>
    [int]$ProgressParentId = -1
    # Contains the desired value of DebugPreference when invoking Write-Debug
    [String]$DebugPref = 'SilentlyContinue'
    # Contains the desired value of VerbosePreference when invoking Write-Verbose
    [String]$VerbosePref = 'SilentlyContinue'
    # Contains the desired concurrency level for ConcurrentDictionary objects
    [int]$ConcurrencyLevel = -1

    PSJobLogger(
        [ValidateNotNull()]
        [String]$Name = '',
        [ValidateNotNull()]
        [String]$Logfile = '',
        [Switch]$UseQueues = $false,
        [int]$ProgressParentId = -1,
        [int]$EstimatedThreads = -1
    ) {
        $this.Name = $Name
        if ($Name -eq '') {
            $this.Name = 'PSJobLogger'
        }
        if ($Logfile -ne '') {
            $this.SetLogfile($Logfile)
        }
        $this.UseQueues = $UseQueues
        $this.ProgressParentId = $ProgressParentId
        $this.ConcurrencyLevel = $EstimatedThreads
        if ($this.ConcurrencyLevel -lt 1) {
            # Set the default concurrency level at half of Microsoft's default (4 * CPU count)
            $this.ConcurrencyLevel = [Environment]::ProcessorCount * 2
        }
        $this.Streams = [ConcurrentDictionary[int, ICollection]]::new($this.ConcurrencyLevel, [PSJLStreams]::GetNames().Count)
        foreach ($stream in [PSJLStreams]::GetValues()) {
            switch ($stream) {
                ([PSJLStreams]::Progress) {
                    # TODO: Can we key these dictionaries on something other than String?
                    if (-not($this.Streams.TryAdd(
                        $stream,
                        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new($this.ConcurrencyLevel, 0))
                    )) {
                        Write-Error 'unable to add progress stream to stream dict'
                    }
                }
                default {
                    if ($this.UseQueues -and -not($this.Streams.TryAdd($stream, [ConcurrentQueue[String]]::new()))) {
                        Write-Error "unable to add stream $([PSJLStreams]::GetName($stream)) to stream dict"
                    }
                }
            }
        }
    }

    [void]
    SetStreamsFromDictLogger(
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$DictLogger
    ) {
        if ($DictLogger.ContainsKey('Streams')) {
            $this.Streams = $DictLogger.Streams
        }
    }

    [void]
    SetLogfile(
        [ValidateNotNull()]
        [String]$Logfile = ''
    ) {
        if ($Logfile -ne '' -and -not(Test-Path $Logfile)) {
            New-Item $Logfile -ItemType File -Force -ErrorAction 'SilentlyContinue' | Out-Null
            if ($Error[0]) {
                $logfileError = $Error[0]
                Write-Error "Unable to create log file ${Logfile}: ${logfileError}"
                $this.ShouldLogToFile = $false
                return
            }
        }
        $this.Logfile = $Logfile
        $this.ShouldLogToFile = $this.Logfile -ne ''
    }

    [void]
    LogToFile(
        [ValidateScript(
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [ValidateNotNull()]
        [String]$Message
    ) {
        if ($this.ShouldLogToFile) {
            Add-Content -Path $this.Logfile -Value $this.FormatLogfileMessage($Stream, $Message) -ErrorAction 'Continue'
        }
    }

    [void]
    Output([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Success, $Message)
    }

    [void]
    Error([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Error, $Message)
    }

    [void]
    Warning([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Warning, $Message)
    }

    [void]
    Verbose([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Verbose, $Message)
    }

    [void]
    Debug([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Debug, $Message)
    }

    [void]
    Information([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Information, $Message)
    }

    [void]
    Host([ValidateNotNull()][String]$Message) {
        $this.EnqueueMessage([PSJLStreams]::Host, $Message)
    }

    [String]
    FormatLogfileMessage(
        [ValidateScript(
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [ValidateNotNull()]
        [String]$Message
    ) {
        return "$(Get-Date -Format FileDateUniversal -ErrorAction SilentlyContinue)",
            "[$($this.Name)]",
            "($([PSJLStreams]::GetName($Stream)))",
            $Message -join ' '
    }

    [void]
    EnqueueMessage(
        [ValidateScript(
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [ValidateNotNull()]
        [String]$Message
    ) {
        # Log the message to a logfile if one is defined
        $this.LogToFile($Stream, $Message)
        # Add the message to the desired queue if queues are enabled
        if ($this.UseQueues) {
            $this.Streams.$Stream.Enqueue($Message)
            return
        }
        # Write the message to the appropriate stream
        $this.FlushMessages($Stream, @($Message))
    }

    [void]
    Progress(
        [ValidateNotNull()]
        [String]$Id,
        [ValidateNotNull()]
        [Hashtable]$ArgumentMap
    ) {
        if ($ArgumentMap.Count -eq 0) {
            return
        }
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable =
            $this.Streams.$([PSJLStreams]::Progress)
        if (-not($progressTable.ContainsKey($Id))) {
            # TODO: Find a better starting value than `5`
            if (-not($progressTable.TryAdd($Id, [ConcurrentDictionary[String, PSObject]]::new($this.ConcurrencyLevel, 5)))) {
                Write-Error "unable to add new key for ${Id}"
                return
            }
        }
        [ConcurrentDictionary[String, PSObject]]$progressArgs = $progressTable.$Id
        [PSObject]$removedValue = $null
        $enumerator = $ArgumentMap.GetEnumerator()
        while ($enumerator.MoveNext()) {
            if ($null -eq $enumerator.Current.Value) {
                if (-not($progressArgs.TryRemove($enumerator.Current.Key, [ref]$removedValue))) {
                    Write-Error "could not remove key $($enumerator.Current.Key) from progress arg map"
                }
                continue
            }
            $progressArgs.$($enumerator.Current.Key) = $enumerator.Current.Value
        }
        if ($this.ProgressParentId -ge 0) {
            if ($progressArgs.ContainsKey('ParentId')) {
                $progressArgs.ParentId = $this.ProgressParentId
            } else {
                # TODO: is piping to Out-Null faster than assigning to $null?
                $progressArgs.TryAdd('ParentId', $this.ProgressParentId) | Out-Null
            }
        }
    }

    [void]
    FlushStreams() {
        foreach ($stream in $PSJLLogStreams) {
            $this.FlushOneStream($stream)
        }
    }

    [void]
    FlushPlainTextStreams() {
        foreach ($stream in $PSJLPlainTextLogStreams) {
            $this.FlushOneStream($stream)
        }
    }

    [void]
    FlushProgressStream() {
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressQueue =
            $this.Streams.$([PSJLStreams]::Progress)
        # write progress records
        $enumerator = $progressQueue.GetEnumerator()
        while ($enumerator.MoveNext()) {
            if ($null -eq $progressQueue.$($enumerator.Current.Key)) {
                Write-Warning "FlushProgressStream(): no queue record for $($enumerator.Current.Key); skipping it"
                continue
            }
            [ConcurrentDictionary[String, PSObject]]$progressArgs = $enumerator.Current.Value
            if ($null -ne $progressArgs.Id -and $null -ne $progressArgs.Activity -and $progressArgs.Activity -ne '') {
                Write-Progress @progressArgs -ErrorAction 'Continue'
            }
            # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
            if ($progressArgs.GetOrAdd('Completed', $false)) {
                [ConcurrentDictionary[String, PSObject]]$removed = $null
                if (-not($progressQueue.TryRemove($enumerator.Current.Key, [ref]$removed))) {
                    Write-Error "FlushProgressStream(): failed to remove progress stream record $($enumerator.Current.Key)"
                }
            }
        }
    }

    [void]
    FlushOneStream(
        [ValidateScript(
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream
    ) {
        # The Progress stream is handled elsewhere since it contains a different type of data
        if ($Stream -eq [PSJLStreams]::Progress) {
            $this.FlushProgressStream()
            return
        }
        # If we're not using queues then there's nothing to flush
        if (-not($this.UseQueues)) {
            return
        }
        # Drain the queue for the stream
        $dequeuedMessage = ''
        [String[]]$messages = @()
        [ConcurrentQueue[String]]$messageQueue = $this.Streams.$Stream
        while ($messageQueue.Count -gt 0) {
            if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                Write-Error "FlushOneStream(): unable to dequeue message from $([PSJLStreams]::GetName($Stream)); queue count = $($messageQueue.Count)"
                break
            }
            $messages += $dequeuedMessage
        }
        # write messages to the desired stream
        $this.FlushMessages($Stream, $messages)
    }

    [void]
    FlushMessages(
        [ValidateScript(
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [ValidateNotNull()]
        [String[]]$Messages
    ) {
        foreach ($message in $Messages) {
            $formattedMessage = $this.FormatLogfileMessage($Stream, $message)
            switch ($Stream) {
                ([PSJLStreams]::Success) {
                    Write-Output $formattedMessage -ErrorAction 'Continue'
                }
                ([PSJLStreams]::Error) {
                    Write-Error -Message $formattedMessage
                }
                ([PSJLStreams]::Warning) {
                    Write-Warning -Message $formattedMessage -ErrorAction 'Continue'
                }
                ([PSJLStreams]::Verbose) {
                    $VerbosePreference = $this.VerbosePref
                    Write-Verbose -Message $formattedMessage -ErrorAction 'Continue' -Verbose
                }
                ([PSJLStreams]::Debug) {
                    $DebugPreference = $this.DebugPref
                    Write-Debug -Message $formattedMessage -ErrorAction 'Continue' -Debug
                }
                ([PSJLStreams]::Information) {
                    Write-Information -MessageData $formattedMessage -ErrorAction 'Continue'
                }
                ([PSJLStreams]::Host) {
                    Write-Host $formattedMessage -ErrorAction 'Continue'
                }
                ([PSJLStreams]::Progress) {
                    # This should never be reached, but it's here just in case.
                    Write-Error "FlushMessages(): unexpected stream [PSJLStreams]::Progress; message: ${formattedMessage}"
                }
                default {
                    Write-Error "FlushMessages(): unexpected stream $([PSJLStreams]::GetName($Stream)); message: ${formattedMessage}"
                }
            }
        }
    }

    [ConcurrentDictionary[String,PSObject]]
    asDictLogger() {
        $dictElements = @{
            Name = $this.Name
            Logfile = $this.Logfile
            ShouldLogToFile = $this.ShouldLogToFile
            UseQueues = $this.UseQueues
            ProgressParentId = $this.ProgressParentId
            ConcurrencyLevel = $this.ConcurrencyLevel
            Streams = $this.Streams
            DebugPref = $this.DebugPref
            VerbosePref = $this.VerbosePref
        }
        $dictLogger = [ConcurrentDictionary[String, PSObject]]::new($this.ConcurrencyLevel, $dictElements.Count)
        $enumerator = $dictElements.GetEnumerator()
        while ($enumerator.MoveNext()) {
            if (-not($dictLogger.TryAdd($enumerator.Current.Key, $enumerator.Current.Value))) {
                Write-Error "unable to add key $($enumerator.Current.Key) to dict"
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
.PARAMETER EstimatedThreads
    The number of threads that may access ConcurrentDictionary objects used by the logger
.EXAMPLE
    PS> $jobLog = Initialize-PSJobLogger -Name MyLogger -Logfile messages.log -ParentProgressId 0
#>
function Initialize-PSJobLogger {
    [CmdletBinding()]
    [OutputType([PSJobLogger])]
    param(
        [String]$Name = 'PSJobLogger',
        [String]$Logfile = '',
        [Switch]$UseQueues,
        [int]$ProgressParentId = -1,
        [int]$EstimatedThreads = -1
    )
    $jobLogger = [PSJobLogger]::new($Name, $Logfile, $UseQueues, $ProgressParentId, $EstimatedThreads)
    $jobLogger.DebugPref = $DebugPreference
    $jobLogger.VerbosePref = $VerbosePreference
    return $jobLogger
}

function ConvertFrom-DictLogger {
    [CmdletBinding()]
    [OutputType([PSJobLogger])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$DictLogger
    )
    # Get initialization parameters from the DictLogger
    $name = ''
    $null = $DictLogger.TryGetValue('Name', [ref]$name)
    $logfile = ''
    $null = $DictLogger.TryGetValue('Logfile', [ref]$logfile)
    $useQueues = $false
    $null = $DictLogger.TryGetValue('UseQueues', [ref]$useQueues)
    $progressParentId = -1
    $null = $DictLogger.TryGetValue('ProgressParentId', [ref]$progressParentId)
    $concurrencyLevel = -1
    $null = $DictLogger.TryGetValue('ConcurrencyLevel', [ref]$concurrencyLevel)
    # Create a new PSJobLogger
    $jobLog = [PSJobLogger]::new($name, $logfile, $useQueues, $progressParentId, $concurrencyLevel)
    # Set preferences
    $debugPref = $DebugPreference
    $null = $DictLogger.TryGetValue('DebugPref', [ref]$debugPref)
    $jobLog.DebugPref = $debugPref
    $verbosePref = $VerbosePreference
    $null = $DictLogger.TryGetValue('VerbosePref', [ref]$verbosePref)
    $jobLog.VerbosePref = $verbosePref
    # Set the message tables to the Streams from the DictLogger
    $jobLog.SetStreamsFromDictLogger($DictLogger)
    return $jobLog
}
