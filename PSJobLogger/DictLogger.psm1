using module ./PSJobLogger.psm1
using namespace System.Collections
using namespace System.Collections.Concurrent

function Initialize-PSJobLoggerDict {
    [CmdletBinding()]
    [OutputType([ConcurrentDictionary[String, PSObject]])]
    param(
        [ValidateNotNull()]
        [String]$Name = 'PSJobLogger',
        [ValidateNotNull()]
        [String]$Logfile = '',
        [Switch]$UseQueues,
        [int]$ProgressParentId = -1,
        [int]$EstimatedThreads = -1
    )
    $concurrencyLevel = $EstimatedThreads
    if ($concurrencyLevel -lt 1) {
        $concurrencyLevel = [Environment]::ProcessorCount * 2
    }
    $dictElements = @{
        Name = $Name
        Logfile = $Logfile
        ShouldLogToFile = $false
        VerbosePref = $VerbosePreference
        DebugPref = $DebugPreference
        UseQueues = $UseQueues
        ProgressParentId = $ProgressParentId
        ConcurrencyLevel = $concurrencyLevel
        Streams = [ConcurrentDictionary[int, ICollection]]$null
    }
    [ConcurrentDictionary[String, PSObject]]$logDict =
        [ConcurrentDictionary[String, PSObject]]::new($concurrencyLevel, $dictElements.Count)
    $enumerator = $dictElements.GetEnumerator()
    while ($enumerator.MoveNext()) {
        if (-not($logDict.TryAdd($enumerator.Current.Key, $enumerator.Current.Value))) {
            Write-Error "could not add element $($enumerator.Current.Key) to dict"
        }
    }
    Set-Logfile -LogDict $logDict -Filename $Logfile
    $logDict.Streams = [ConcurrentDictionary[int, ICollection]]::new($concurrencyLevel, $PSJLLogStreams.Count)
    foreach ($stream in $PSJLLogStreams) {
        switch ([int]$stream) {
            ([int]([PSJLStreams]::Progress)) {
                # TODO: Find a better starting value than `5`
                if (-not($logDict.Streams.TryAdd(
                    [int]$stream,
                    [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new($concurrencyLevel, 5))
                )) {
                    Write-Error 'could not create new ConcurrentDictionary for progress stream'
                }
            }
            default {
                if ($UseQueues) {
                    if (-not($logDict.Streams.TryAdd([int]$stream, [ConcurrentQueue[String]]::new()))) {
                        Write-Error "could not create new ConcurrentQueue for $([PSJLStreams].GetEnumName($stream)) stream"
                    }
                }
            }
        }
    }
    return $logDict
}

function Set-Logfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [ValidateNotNull()]
        [String]$Filename
    )
    if ($Filename -ne '' -and -not(Test-Path $Filename)) {
        $null = New-Item $Filename -ItemType File -Force -ErrorAction 'SilentlyContinue'
        if ($Error[0]) {
            $logfileError = $Error[0]
            Write-Error "Unable to create log file ${Filename}: ${logfileError}"
            $LogDict.ShouldLogToFile = $false
            return
        }
    }
    $LogDict.Logfile = $Filename
    $LogDict.ShouldLogToFile = $LogDict.Logfile -ne ''
}

function Write-MessageToLogfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateScript(
            { $_ -ge 0 -and $_ -lt [PSJLStreams].GetEnumNames().Count },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    if ($LogDict.ShouldLogToFile) {
        Add-Content -Path $LogDict.Logfile -Value $(Format-LogMessage -LogDict $LogDict -Stream $Stream -Message $Message) -ErrorAction 'Continue'
    }
}

function Format-LogMessage {
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateScript(
            { $_ -ge 0 -and $_ -lt [PSJLStreams].GetEnumNames().Count },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    return $(Get-Date -Format FileDateUniversal -ErrorAction 'Continue'),
            "[$($LogDict.Name)]",
            "($([PSJLStreams].GetEnumName($Stream))",
            $Message -join ' '
}

function Add-LogMessageToQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateScript(
            { $_ -ge 0 -and $_ -lt [PSJLStreams].GetEnumNames().Count },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [String]$Message
    )
    # Log the message to a logfile if one is defined
    Write-MessageToLogfile -LogDict $LogDict -Stream $Stream -Message $Message
    # Add the message to the desired queue if queues are enabled
    if ($LogDict.UseQueues) {
        if ($null -ne $Message) {
            $LogDict.Streams.$Stream.Enqueue($Message)
        }
        return
    }
    # Write the message to the appropriate stream
    [List[String]]$messages = [List[String]]::new()
    $messages.Add($Message)
    Write-LogMessagesToStream -Stream $Stream -Messages $messages
}

function Write-LogOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Success)) -Message $Message
}

function Write-LogError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Error)) -Message $Message
}

function Write-LogWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Warning)) -Message $Message
}

function Write-LogVerbose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Verbose)) -Message $Message
}

function Write-LogDebug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Debug)) -Message $Message
}

function Write-LogInformation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Information)) -Message $Message
}

