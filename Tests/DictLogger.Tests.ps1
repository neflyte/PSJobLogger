using module ../PSJobLogger
using namespace System.Collections
using namespace System.Collections.Concurrent

InModuleScope PSJobLogger {
    BeforeAll {
        $LoggerName = 'DictLogger-test'
    }
    Describe 'DictLogger' {
        BeforeEach {
            $logger = Initialize-PSJobLoggerDict -Name $LoggerName -LogFile '' -UseQueues -ProgressParentId -1 -EstimatedThreads -1
        }

        Context 'Initialize-PSJobLoggerDict' {
            It 'initializes correctly' {
                $logger | Should -Not -BeNullOrEmpty
                $logger.Name | Should -BeExactly $loggerName
                $logger.Logfile | Should -BeExactly ''
                $logger.ShouldLogToFile | Should -BeFalse
                $logger.VerbosePref | Should -BeExactly 'SilentlyContinue'
                $logger.DebugPref | Should -BeExactly 'SilentlyContinue'
                $logger.UseQueues | Should -BeTrue
                $logger.ProgressParentId | Should -BeExactly -1
                $logger.ConcurrencyLevel | Should -Be ([Environment]::ProcessorCount * 2)
                $logger.Streams | Should -Not -BeNullOrEmpty
                $logger.Streams.Keys.Count | Should -BeExactly $([PSJLStreams].GetEnumNames()).Count
                foreach ($stream in $logger.Streams.Keys) {
                    switch ($stream) {
                        $([int]([PSJLStreams]::Progress)) {
                            [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable =
                                $logger.Streams.$stream
                            $progressTable.Count | Should -BeExactly 0
                        }
                        default {
                            [ConcurrentQueue[String]]$messageTable = $logger.Streams.$stream
                            $messageTable.Keys.Count | Should -BeExactly 0
                        }
                    }
                }
            }
        }

        Context 'Write-LogProgress' {
            It 'adds a new map' {
                Write-LogProgress -LogDict $logger -Id 'foo' -ArgumentMap @{ Id = 1; Activity = 'bar' }
                [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable =
                    $logger.Streams.$([int]([PSJLStreams]::Progress))
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                [ConcurrentDictionary[String, PSObject]]$progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 2
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
            }
            It 'updates a map' {
                # write a progress entry
                Write-LogProgress -LogDict $logger -Id 'foo' -ArgumentMap @{ Id = 1; Activity = 'bar'; Status = 'fnord'; PercentComplete = -1 }
                # validate it
                [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable =
                    $logger.Streams.$([int]([PSJLStreams]::Progress))
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                [ConcurrentDictionary[String, PSObject]]$progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 4
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
                $progressArgs.Status | Should -Be 'fnord'
                $progressArgs.PercentComplete | Should -Be -1
                # update the existing map
                Write-LogProgress -LogDict $logger -Id 'foo' -ArgumentMap @{ Completed = $true }
                # validate the update
                $progressTable = $logger.Streams.$([int]([PSJLStreams]::Progress))
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                $progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 5
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
                $progressArgs.Status | Should -Be 'fnord'
                $progressArgs.PercentComplete | Should -Be -1
                $progressArgs.Completed | Should -BeTrue
                # update the map and remove a key
                Write-LogProgress -LogDict $logger -Id 'foo' -ArgumentMap @{ PercentComplete = $null; Activity = 'zot'; Status = 'baz' }
                # validate the update
                $progressTable = $logger.Streams.$([int]([PSJLStreams]::Progress))
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                $progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 4
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'zot'
                $progressArgs.Status | Should -Be 'baz'
                $progressArgs.PercentComplete | Should -BeExactly $null
                $progressArgs.Completed | Should -BeTrue
            }
        }

        Context 'Write-LogOutput' {
            It 'enqueues a message' {
                $successTable = $logger.Streams.$([int]([PSJLStreams]::Success))
                $successTable.Count | Should -BeExactly 0
                Write-LogOutput -LogDict $logger -Message 'foo'
                $successTable = $logger.Streams.$([int]([PSJLStreams]::Success))
                $successTable.Count | Should -BeExactly 1
                $successTable[0] | Should -Contain 'foo'
            }
        }

        Context 'Set-Logfile' {
            BeforeEach {
                $logfile = New-TemporaryFile
            }
            AfterEach {
                Remove-Item $logfile -Force
            }
            It 'sets the correct dict state' {
                Set-Logfile -LogDict $logger -Filename $logfile
                $logger.Logfile | Should -BeExactly $logfile.ToString()
                $logger.ShouldLogToFile | Should -BeTrue
            }
        }

        Context 'Write-MessageToLogFile' {
            BeforeEach {
                $logfile = New-TemporaryFile
            }
            AfterEach {
                Remove-Item $logfile -Force
            }
            It 'writes to the log file' {
                Set-Logfile -LogDict $logger -Filename $logfile
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamSuccess -Message '1: LOG SUCCESS'
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamError -Message '2: LOG ERROR'
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamWarning -Message '3: LOG WARNING'
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamVerbose -Message '4: LOG VERBOSE'
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamDebug -Message '5: LOG DEBUG'
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamInformation -Message '6: LOG INFO'
                Write-MessageToLogfile -LogDict $logger -Stream $PSJobLoggerStreamHost -Message '6: LOG HOST'
                $logContents = Get-Content $logfile -Raw
                $logContents | Should -Match '1: LOG SUCCESS'
                $logContents | Should -Match '2: LOG ERROR'
                $logContents | Should -Match '3: LOG WARNING'
                $logContents | Should -Match '4: LOG VERBOSE'
                $logContents | Should -Match '5: LOG DEBUG'
                $logContents | Should -Match '6: LOG INFO'
                $logContents | Should -Match '6: LOG HOST'
            }
        }
    }
}
