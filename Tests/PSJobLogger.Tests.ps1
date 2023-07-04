using module '../PSJobLogger/PSJobLogger.psd1'
using namespace System.Collections.Concurrent

[String]$LoggerName
[PSJobLogger]$logger

InModuleScope PSJobLogger {
    Describe 'PSJobLogger' {
        BeforeAll {
            $LoggerName = 'PSJobLogger-test'
        }

        BeforeEach {
            $logger = [PSJobLogger]::new($LoggerName)
        }

        Context 'constructor' {
            It 'initializes correctly' {
                $logger | Should -Not -BeNullOrEmpty
                $logger.Name | Should -BeExactly $LoggerName
                $logger.Prefix | Should -BeExactly "${LoggerName}: "
                $logger.Initialized | Should -BeTrue
                $logger.MessageTables.Keys.Count | Should -Be $([PSJobLogger]::LogStreams).Count
                $logger.MessageTables.Keys | ForEach-Object {
                    if ($_ -eq [PSJobLogger]::StreamProgress) {
                        [ConcurrentDictionary[String, Hashtable]]$progressTable = $logger.MessageTables.$_
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
        }
    }
}