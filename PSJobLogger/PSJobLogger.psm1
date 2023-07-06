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
    static [int[]]$LogStreams = @(
        [PSJobLogger]::StreamSuccess,
        [PSJobLogger]::StreamError,
        [PSJobLogger]::StreamWarning,
        [PSJobLogger]::StreamVerbose,
        [PSJobLogger]::StreamDebug,
        [PSJobLogger]::StreamInformation,
        [PSJobLogger]::StreamProgress
    )

    # The name of the logger; used to construct a "prefix" that is prepended to each message
    [String]$Name
    # A thread-safe dictionary that holds thread-safe collections for each output stream
    [ConcurrentDictionary[int, ICollection]]$MessageTables
    # The logger prefix string; it is prepended to each message
    [String]$Prefix
    # Indicates that the class has been initialized and should not be initialized again
    [Boolean]$Initialized = $false

    PSJobLogger([String]$Name = 'PSJobLogger') {
        $this.SetName($Name)
        if ($Name -eq '') {
            $this.SetName('PSJobLogger')
        }
        $this.initializeMessageTables()
    }

    [void]
    initializeMessageTables() {
        if ($this.Initialized) {
            return
        }
        $this.MessageTables = [ConcurrentDictionary[int, ICollection]]::new()
        foreach ($stream in [PSJobLogger]::LogStreams) {
            if ($stream -eq [PSJobLogger]::StreamProgress) {
                $this.MessageTables.$stream = [ConcurrentDictionary[String, Hashtable]]::new()
                continue
            }
            $this.MessageTables.$stream = [ConcurrentQueue[String]]::new()
        }
        $this.Initialized = $true
    }

    [void]
    SetName([String]$Name) {
        $this.Name = $Name
        $this.Prefix = "${Name}: "
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
        [ConcurrentQueue[String]]$messageTable = $this.MessageTables.$Stream
        $messageTable.Enqueue($Message)
    }

    [void]
    Progress([String]$Id, [Hashtable]$ArgumentMap) {
        [ConcurrentDictionary[String, Hashtable]]$progressTable = $this.MessageTables.$([PSJobLogger]::StreamProgress)
        if ($null -eq $progressTable.$Id) {
            $progressTable.$Id = @{ }
        }
        $progressArgs = $progressTable.$Id
        foreach ($argumentKey in $ArgumentMap.Keys) {
            if ($null -eq $ArgumentMap.$argumentKey) {
                $progressArgs.Remove($argumentKey)
                continue
            }
            $progressArgs.$argumentKey = $ArgumentMap.$argumentKey
        }
    }

    [void]
    FlushStreams() {
        foreach ($stream in [PSJobLogger]::LogStreams) {
            $this.FlushOneStream($stream)
        }
    }

    [void]
    FlushProgressStream() {
        $progressRecords = @{}
        [ConcurrentDictionary[String, Hashtable]]$progressQueue = $this.MessageTables.$([PSJobLogger]::StreamProgress)
        foreach ($queueKey in $progressQueue.Keys) {
            $progressRecords.$queueKey = @{} + $progressQueue.$queueKey
        }
        # write progress records
        foreach ($recordKey in $progressRecords.Keys) {
            if ($null -eq $progressRecords.$recordKey) {
                continue
            }
            $progressArgs = $progressRecords.$recordKey
            $progressError = $null
            Write-Progress @progressArgs -ErrorAction SilentlyContinue -ErrorVariable progressError
            if ($null -ne $progressError) {
                $progressError | ForEach-Object {
                    $this.Error($($_ | Out-String))
                }
            }
            # If the arguments included `Completed = $true`, remove the key from the progress stream dictionary
            if ($null -ne $progressArgs.Completed -and [Boolean]$progressArgs.Completed) {
                $progressQueue.TryRemove($recordKey, [ref]@{})
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
        # Handle the remaining streams
        [String[]]$messages = @()
        [ConcurrentQueue[String]]$messageQueue = $this.MessageTables.$Stream
        $dequeuedMessage = ''
        while ($messageQueue.Count -gt 0) {
            if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                break
            }
            $messages += @($dequeuedMessage)
        }
        # write messages to the desired stream
        foreach ($message in $messages) {
            $messageWithPrefix = "$( $this.Prefix )${message}"
            switch ($Stream) {
                ([PSJobLogger]::StreamSuccess) {
                    $outputError = $null
                    Write-Output $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable outputError
                    if ($null -ne $outputError) {
                        $outputError | ForEach-Object {
                            $this.Error($($_ | Out-String))
                        }
                    }
                }
                ([PSJobLogger]::StreamError) {
                    $errorstreamError = $null
                    Write-Error $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable errorstreamError
                    if ($null -ne $errorstreamError) {
                        $errorstreamError | ForEach-Object {
                            Write-Error ($_ | Out-String)
                        }
                    }
                }
                ([PSJobLogger]::StreamWarning) {
                    $warningError = $null
                    Write-Warning $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable warningError
                    if ($null -ne $warningError) {
                        $warningError | ForEach-Object {
                            $this.Error($($_ | Out-String))
                        }
                    }
                }
                ([PSJobLogger]::StreamVerbose) {
                    $verboseError = $null
                    Write-Verbose $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable verboseError
                    if ($null -ne $verboseError) {
                        $verboseError | ForEach-Object {
                            $this.Error($($_ | Out-String))
                        }
                    }
                }
                ([PSJobLogger]::StreamDebug) {
                    $debugError = $null
                    Write-Debug $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable debugError
                    if ($null -ne $debugError) {
                        $debugError | ForEach-Object {
                            $this.Error($($_ | Out-String))
                        }
                    }
                }
                ([PSJobLogger]::StreamInformation) {
                    $informationError = $null
                    Write-Information $messageWithPrefix -ErrorAction SilentlyContinue -ErrorVariable informationError
                    if ($null -ne $informationError) {
                        $informationError | ForEach-Object {
                            $this.Error($($_ | Out-String))
                        }
                    }
                }
                ([PSJobLogger]::StreamProgress) {
                    # This should never be reached, but it's here just in case.
                    continue
                }
                default {
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
.EXAMPLE
    PS> $jobLog = Initialize-PSJobLogger -Name MyLogger
#>
function Initialize-PSJobLogger {
    [OutputType([PSJobLogger])]
    param(
        [String]$Name = 'PSJobLogger'
    )
    return [PSJobLogger]::new($Name)
}
