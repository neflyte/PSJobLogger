using namespace System.Collections
using namespace System.Collections.Concurrent

function Initialize-PSJobLoggerDict {
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
        Prefix = "${Name}: "
        Logfile = $Logfile
        UseQueues = $UseQueues
        ProgressParentId = $ProgressParentId
    }
    $dictElements.Keys | ForEach-Object {
        if (-not($logDict.TryAdd($_, $dictElements.$_))) {
            Write-Error "could not add element $($_) to dict"
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
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    if ($LogDict.Logfile -ne '') {
        $timestamp = Get-Date -Format FileDateTimeUniversal -ErrorAction Continue
        "${timestamp} ${Message}" | Out-File -FilePath $LogDict.Logfile -Append -ErrorAction Continue
    }
}

function Add-LogMessageToQueue {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][int]$Stream,
        [Parameter(Mandatory)][String]$Message
    )
    Write-MessageToLogfile -LogDict $LogDict -Message "$($LogDict.Prefix)$($PSJobLoggerLogStreams.$Stream): ${Message}"
    if ($LogDict.UseQueues -and $null -ne $LogDict.Streams.$Stream) {
        [ConcurrentQueue[String]]$messageQueue = $LogDict.Streams.$Stream
        $messageQueue.Enqueue($Message)
    }
    Write-LogMessagesToStream -Stream $Stream -Prefix $LogDict.Prefix -Messages @($Message)
}

function Write-LogOutput {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamSuccess -Message $Message
}

function Write-LogError {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamError -Message $Message
}

function Write-LogWarning {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamWarning -Message $Message
}

function Write-LogVerbose {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamVerbose -Message $Message
}

function Write-LogDebug {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamDebug -Message $Message
}

function Write-LogInformation {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [Parameter(Mandatory)][String]$Message
    )
    Add-LogMessageToQueue -LogDict $LogDict -Stream $PSJobLoggerStreamInformation -Message $Message
}

function Write-LogProgress {
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
    $progressParentId = $LogDict.ProgressParentId
    if ($progressParentId -ge 0) {
        if (-not($progressArgs.ContainsKey('ParentId'))) {
            $null = $progressArgs.TryAdd('ParentId', $progressParentId)
        } else {
            $progressArgs.ParentId = $progressParentId
        }
    }
}

function Show-LogProgress {
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
                Write-Error "failed to remove progress stream record ${recordKey}"
            }
        }
    }
}

function Show-LogFromOneStream {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict,
        [int]$Stream
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
        $messages += @($dequeuedMessage)
    }
    # write messages to the desired stream
    Write-LogMessagesToStream -Stream $Stream -Prefix $LogDict.Prefix -Messages $messages
}

function Show-Log {
    param(
        [Parameter(Mandatory)][ConcurrentDictionary[String, PSObject]]$LogDict
    )
    foreach ($stream in $PSJobLoggerLogStreams.Keys) {
        Show-LogFromOneStream -LogDict $LogDict -Stream $stream
    }
}

function Write-LogMessagesToStream {
    param(
        [Parameter(Mandatory)][int]$Stream,
        [Parameter(Mandatory)][String]$Prefix,
        [Parameter(Mandatory)][String[]]$Messages
    )
    $streamLabel = $PSJobLoggerLogStreams.$Stream
    foreach ($message in $Messages) {
        $messageWithPrefix = "${Prefix}${streamLabel}: ${message}"
        switch ($Stream) {
            ($PSJobLoggerStreamSuccess) {
                $null = Write-Output -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable outputError
                if ($outputError) {
                    $outputError | ForEach-Object { Write-Error $_ }
                }
            }
            ($PSJobLoggerStreamError) {
                Write-Error -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable errorstreamError
                if ($errorstreamError) {
                    $errorstreamError | ForEach-Object { Write-Error $_ }
                }
            }
            ($PSJobLoggerStreamWarning) {
                Write-Warning -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable warningError
                if ($warningError) {
                    $warningError | ForEach-Object { Write-Error $_ }
                }
            }
            ($PSJobLoggerStreamVerbose) {
                Write-Verbose -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable verboseError
                if ($verboseError) {
                    $verboseError | ForEach-Object { Write-Error $_ }
                }
            }
            ($PSJobLoggerStreamDebug) {
                Write-Debug -Message $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable debugError
                if ($debugError) {
                    $debugError | ForEach-Object { Write-Error $_ }
                }
            }
            ($PSJobLoggerStreamInformation) {
                Write-Information -MessageData $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable informationError
                if ($informationError) {
                    $informationError | ForEach-Object { Write-Error $_ }
                }
            }
            ($PSJobLoggerStreamProgress) {
                # The Progress stream is handled in a different function
            }
            default {
                Write-Error "unexpected stream ${Stream}"
            }
        }
    }
}