using module '../PSJobLogger/PSJobLogger.psd1'
using namespace System.Collections.Concurrent

InModuleScope PSJobLogger {
    Describe 'PSJobLogger' {
        BeforeAll {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '')]
            $LoggerName = 'PSJobLogger-test'
        }

        BeforeEach {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '')]
            $logger = [PSJobLogger]::new($LoggerName, '', $true, -1)
        }

        Context 'constructor' {
            It 'initializes correctly' {
                $logger | Should -Not -BeNullOrEmpty
                $logger.Name | Should -BeExactly $LoggerName
                $logger.Prefix | Should -BeExactly "${LoggerName}: "
                $logger.UseQueues | Should -BeTrue
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

        Context 'SetName' {
            It 'sets the logger name and updates the prefix' {
                $logger.SetName('foo')
                $logger.Name | Should -Be 'foo'
                $logger.Prefix | Should -Be 'foo: '
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
    }
}
