using module '../PSJobLogger'
using namespace System.Collections.Concurrent

InModuleScope PSJobLogger {
    Describe 'PSJobLogger' {
        BeforeAll {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '')]
            $LoggerName = 'PSJobLogger-test'
        }

        BeforeEach {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '')]
            $logger = [PSJobLogger]::new($LoggerName, '', $true)
        }

        Context 'constructor' {
            It 'initializes correctly' {
                $logger | Should -Not -BeNullOrEmpty
                $logger.Name | Should -BeExactly $LoggerName
                $logger.Prefix | Should -BeExactly "${LoggerName}: "
                $logger.Initialized | Should -BeTrue
                $logger.UseQueues | Should -BeTrue
                $logger.MessageTables.Keys.Count | Should -Be $([PSJobLogger]::LogStreams).Count
                $logger.MessageTables.Keys | ForEach-Object {
                    if ($_ -eq [PSJobLogger]::StreamProgress) {
                        [ConcurrentDictionary[String, PSObject]]$progressTable = $logger.MessageTables.$_
                        $progressTable.Count | Should -Be 0
                        continue
                    }
                    [ConcurrentQueue[String]]$messageTable = $logger.MessageTables.$_
                    $messageTable.Keys.Count | Should -Be 0
                }
            }
        }

        Context 'Progress' {
            It 'adds a new map' {
                $logger.Progress('foo', @{ Id = 1; Activity = 'bar' })
                $progressTable = $logger.MessageTables.$([PSJobLogger]::StreamProgress)
                $progressTable.Keys.Count | Should -Be 1
                $progressTable.Keys[0]| Should -Be 'foo'
                $progressArgs = $progressTable.foo
                $progressArgs.Keys.Count | Should -Be 2
                $progressArgs.Id | Should -Be 1
                $progressArgs.Activity | Should -Be 'bar'
            }
            It 'updates a map' {
                $progressTable = $logger.MessageTables.$([PSJobLogger]::StreamProgress)
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
                $progressArgs.PercentComplete | Should -Be $null
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
                $successTable = $logger.MessageTables.$([PSJobLogger]::StreamSuccess)
                $successTable.Count | Should -Be 0
                $logger.Output('foo')
                $successTable.Count | Should -Be 1
                $successTable[0] | Should -Be 'foo'
            }
            It 'flushes' {
                $successTable = $logger.MessageTables.$([PSJobLogger]::StreamSuccess)
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
