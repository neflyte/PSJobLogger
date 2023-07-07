using namespace System.Collections
using namespace System.Collections.Concurrent

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
    [String]$Name
    # A thread-safe dictionary that holds thread-safe collections for each output stream
    [ConcurrentDictionary[int, ICollection]]$MessageTables
    # The logger prefix string; it is prepended to each message
    [String]$Prefix
    # Indicates that the class has been initialized and should not be initialized again
    [Boolean]$Initialized = $false
    # The file in which to additionally log all messages
    [String]$Logfile

    PSJobLogger([String]$Name = 'PSJobLogger', [String]$Logfile = '') {
        $this.SetName($Name)
        if ($Name -eq '') {
            $this.SetName('PSJobLogger')
        }
        if ($Logfile -ne '') {
            $this.SetLogfile($Logfile)
        }
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
                    $this.MessageTables.$stream = [ConcurrentQueue[String]]::new()
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
            New-Item $Logfile -ItemType File -Force
        }
        $this.Logfile = $Logfile
    }

    [void]
    Logtofile([String]$Message) {
        if ($this.Logfile -ne '') {
            $timestamp = Get-Date -Format FileDateTimeUniversal
            Out-File -FilePath $this.Logfile -Append -InputObject "${timestamp} ${Message}"
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
        $($this.MessageTables.$Stream).Enqueue($Message)
    }

    [void]
    Progress([String]$Id, [Hashtable]$ArgumentMap) {
        if ($null -eq $ArgumentMap) {
            return
        }
        $argumentMapString = $ArgumentMap.Keys | ForEach-Object { "$_=($($ArgumentMap.$_))" } | Join-String -Separator ';'
        $this.Logtofile("Progress(Id=${Id}; ArgumentMap=${argumentMapString})")
        [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $this.MessageTables.$([PSJobLogger]::StreamProgress)
        if (-not($progressTable.ContainsKey($Id))) {
            $progressTable.$Id = [ConcurrentDictionary[String, PSObject]]::new()
        }
        $progressArgs = $progressTable.$Id
        foreach ($argumentKey in $ArgumentMap.Keys) {
            if ($null -eq $ArgumentMap.$argumentKey) {
                $null = $progressArgs.Remove($argumentKey)
                continue
            }
            $progressArgs.$argumentKey = $ArgumentMap.$argumentKey
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
        $this.Logtofile("+++ FlushProgressStream(): progressQueue: Keys.Count=$($progressQueue.Keys.Count)")
        # write progress records
        foreach ($recordKey in $progressQueue.Keys) {
            if ($null -eq $progressQueue.$recordKey) {
                $this.Logtofile("+++ FlushProgressStream(): no queue record for ${recordKey}; skipping it")
                continue
            }
            $progressArgs = $progressQueue.$recordKey
            $argsString = $progressArgs.Keys | ForEach-Object { "$($_)=$($progressArgs.$_)" } | Join-String -Separator ';'
            $this.Logtofile("Progress: ${recordKey} -> ${argsString}")
            if ($null -eq $progressArgs.Id -or $null -eq $progressArgs.Activity -or $progressArgs.Activity -eq '') {
                $this.Logtofile("Warning: skipping ${recordKey} because Id or Activity keys were null or missing")
                $this.Warning("skipping ${recordKey} because Id or Activity keys were null or missing")
                continue
            }
            $progressError = $null
            Write-Progress @progressArgs -ErrorAction SilentlyContinue -ErrorVariable progressError
            if ($null -ne $progressError) {
                $progressError | ForEach-Object {
                    $this.Logtofile("Error (Progress): $($_)")
                    $this.Error($_)
                }
            }
            # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
            if ($null -ne $progressArgs.Completed -and [Boolean]$progressArgs.Completed) {
                $this.Logtofile("Progress: removing progress stream record ${recordKey}")
                if (-not($progressQueue.TryRemove($recordKey, [ref]@{}))) {
                    $this.Logtofile("Error: failed to remove progress stream record ${recordKey}")
                }
            }
        }
    }

    [void]
    FlushOneStream([int]$Stream) {
        if ($null -eq $this.MessageTables.$Stream) {
            return
        }
        # The Progress stream is handled elsewhere since it is different
        if ($Stream -eq [PSJobLogger]::StreamProgress) {
            $this.FlushProgressStream()
            return
        }
        $streamLabel = [PSJobLogger]::LogStreams.$Stream
        # Handle the remaining streams
        [String[]]$messages = @()
        [ConcurrentQueue[String]]$messageQueue = $this.MessageTables.$Stream
        $dequeuedMessage = ''
        while ($messageQueue.Count -gt 0) {
            if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                $this.Logtofile("Error: unable to dequeue message from ${streamLabel}; queue count = $($messageQueue.Count)")
                $this.Error("unable to dequeue message from ${streamLabel}; queue count = $($messageQueue.Count)")
                break
            }
            $messages += @($dequeuedMessage)
        }
        $messageTimestamp = Get-Date -Format FileDateTimeUniversal
        # write messages to the desired stream
        foreach ($message in $messages) {
            $messageWithPrefix = "${messageTimestamp} $( $this.Prefix )${streamLabel}: ${message}"
            $this.Logtofile($messageWithPrefix)
            switch ($Stream) {
                ([PSJobLogger]::StreamSuccess) {
                    $outputError = $null
                    Write-Output -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable outputError
                    if ($outputError) {
                        $outputError | ForEach-Object {
                            $this.Logtofile("Error (Success): $_")
                            $this.Error($_)
                        }
                    }
                }
                ([PSJobLogger]::StreamError) {
                    $errorstreamError = $null
                    Write-Error -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable errorstreamError
                    if ($errorstreamError) {
                        $errorstreamError | ForEach-Object {
                            $this.Logtofile("Error (Error): $_")
                            $this.Error($_)
                        }
                    }
                }
                ([PSJobLogger]::StreamWarning) {
                    $warningError = $null
                    Write-Warning -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable warningError
                    if ($warningError) {
                        $warningError | ForEach-Object {
                            $this.Logtofile("Error (Warning): $_")
                            $this.Error($_)
                        }
                    }
                }
                ([PSJobLogger]::StreamVerbose) {
                    $verboseError = $null
                    Write-Verbose -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable verboseError
                    if ($verboseError) {
                        $verboseError | ForEach-Object {
                            $this.Logtofile("Error (Verbose): $_")
                            $this.Error($_)
                        }
                    }
                }
                ([PSJobLogger]::StreamDebug) {
                    $debugError = $null
                    Write-Debug -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable debugError
                    if ($debugError) {
                        $debugError | ForEach-Object {
                            $this.Logtofile("Error (Debug): $_")
                            $this.Error($_)
                        }
                    }
                }
                ([PSJobLogger]::StreamInformation) {
                    $informationError = $null
                    Write-Information -InputObject $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable informationError
                    if ($informationError) {
                        $informationError | ForEach-Object {
                            $this.Logtofile("Error (Information): $_")
                            $this.Error($_)
                        }
                    }
                }
                ([PSJobLogger]::StreamProgress) {
                    # This should never be reached, but it's here just in case.
                    continue
                }
                default {
                    $this.Logtofile("Error: $( $this.Prefix )unexpected stream ${Stream}")
                    Write-Error "$( $this.Prefix )unexpected stream ${Stream}"
                    return
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
.EXAMPLE
    PS> $jobLog = Initialize-PSJobLogger -Name MyLogger
#>
function Initialize-PSJobLogger {
    [OutputType([PSJobLogger])]
    param(
        [String]$Name = 'PSJobLogger',
        [String]$Logfile = ''
    )
    return [PSJobLogger]::new($Name, $Logfile)
}
