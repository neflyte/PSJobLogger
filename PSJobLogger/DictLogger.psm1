using namespace System.Collections
using namespace System.Collections.Concurrent

function Initialize-PSJobLoggerDict {
    [CmdletBinding()]
    [OutputType([ConcurrentDictionary[String, PSObject]])]
    param(
        [String]$Name = 'PSJobLogger',
        [String]$Logfile = '',
        [Switch]$UseQueues,
        [int]$ProgressParentId = -1
    )
    [ConcurrentDictionary[String, PSObject]]$logDict = [ConcurrentDictionary[String, PSObject]]::new()
    $dictElements = @{
        Name = $Name
        Logfile = $Logfile
        UseQueues = $UseQueues
        ProgressParentId = $ProgressParentId
    }
    foreach ($key in $dictElements.Keys) {
        if (-not($logDict.TryAdd($key, $dictElements.$key))) {
            Write-Error "could not add element ${key} to dict"
        }
    }
    if ($Logfile -ne '') {
        if (-not(Test-Path $Logfile)) {
            $null = New-Item $Logfile -ItemType File -Force
        }
    }
    $streams = [ConcurrentDictionary[int, ICollection]]::new()
    foreach ($stream in $PSJobLoggerLogStreams.Keys) {
        switch ($stream) {
            $PSJobLoggerStreamProgress {
                if (-not($streams.TryAdd($stream, [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]::new()))) {
                    Write-Error 'could not create new ConcurrentDictionary for progress stream'
                }
            }
            default {
                if ($UseQueues) {
                    if (-not($streams.TryAdd($stream, [ConcurrentQueue[String]]::new()))) {
                        Write-Error "could not create new ConcurrentQueue for $($PSJobLoggerLogStreams.$stream) stream"
                    }
                }
            }
        }
    }
    if (-not($logDict.TryAdd('Streams', $streams))) {
        Write-Error 'could not add streams to dict'
    }
    return $logDict
}

function Write-MessageToLogfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    if ($LogDict.Logfile -ne '') {
        $Message | Out-File -FilePath $LogDict.Logfile -Append -ErrorAction Continue
    }
}

function Format-LogMessage {
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][int]$Stream,
        [Parameter(Mandatory)][String]$Message
    )
    return "$(Get-Date -Format FileDateUniversal -ErrorAction Continue) " +
            "[$($LogDict.Name)] " +
            "($($PSJobLoggerLogStreams.$Stream)) " +
            $Message
}

function Add-LogMessageToQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][int]$Stream,
        [Parameter(Mandatory)][String]$Message
    )
    Write-MessageToLogfile -LogDict $LogDict -Message $(Format-LogMessage -LogDict $LogDict -Stream $Stream -Message $Message)
    if ($LogDict.UseQueues -and $null -ne $LogDict.Streams.$Stream) {
        [ConcurrentQueue[String]]$messageQueue = $LogDict.Streams.$Stream
        $messageQueue.Enqueue($Message)
    }
    Write-LogMessagesToStream -Stream $Stream -Messages @($Message)
}

function Write-LogOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamSuccess -Message $Message
}

function Write-LogError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamError -Message $Message
}

function Write-LogWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamWarning -Message $Message
}

function Write-LogVerbose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamVerbose -Message $Message
}

function Write-LogDebug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamDebug -Message $Message
}

function Write-LogInformation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamInformation -Message $Message
}

function Write-LogProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Id,
        [Parameter(Mandatory)][Hashtable]$ArgumentMap
    )
    if ($null -eq $ArgumentMap) {
        Write-Error 'ArgumentMap cannot be null'
        return
    }
    [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $LogDict.Streams.$PSJobLoggerStreamProgress
    [ConcurrentDictionary[String, PSObject]]$progressArgs = $progressTable.GetOrAdd($Id, [ConcurrentDictionary[String, PSObject]]::new())
    foreach ($key in $ArgumentMap.Keys) {
        if ($null -eq $ArgumentMap.$key -and $progressArgs.ContainsKey($key)) {
            [PSObject]$removedValue = $null
            if (-not($progressArgs.TryRemove($key, [ref]$removedValue))) {
                Write-Error "could not remove key ${key} from progress arg map"
            }
            continue
        }
        $progressArgs.$key = $ArgumentMap.$key
    }
    $progressParentId = $LogDict.GetOrAdd('ProgressParentId', -1)
    if ($progressParentId -ge 0) {
        if (-not($progressArgs.ContainsKey('ParentId'))) {
            $null = $progressArgs.TryAdd('ParentId', $progressParentId)
        } else {
            $progressArgs.ParentId = $progressParentId
        }
    }
}

