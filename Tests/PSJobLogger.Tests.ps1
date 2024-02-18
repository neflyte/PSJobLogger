using module ../PSJobLogger
using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.IO
Import-Module (Join-Path $PSScriptRoot 'Helpers.psm1') -Force

InModuleScope PSJobLogger {
    BeforeAll {
        $LoggerName = 'PSJobLogger-test'
    }

    Describe 'PSJobLogger' {
        BeforeEach {
            $logger = [PSJobLogger]::new($LoggerName, '', $true, -1)
        }

        Context 'constructor' {
            It 'initializes correctly' {
                $logger | Should -Not -BeNullOrEmpty
                $logger.Name | Should -BeExactly $LoggerName
                $logger.UseQueues | Should -BeTrue
                $logger.Logfile | Should -BeExactly ''
                $logger.ShouldLogToFile | Should -BeFalse
                $logger.VerbosePref | Should -BeExactly 'SilentlyContinue'
                $logger.DebugPref | Should -BeExactly 'SilentlyContinue'
                $logger.Streams.Keys.Count | Should -Be $([PSJobLogger]::LogStreams.Keys).Count
                $logger.Streams.Keys | ForEach-Object {
                    switch ($_) {
                        ([PSJobLogger]::StreamProgress) {
                            [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $logger.Streams.$_
                            $progressTable.Count | Should -Be 0
                        }
                        default {
                            [ConcurrentQueue[String]]$messageTable = $logger.Streams.$_
                            $messageTable.Keys.Count | Should -Be 0
                        }
                    }
                }
            }
        }

        Context 'Progress' {
            It 'adds a new map' {
                $logger.Progress('foo', @{ Id = 1; Activity = 'bar' })
                [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $logger.Streams.$([PSJobLogger]::StreamProgress)
                $progressTable | Should -Not -BeNullOrEmpty
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                $progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 2
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
            }
            It 'updates a map' {
                [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $logger.Streams.$([PSJobLogger]::StreamProgress)
                $progressTable | Should -Not -BeNullOrEmpty
                # write a progress entry
                $logger.Progress('foo', @{ Id = 1; Activity = 'bar'; Status = 'fnord'; PercentComplete = -1 })
                # validate it
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                $progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 4
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
                $progressArgs.Status | Should -Be 'fnord'
                $progressArgs.PercentComplete | Should -Be -1
                # update the existing map
                $logger.Progress('foo', @{ Completed = $true })
                # validate the update
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                $progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 5
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
                $progressArgs.Status | Should -Be 'fnord'
                $progressArgs.PercentComplete | Should -Be -1
                $progressArgs.Completed | Should -BeTrue
                # update the map again and remove a key
                $logger.Progress('foo', @{ PercentComplete = $null; Activity = 'zot'; Status = 'baz' })
                # validate the update
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

        Context 'Output' {
            It 'enqueues a message' {
                [ConcurrentQueue[String]]$successTable = $logger.Streams.$([PSJobLogger]::StreamSuccess)
                $successTable.Count | Should -Be 0
                $logger.Output('foo')
                $successTable.Count | Should -Be 1
                $successTable[0] | Should -Be 'foo'
            }
            It 'flushes' {
                [ConcurrentQueue[String]]$successTable = $logger.Streams.$([PSJobLogger]::StreamSuccess)
                $successTable.Count | Should -Be 0
                $logger.Output('foo')
                $successTable.Count | Should -Be 1
                $successTable[0] | Should -Be 'foo'
                $logger.FlushStreams()
                $successTable.Count | Should -Be 0
            }
        }

        Context 'FlushMessages' {
            BeforeEach {
                $logger.VerbosePref = 'Continue'
                $logger.DebugPref = 'Continue'
                $logCapture = New-TemporaryFile
            }

            AfterEach {
                Remove-Item $logCapture -Force
            }

            It 'flushes to plain text streams' {
                $logger.Output('1: LOG SUCCESS')
                $logger.Error('2: LOG ERROR')
                $logger.Warning('3: LOG WARNING')
                $logger.Verbose('4: LOG VERBOSE')
                $logger.Debug('5: LOG DEBUG')
                $logger.Information('6: LOG INFO')
                $logger.Host('6: LOG HOST')
                FlushAndCapture -JobLogger $logger -LogCapture $logCapture
                $captured = Get-Content $logCapture -Raw
                # $captured -match '1: LOG SUCCESS' | Should -BeTrue
                $captured -match '2: LOG ERROR' | Should -BeTrue
                $captured -match '3: LOG WARNING' | Should -BeTrue
                $captured -match '4: LOG VERBOSE' | Should -BeTrue
                $captured -match '5: LOG DEBUG' | Should -BeTrue
                $captured -match '6: LOG INFO' | Should -BeTrue
                $captured -match '6: LOG HOST' | Should -BeTrue
            }
        }

        # TODO: Add tests for FlushProgressStream, especially around removing keys for completed jobs

        Context 'Logfile' {
            BeforeEach {
                $logfile = New-TemporaryFile
            }
            AfterEach {
                Remove-Item $logfile -Force
            }
            It 'Writes to a log file' {
                $logger.SetLogfile($logfile)
                $logger.Output('1: LOG SUCCESS')
                $logger.Error('2: LOG ERROR')
                $logger.Warning('3: LOG WARNING')
                $logger.Verbose('4: LOG VERBOSE')
                $logger.Debug('5: LOG DEBUG')
                $logger.Information('6: LOG INFO')
                $logger.Host('6: LOG HOST')
                $logger.FlushPlainTextStreams()
                $logfileContents = Get-Content $logfile -Raw
                $logfileContents -match '1: LOG SUCCESS' | Should -BeTrue
                $logfileContents -match '2: LOG ERROR' | Should -BeTrue
                $logfileContents -match '3: LOG WARNING' | Should -BeTrue
                $logfileContents -match '4: LOG VERBOSE' | Should -BeTrue
                $logfileContents -match '5: LOG DEBUG' | Should -BeTrue
                $logfileContents -match '6: LOG INFO' | Should -BeTrue
                $logfileContents -match '6: LOG HOST' | Should -BeTrue
            }
        }

        Context 'asDictLogger' {
            It 'converts from a class' {
                $dictLogger = $logger.asDictLogger()
                $dictLogger | Should -Not -BeNullOrEmpty
                $expectedKeys = 'Name', 'Logfile', 'ShouldLogToFile', 'VerbosePref', 'DebugPref', 'UseQueues', 'ProgressParentId', 'Streams'
                foreach ($key in $expectedKeys) {
                    $dictLogger.ContainsKey($key) | Should -BeTrue
                    $dictLogger.$key | Should -Not -Be $null
                }
            }
        }

        Context 'Initialize-PSJobLogger' {
            It 'initializes' {
                $jobLogger = Initialize-PSJobLogger -Name $LoggerName -Logfile '' -UseQueues -ProgressParentId -1
                $jobLogger | Should -Not -BeNullOrEmpty
                $jobLogger.Name | Should -BeExactly $LoggerName
                $jobLogger.UseQueues | Should -BeTrue
                $jobLogger.Logfile | Should -BeExactly ''
                $jobLogger.ShouldLogToFile | Should -BeFalse
                $logger.VerbosePref | Should -BeExactly 'SilentlyContinue'
                $logger.DebugPref | Should -BeExactly 'SilentlyContinue'
                $jobLogger.Streams.Keys.Count | Should -Be $([PSJobLogger]::LogStreams.Keys).Count
                $jobLogger.Streams.Keys | ForEach-Object {
                    switch ($_) {
                        ([PSJobLogger]::StreamProgress) {
                            [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $jobLogger.Streams.$_
                            $progressTable.Count | Should -Be 0
                        }
                        default {
                            [ConcurrentQueue[String]]$messageTable = $jobLogger.Streams.$_
                            $messageTable.Keys.Count | Should -Be 0
                        }
                    }
                }
            }
        }
    }
}
