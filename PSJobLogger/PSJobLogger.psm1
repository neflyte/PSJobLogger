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
    FlushOneStream([int]$Stream) {
        if ($null -eq $this.MessageTables.$Stream) {
            return
        }
        $messages = @()
        # drain the queue, unless it's the Progress stream
        if ($Stream -eq [PSJobLogger]::StreamProgress) {
            [ConcurrentDictionary[String, Hashtable]]$progressQueue = $this.MessageTables.$Stream
            foreach ($queueKey in $progressQueue.Keys) {
                $messages += @($progressQueue.$queueKey)
            }
        }
        else {
            [ConcurrentQueue[String]]$messageQueue = $this.MessageTables.$Stream
            $dequeuedMessage = ''
            while ($messageQueue.Count -gt 0) {
                if (-not($messageQueue.TryDequeue([ref]$dequeuedMessage))) {
                    break
                }
                $messages += @($dequeuedMessage)
            }
        }
        # write messages to the desired stream
        foreach ($message in $messages) {
            switch ($Stream) {
                # $message is a [String] unless it's the Progress stream
                ([PSJobLogger]::StreamSuccess) {
                    Write-Output "$( $this.Prefix )${message}"
                }
                ([PSJobLogger]::StreamError) {
                    Write-Error "$( $this.Prefix )${message}"
                }
                ([PSJobLogger]::StreamWarning) {
                    Write-Warning "$( $this.Prefix )${message}"
                }
                ([PSJobLogger]::StreamVerbose) {
                    Write-Verbose "$( $this.Prefix )${message}"
                }
                ([PSJobLogger]::StreamDebug) {
                    Write-Debug "$( $this.Prefix )${message}"
                }
                ([PSJobLogger]::StreamInformation) {
                    Write-Information "$( $this.Prefix )${message}"
                }
                # $message is a [Hashtable] for the Progress stream
                ([PSJobLogger]::StreamProgress) {
                    Write-Progress @message
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
