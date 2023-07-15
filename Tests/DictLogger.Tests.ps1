using namespace System.Collections
using namespace System.Collections.Concurrent

Describe 'DictLogger' {
    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '')]
        $loggerName = 'DictLogger-test'
    }

    BeforeEach {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '')]
        $logger = Initialize-PSJobLoggerDict -Name $loggerName -UseQueues
    }

    Context 'Initialize-PSJobLoggerDict' {
        It 'initializes correctly' {
            $logger | Should -Not -BeNullOrEmpty
            $logger.Name | Should -BeExactly $loggerName
            $logger.Prefix | Should -BeExactly "${loggerName}: "
            $logger.UseQueues | Should -BeTrue
            $logger.Streams.Keys.Count | Should -Be $PSJobLoggerLogStreams.Count
            foreach ($stream in $logger.Streams.Keys) {
                switch ($stream) {
                    $PSJobLoggerStreamProgress {
                        $progressTable = $logger.Streams.$stream
                        $progressTable.Count | Should -Be 0
                    }
                    default {
                        $messageTable = $logger.Streams.$stream
                        $messageTable.Keys.Count | Should -Be 0
                    }
                }
            }
        }
    }

    Context 'Write-LogProgress' {
        It 'adds a new map' {
            Write-LogProgress -LogDict $logger -Id 'foo' -ArgumentMap @{ Id = 1; Activity = 'bar' }
            [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $logger.Streams.$PSJobLoggerStreamProgress
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
            [ConcurrentDictionary[String, ConcurrentDictionary[String, PSObject]]]$progressTable = $logger.Streams.$PSJobLoggerStreamProgress
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
            $progressTable = $logger.Streams.$PSJobLoggerStreamProgress
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
            $progressTable = $logger.Streams.$PSJobLoggerStreamProgress
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

    Context 'Write-LogOutput' {
        It 'enqueues a message' {
            $successTable = $logger.Streams.$PSJobLoggerStreamSuccess
            $successTable.Count | Should -Be 0
            Write-LogOutput -LogDict $logger -Message 'foo'
            $successTable = $logger.Streams.$PSJobLoggerStreamSuccess
            $successTable.Count | Should -Be 1
            $successTable[0] | Should -Be 'foo'
        }
    }

}