function Write-LogHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([int]([PSJLStreams]::Host)) -Message $Message
}

function Write-LogProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Id,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Hashtable]$ArgumentMap
    )
    [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable =
        $LogDict.Streams.$([int]([PSJLStreams]::Progress))
    [ConcurrentDictionary[String, PSObject]]$progressArgs =
        $progressTable.GetOrAdd($Id, [ConcurrentDictionary[String, PSObject]]::new())
    [PSObject]$removedValue = $null
    $enumerator = $ArgumentMap.GetEnumerator()
    while ($enumerator.MoveNext()) {
        if ($null -eq $enumerator.Current.Value -and $progressArgs.ContainsKey($enumerator.Current.Key)) {
            if (-not($progressArgs.TryRemove($enumerator.Current.Key, [ref]$removedValue))) {
                Write-Error "could not remove key $($enumerator.Current.Key) from progress arg map"
            }
            continue
        }
        $progressArgs.$($enumerator.Current.Key) = $enumerator.Current.Value
    }
    $progressParentId = $LogDict.GetOrAdd('ProgressParentId', -1)
    if ($progressParentId -ge 0) {
        if ($progressArgs.ContainsKey('ParentId')) {
            $progressArgs.ParentId = $progressParentId
        } else {
            $null = $progressArgs.TryAdd('ParentId', $progressParentId)
        }
    }
}

function Show-LogProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict
    )
    [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressQueue =
        $LogDict.Streams.$([int]([PSJLStreams]::Progress))
    # write progress records
    [ConcurrentDictionary[String, PSObject]]$removed = $null
    $completed = $false
    $enumerator = $progressQueue.GetEnumerator()
    while ($enumerator.MoveNext()) {
        if ($null -eq $enumerator.Current.Value) {
            Write-Warning "no queue record for $($enumerator.Current.Key); skipping it"
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
                Write-Error "failed to remove progress stream record $($enumerator.Current.Key)"
            }
        }
    }
}

function Show-LogFromOneStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateScript(
            { $_ -ge 0 -and $_ -lt [PSJLStreams].GetEnumNames().Count },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream
    )
    if ($Stream -eq [int]([PSJLStreams]::Progress)) {
        Show-LogProgress -LogDict $LogDict
        return
    }
    if (-not($LogDict.UseQueues)) {
        return
    }
    [List[String]]$messages = [List[String]]::new()
    [ConcurrentQueue[String]]$messageQueue = $LogDict.Streams.$Stream
    $dequeuedMessage = ''
    while ($messageQueue.Count -gt 0) {
        if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
            Write-Error "unable to dequeue message from $([PSJLStreams].GetEnumName($Stream)); queue count = $($messageQueue.Count)"
            break
        }
        $messages.Add($dequeuedMessage)
    }
    # write messages to the desired stream
    Write-LogMessagesToStream -Stream $Stream -Messages $messages
}

function Show-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict
    )
    foreach ($stream in $PSJLLogStreams) {
        Show-LogFromOneStream -LogDict $LogDict -Stream [int]$stream
    }
}

function Show-PlainTextLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict
    )
    foreach ($stream in $PSJLPlainTextLogStreams) {
        Show-LogFromOneStream -LogDict $LogDict -Stream [int]$stream
    }
}

function Write-LogMessagesToStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript(
            { $_ -ge 0 -and $_ -lt [PSJLStreams].GetEnumNames().Count },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [List[String]]$Messages
    )
    foreach ($message in $Messages) {
        $formattedMessage = Format-LogMessage -LogDict $LogDict -Stream $Stream -Message $Message
        switch ($Stream) {
            ([int]([PSJLStreams]::Success)) {
                Write-Output -InputObject $formattedMessage -ErrorAction 'Continue'
            }
            ([int]([PSJLStreams]::Error)) {
                Write-Error -Message $formattedMessage
            }
            ([int]([PSJLStreams]::Warning)) {
                Write-Warning -Message $formattedMessage -ErrorAction 'Continue'
            }
            ([int]([PSJLStreams]::Verbose)) {
                $VerbosePreference = $LogDict.VerbosePref
                Write-Verbose -Message $formattedMessage -ErrorAction 'Continue'
            }
            ([int]([PSJLStreams]::Debug)) {
                $DebugPreference = $LogDict.DebugPref
                Write-Debug -Message $formattedMessage -ErrorAction 'Continue'
            }
            ([int]([PSJLStreams]::Information)) {
                Write-Information -MessageData $formattedMessage -ErrorAction 'Continue'
            }
            ([int]([PSJLStreams]::Host)) {
                $formattedMessage | Out-Host -ErrorAction 'Continue'
            }
            ([int]([PSJLStreams]::Progress)) {
                # The Progress stream is handled in a different function
                Write-Error "unexpected [PSJLStreams]::Progress stream; message: ${formattedMessage}"
            }
            default {
                Write-Error "unexpected stream $([PSJLStreams].GetEnumName($Stream)); message: ${formattedMessage}"
            }
        }
    }
}
