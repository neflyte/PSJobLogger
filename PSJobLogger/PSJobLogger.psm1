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
$PSJLLogStreams = @(
    [PSJLStreams]::Success,
    [PSJLStreams]::Error,
    [PSJLStreams]::Warning,
    [PSJLStreams]::Verbose,
    [PSJLStreams]::Debug,
    [PSJLStreams]::Information,
    [PSJLStreams]::Progress,
    [PSJLStreams]::Host
)
Set-Variable @setVariableOpts -Name PSJLLogStreams -Value $PSJLLogStreams
$PSJLPlainTextLogStreams = @(
    [PSJLStreams]::Success,
    [PSJLStreams]::Error,
    [PSJLStreams]::Warning,
    [PSJLStreams]::Verbose,
    [PSJLStreams]::Debug,
    [PSJLStreams]::Information,
    [PSJLStreams]::Host
)
Set-Variable @setVariableOpts -Name PSJLPlainTextLogStreams -Value $PSJLPlainTextLogStreams

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
        [String]$Name = '',
        [String]$Logfile = '',
        [Switch]$UseQueues = $false,
        [int]$ProgressParentId = -1,
        [int]$EstimatedThreads = -1
    ) {
        if ($null -eq $Name) { throw 'Name parameter cannot be null' }
        $this.Name = $Name
        if ($Name -eq '') {
            $this.Name = 'PSJobLogger'
        }
        if ($null -eq $Logfile) { throw 'Logfile parameter cannot be null' }
        $this.SetLogfile($Logfile)
        $this.UseQueues = $UseQueues
        $this.ProgressParentId = $ProgressParentId
        $this.ConcurrencyLevel = $EstimatedThreads
        if ($this.ConcurrencyLevel -lt 1) {
            # Set the default concurrency level at half of Microsoft's default (4 * CPU count)
            $this.ConcurrencyLevel = [Environment]::ProcessorCount * 2
        }
        $this.Streams = [ConcurrentDictionary[int, ICollection]]::new($this.ConcurrencyLevel, [PSJLStreams].GetEnumNames().Count)
        foreach ($stream in [PSJLStreams].GetEnumValues()) {
            switch ([int]$stream) {
                ([int]([PSJLStreams]::Progress)) {
                    # TODO: Can we key these dictionaries on something other than String?
                    if (-not($this.Streams.TryAdd(
                        [int]$stream,
                        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new($this.ConcurrencyLevel, 0))
                    )) {
                        Write-Error 'unable to add progress stream to stream dict'
                    }
                }
                default {
                    if ($this.UseQueues -and -not($this.Streams.TryAdd([int]$stream, [ConcurrentQueue[String]]::new()))) {
                        Write-Error "unable to add stream $([PSJLStreams].GetEnumName($stream)) to stream dict"
                    }
                }
            }
        }
    }

    [boolean]
    IsValidStream([int]$Stream) {
        return $Stream -ge 0 -and $Stream -lt [PSJLStreams].GetEnumNames().Count
    }

    [void]
    SetStreamsFromDictLogger([ConcurrentDictionary[String, PSObject]]$DictLogger) {
        if ($null -ne $DictLogger -and $DictLogger.ContainsKey('Streams')) {
            $this.Streams = $DictLogger.Streams
        }
    }

    [void]
    SetLogfile([String]$Logfile = '') {
        if ($null -eq $Logfile) {
            $this.Logfile = ''
            $this.ShouldLogToFile = $false
            return
        }
        $this.Logfile = $Logfile
        if ($Logfile -ne '' -and -not(Test-Path $Logfile)) {
            $null = New-Item $Logfile -ItemType File -Force -ErrorAction 'SilentlyContinue'
            if ($Error[0]) {
                $logfileError = $Error[0]
                Write-Error "Unable to create log file ${Logfile}: ${logfileError}"
                $this.ShouldLogToFile = $false
                return
            }
        }
        $this.ShouldLogToFile = $this.Logfile -ne ''
    }

    [void]
    LogToFile([int]$Stream, [String]$Message) {
        if ($this.ShouldLogToFile) {
            Add-Content -Path $this.Logfile -Value $this.FormatLogfileMessage($Stream, $Message) -ErrorAction 'Continue'
        }
    }

    [void]
    Output([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Success), $Message)
    }

    [void]
    Error([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Error), $Message)
    }

    [void]
    Warning([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Warning), $Message)
    }

    [void]
    Verbose([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Verbose), $Message)
    }

    [void]
    Debug([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Debug), $Message)
    }

    [void]
    Information([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Information), $Message)
    }

    [void]
    Host([String]$Message) {
        $this.EnqueueMessage([int]([PSJLStreams]::Host), $Message)
    }

    [String]
    FormatLogfileMessage([int]$Stream, [String]$Message) {
        if ($null -eq $Message -or -not($this.IsValidStream($Stream))) {
            return ''
        }
        return "$(Get-Date -Format FileDateUniversal -ErrorAction SilentlyContinue)",
            "[$($this.Name)]",
            "($([PSJLStreams].GetEnumName($Stream)))",
            $Message -join ' '
    }

    [void]
    EnqueueMessage([int]$Stream, [String]$Message) {
        # Log the message to a logfile if one is defined
        $this.LogToFile($Stream, $Message)
        # Add the message to the desired queue if queues are enabled
        if ($this.UseQueues) {
            if ($null -ne $Message) {
                $this.Streams.$Stream.Enqueue($Message)
            }
            return
        }
        # Write the message to the appropriate stream
        [List[String]]$messages = [List[String]]::new()
        $messages.Add($Message)
        $this.FlushMessages($Stream, $messages)
    }

    [void]
    Progress([String]$Id, [Hashtable]$ArgumentMap) {
        if ($null -eq $Id -or $null -eq $ArgumentMap -or $ArgumentMap.Count -eq 0) {
            return
        }
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable =
            $this.Streams.$([int]([PSJLStreams]::Progress))
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
                $null = $progressArgs.TryAdd('ParentId', $this.ProgressParentId)
            }
        }
    }

    [void]
    FlushStreams() {
        foreach ($stream in $global:PSJLLogStreams) {
            $this.FlushOneStream([int]$stream)
        }
    }

    [void]
    FlushPlainTextStreams() {
        foreach ($stream in $global:PSJLPlainTextLogStreams) {
            $this.FlushOneStream([int]$stream)
        }
    }

    [void]
    FlushProgressStream() {
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressQueue =
            $this.Streams.$([int]([PSJLStreams]::Progress))
        # write progress records
        [ConcurrentDictionary[String, PSObject]]$removed = $null
        $completed = $false
        $enumerator = $progressQueue.GetEnumerator()
        while ($enumerator.MoveNext()) {
            if ($null -eq $enumerator.Current.Value) {
                Write-Warning "FlushProgressStream(): no queue record for $($enumerator.Current.Key); skipping it"
                continue
            }
            [ConcurrentDictionary[String, PSObject]]$progressArgs = $enumerator.Current.Value
            if ($null -ne $progressArgs.Id -and $null -ne $progressArgs.Activity -and $progressArgs.Activity -ne '') {
                Write-Progress @progressArgs -ErrorAction 'Continue'
            }
            # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
            $completed = $false
            if ($progressArgs.TryGetValue('Completed', [ref]$completed) -and $completed) {
                if (-not($progressQueue.TryRemove($enumerator.Current.Key, [ref]$removed))) {
                    Write-Error "FlushProgressStream(): failed to remove progress stream record $($enumerator.Current.Key)"
                }
            }
        }
    }

    [void]
    FlushOneStream([int]$Stream) {
        # If the stream is invalid then there's nothing to flush
        if (-not($this.IsValidStream($Stream))) {
            return
        }
        # The Progress stream is handled elsewhere since it contains a different type of data
        if ($Stream -eq [int]([PSJLStreams]::Progress)) {
            $this.FlushProgressStream()
            return
        }
        # If we're not using queues then there's nothing to flush
        if (-not($this.UseQueues)) {
            return
        }
        # Drain the queue for the stream
        $dequeuedMessage = ''
        [List[String]]$messages = [List[String]]::new()
        [ConcurrentQueue[String]]$messageQueue = $this.Streams.$Stream
        while ($messageQueue.Count -gt 0) {
            if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                Write-Error "FlushOneStream(): unable to dequeue message from $([PSJLStreams].GetEnumName($Stream)); queue count = $($messageQueue.Count)"
                break
            }
            $messages.Add($dequeuedMessage)
        }
        # write messages to the desired stream
        $this.FlushMessages($Stream, $messages)
    }

    [void]
    FlushMessages([int]$Stream, [List[String]]$Messages) {
        if ($null -eq $Messages -or -not($this.IsValidStream($Stream))) {
            return
        }
        foreach ($message in $Messages) {
            $formattedMessage = $this.FormatLogfileMessage($Stream, $message)
            switch ($Stream) {
                ([int]([PSJLStreams]::Success)) {
                    Write-Output $formattedMessage -ErrorAction 'Continue'
                }
                ([int]([PSJLStreams]::Error)) {
                    Write-Error -Message $formattedMessage
                }
                ([int]([PSJLStreams]::Warning)) {
                    Write-Warning -Message $formattedMessage -ErrorAction 'Continue'
                }
                ([int]([PSJLStreams]::Verbose)) {
                    $VerbosePreference = $this.VerbosePref
                    Write-Verbose -Message $formattedMessage -ErrorAction 'Continue' -Verbose
                }
                ([int]([PSJLStreams]::Debug)) {
                    $DebugPreference = $this.DebugPref
                    Write-Debug -Message $formattedMessage -ErrorAction 'Continue' -Debug
                }
                ([int]([PSJLStreams]::Information)) {
                    Write-Information -MessageData $formattedMessage -ErrorAction 'Continue'
                }
                ([int]([PSJLStreams]::Host)) {
                    Write-Host $formattedMessage -ErrorAction 'Continue'
                }
                ([int]([PSJLStreams]::Progress)) {
                    # This should never be reached, but it's here just in case.
                    Write-Error "FlushMessages(): unexpected stream [PSJLStreams]::Progress; message: ${formattedMessage}"
                }
                default {
                    Write-Error "FlushMessages(): unexpected stream $([PSJLStreams].GetEnumName($Stream)); message: ${formattedMessage}"
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
        [ValidateNotNull()]
        [String]$Name = 'PSJobLogger',
        [ValidateNotNull()]
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
