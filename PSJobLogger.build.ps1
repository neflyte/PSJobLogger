#requires -modules InvokeBuild
task Clean {
    Remove-Item PSJobLogger/PSJobLogger.psd1 -Force -ErrorAction SilentlyContinue
    Remove-Item hack/test.log -Force -ErrorAction SilentlyContinue
}

task Lint {
    Invoke-ScriptAnalyzer -Path (Join-Path $PWD 'PSJobLogger') -Settings ./PSScriptAnalyzerSettings.psd1
}

task Test {
    foreach ($module in 'PSJobLogger','DictLogger','PSJLStreams','PSJLLogStreams','PSJobLoggerTestHelpers') {
        if (Get-Module $module) {
            Remove-Module $module -Force -ErrorAction Continue
        }
    }
    Import-Module (Join-Path $PWD 'PSJobLogger') -Force
    Invoke-Pester
}

task Install-Dependencies {
    foreach ($module in 'Pester','PSScriptAnalyzer') {
        Install-Module $module -Scope CurrentUser -Force
    }
}

task Build-Manifest {
    $manifestArgs = @{
        Path = './PSJobLogger/PSJobLogger.psd1'
        Guid = '7f941218-c9c8-409a-9406-454b0a7116f6'
        Author = 'Alan Lew'
        Copyright = '(c) 2024 Alexander W Lew. All Rights Reserved.'
        CompanyName = 'Alan Lew'
        RootModule = 'PSJobLogger.psm1'
        ModuleVersion = '0.6.0'
        Description = 'A logging class suitable for use with ForEach-Object -Parallel -AsJob'
        PowerShellVersion = '5.1'
        NestedModules = @(
            'DictLogger.psm1',
            'PSJLLogStreams.psm1',
            'PSJLStreams.psm1'
        )
        FunctionsToExport = @(
            # PSJobLogger.psm1
            'ConvertFrom-DictLogger',
            'Initialize-PSJobLogger',
            # DictLogger.psm1
            'Add-LogMessageToQueue',
            'Format-LogMessage',
            'Initialize-PSJobLoggerDict',
            'Set-Logfile',
            'Show-Log',
            'Show-LogFromOneStream',
            'Show-LogProgress',
            'Write-LogDebug',
            'Write-LogError',
            'Write-LogInformation',
            'Write-LogMessagesToStream',
            'Write-LogOutput',
            'Write-LogProgress',
            'Write-LogVerbose',
            'Write-LogWarning',
            'Write-MessageToLogfile'
        )
        CmdletsToExport = @()
        AliasesToExport = @()
        VariablesToExport = @()
        ModuleList = 'DictLogger.psm1','PSJLStreams.psm1','PSJLLogStreams.psm1'
        FileList = 'PSJobLogger.psd1','PSJobLogger.psm1','DictLogger.psm1','PSJLStreams.psm1','PSJLLogStreams.psm1','en-US/about_PSJobLogger.help.txt'
        Tags = 'ForEach-Object','Parallel','AsJob','Logging','PSEdition_Core','Windows','Linux','MacOS'
        ProjectUri = 'https://github.com/neflyte/PSJobLogger'
        LicenseUri = 'https://github.com/neflyte/PSJobLogger/blob/main/LICENSE'
        ReleaseNotes = 'https://github.com/neflyte/PSJobLogger/blob/main/CHANGELOG.md'
    }
    $null = New-ModuleManifest @manifestArgs
}

task Mp3test {
    if (Get-Module PSJobLogger) {
        Remove-Module PSJobLogger -Force -ErrorAction SilentlyContinue
    }
    Import-Module (Join-Path $PWD 'PSJobLogger') -Force
    Push-Location hack
    try {
        Remove-Item test.log -Force -ErrorAction SilentlyContinue
        ./Process-Mp3Files.ps1 -Directory $HOME/Music/share -Logfile test.log
    } finally {
        Pop-Location
    }
}
