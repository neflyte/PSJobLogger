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
    if ($Logfile -ne '' -and -not(Test-Path $Logfile)) {
        New-Item $Logfile -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
        if (-not($Error[0])) {
            $logDict.ShouldLogToFile = $true
        }
    }
    $logDict.Streams = [ConcurrentDictionary[int, ICollection]]::new($concurrencyLevel, $PSJLLogStreams.Count)
    foreach ($stream in $PSJLLogStreams) {
        switch ($stream) {
            ([PSJLStreams]::Progress) {
                # TODO: Find a better starting value than `5`
                if (-not($logDict.Streams.TryAdd(
                    $stream,
                    [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new($concurrencyLevel, 5))
                )) {
                    Write-Error 'could not create new ConcurrentDictionary for progress stream'
                }
            }
            default {
                if ($UseQueues) {
                    if (-not($logDict.Streams.TryAdd($stream, [ConcurrentQueue[String]]::new()))) {
                        Write-Error "could not create new ConcurrentQueue for $([PSJLStreams]::GetName($stream)) stream"
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
        New-Item $Filename -ItemType File -Force -ErrorAction 'SilentlyContinue' | Out-Null
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
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
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
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    return $(Get-Date -Format FileDateUniversal -ErrorAction 'Continue'),
            "[$($LogDict.Name)]",
            "($([PSJLStreams]::GetName($Stream))",
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
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Write-MessageToLogfile -LogDict $LogDict -Stream $Stream -Message $Message
    if ($LogDict.UseQueues) {
        $LogDict.Streams.$Stream.Enqueue($Message)
    }
    Write-LogMessagesToStream -Stream $Stream -Messages @($Message)
}

function Write-LogOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([PSJLStreams]::Success) -Message $Message
}

function Write-LogError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([PSJLStreams]::Error) -Message $Message
}

function Write-LogWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([PSJLStreams]::Warning) -Message $Message
}

function Write-LogVerbose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([PSJLStreams]::Verbose) -Message $Message
}

function Write-LogDebug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $([PSJLStreams]::Debug) -Message $Message
}

function Write-LogInformation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamInformation -Message $Message
}

function Write-LogHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamHost -Message $Message
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
        $LogDict.Streams.$([PSJLStreams]::Progress)
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
        if (-not($progressArgs.ContainsKey('ParentId'))) {
            $progressArgs.TryAdd('ParentId', $progressParentId) | Out-Null
        } else {
            $progressArgs.ParentId = $progressParentId
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
        $LogDict.Streams.$([PSJLStreams]::Progress)
    # write progress records
    [ConcurrentDictionary[String, PSObject]]$removed = $null
    $enumerator = $progressQueue.GetEnumerator()
    while ($enumerator.MoveNext()) {
        if ($null -eq $enumerator.Current.Value) {
            Write-Warning "no queue record for ${recordKey}; skipping it"
            continue
        }
        $progressArgs = $enumerator.Current.Value
        if ($null -ne $progressArgs.Id -and $null -ne $progressArgs.Activity -and $progressArgs.Activity -ne '') {
            Write-Progress @progressArgs -ErrorAction 'Continue'
        }
        # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
        if ($progressArgs.GetOrAdd('Completed', $false)) {
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
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream
    )
    if ($Stream -eq [PSJLStreams]::Progress) {
        Show-LogProgress -LogDict $LogDict
        return
    }
    if (-not($LogDict.UseQueues)) {
        return
    }
    [String[]]$messages = @()
    [ConcurrentQueue[String]]$messageQueue = $LogDict.Streams.$Stream
    $dequeuedMessage = ''
    while ($messageQueue.Count -gt 0) {
        if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
            Write-Error "unable to dequeue message from $([PSJLStreams]::GetName($Stream)); queue count = $($messageQueue.Count)"
            break
        }
        $messages += $dequeuedMessage
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
        Show-LogFromOneStream -LogDict $LogDict -Stream $stream
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
        Show-LogFromOneStream -LogDict $LogDict -Stream $stream
    }
}

function Write-LogMessagesToStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript(
            { $_ -lt [PSJLStreams]::GetNames().Count - 1 },
            ErrorMessage = "Stream key {0} is invalid"
        )]
        [int]$Stream,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [String[]]$Messages
    )
    foreach ($message in $Messages) {
        $formattedMessage = Format-LogMessage -LogDict $LogDict -Stream $Stream -Message $Message
        switch ($Stream) {
            ([PSJLStreams]::Success) {
                Write-Output -InputObject $formattedMessage -ErrorAction 'Continue'
            }
            ([PSJLStreams]::Error) {
                Write-Error -Message $formattedMessage
            }
            ([PSJLStreams]::Warning) {
                Write-Warning -Message $formattedMessage -ErrorAction 'Continue'
            }
            ([PSJLStreams]::Verbose) {
                $VerbosePreference = $LogDict.VerbosePref
                Write-Verbose -Message $formattedMessage -ErrorAction 'Continue'
            }
            ([PSJLStreams]::Debug) {
                $DebugPreference = $LogDict.DebugPref
                Write-Debug -Message $formattedMessage -ErrorAction 'Continue'
            }
            ([PSJLStreams]::Information) {
                Write-Information -MessageData $formattedMessage -ErrorAction 'Continue'
            }
            ([PSJLStreams]::Host) {
                $formattedMessage | Out-Host -ErrorAction 'Continue'
            }
            ([PSJLStreams]::Progress) {
                # The Progress stream is handled in a different function
                Write-Error "unexpected [PSJLStreams]::Progress stream; message: ${formattedMessage}"
            }
            default {
                Write-Error "unexpected stream ${Stream}; message: ${formattedMessage}"
            }
        }
    }
}