function Show-LogProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict
    )
    [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressQueue = $LogDict.Streams.$PSJobLoggerStreamProgress
    # write progress records
    foreach ($recordKey in $progressQueue.Keys) {
        if ($null -eq $progressQueue.$recordKey) {
            Write-Warning "no queue record for ${recordKey}; skipping it"
            continue
        }
        $progressArgs = $progressQueue.$recordKey
        if ($null -ne $progressArgs.Id -and $null -ne $progressArgs.Activity -and $progressArgs.Activity -ne '') {
            Write-Progress @progressArgs -ErrorAction 'Continue'
        }
        # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
        if ($progressArgs.GetOrAdd('Completed', $false)) {
            if (-not($progressQueue.TryRemove($recordKey, [ref]@{}))) {
                Write-Error "failed to remove progress stream record ${recordKey}"
            }
        }
    }
}

function Show-LogFromOneStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][int]$Stream
    )
    if ($Stream -eq $PSJobLoggerStreamProgress) {
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
            Write-Error "unable to dequeue message from $($PSJobLoggerLogStreams.$Stream); queue count = $($messageQueue.Count)"
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
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict
    )
    foreach ($stream in $PSJobLoggerLogStreams.Keys) {
        Show-LogFromOneStream -LogDict $LogDict -Stream $stream
    }
}

function Show-PlainTextLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict
    )
    foreach ($stream in $PSJobLoggerPlainTextLogStreams.Keys) {
        Show-LogFromOneStream -LogDict $LogDict -Stream $stream
    }
}

function Write-LogMessagesToStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Stream,
        [Parameter(Mandatory)][String[]]$Messages
    )
    foreach ($message in $Messages) {
        $formattedMessage = Format-LogMessage -LogDict $LogDict -Stream $Stream -Message $Message
        switch ($Stream) {
            ($PSJobLoggerStreamSuccess) {
                Write-Output -InputObject $formattedMessage -ErrorAction SilentlyContinue
                if ($Error[0]) {
                    $outputError = $Error[0]
                    Write-Error $outputError
                }
            }
            ($PSJobLoggerStreamError) {
                Write-Error -Message $formattedMessage
            }
            ($PSJobLoggerStreamWarning) {
                Write-Warning -Message $formattedMessage -ErrorAction SilentlyContinue
                if ($Error[0]) {
                    $warningError = $Error[0]
                    Write-Error $warningError
                }
            }
            ($PSJobLoggerStreamVerbose) {
                Write-Verbose -Message $formattedMessage -ErrorAction SilentlyContinue
                if ($Error[0]) {
                    $verboseError = $Error[0]
                    Write-Error $verboseError
                }
            }
            ($PSJobLoggerStreamDebug) {
                Write-Debug -Message $formattedMessage -ErrorAction SilentlyContinue
                if ($Error[0]) {
                    $debugError = $Error[0]
                    Write-Error $debugError
                }
            }
            ($PSJobLoggerStreamInformation) {
                Write-Information -MessageData $formattedMessage -ErrorAction SilentlyContinue
                if ($Error[0]) {
                    $informationError = $Error[0]
                    Write-Error $informationError
                }
            }
            ($PSJobLoggerStreamProgress) {
                # The Progress stream is handled in a different function
                Write-Error "reached PSJobLoggerStreamProgress in Write-LogMessagesToStream; this is unexpected"
            }
            default {
                Write-Error "unexpected stream ${Stream}"
            }
        }
    }
}
