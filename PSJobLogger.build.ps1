#requires -modules InvokeBuild
task Clean {
    Remove-Item PSJobLogger/PSJobLogger.psd1 -Force -ErrorAction SilentlyContinue
    Remove-Item hack/test.log -Force -ErrorAction SilentlyContinue
}

task Lint {
    Invoke-ScriptAnalyzer -Path ./PSJobLogger -Settings ./PSScriptAnalyzerSettings.psd1
}

task Test {
    Remove-Module PSJobLogger -Force -ErrorAction SilentlyContinue
    Import-Module ./PSJobLogger -Force
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
        Copyright = '(c) 2023 Alexander W Lew. All Rights Reserved.'
        CompanyName = 'Alan Lew'
        RootModule = 'PSJobLogger.psm1'
        ModuleVersion = '0.5.0'
        Description = 'A logging class suitable for use with ForEach-Object -Parallel -AsJob'
        PowerShellVersion = '5.1'
        NestedModules = @(
            'DictLogger.psm1'
        )
        FunctionsToExport = @(
            'Add-LogMessageToQueue',
            'ConvertFrom-DictLogger',
            'Format-LogMessage',
            'Initialize-PSJobLogger',
            'Initialize-PSJobLoggerDict',
            'Show-LogProgress',
            'Show-LogFromOneStream',
            'Show-Log',
            'Write-MessageToLogfile',
            'Write-LogOutput',
            'Write-LogError',
            'Write-LogWarning',
            'Write-LogVerbose',
            'Write-LogDebug',
            'Write-LogInformation',
            'Write-LogProgress',
            'Write-LogMessagesToStream'
        )
        CmdletsToExport = @()
        AliasesToExport = @()
        VariablesToExport = @(
            'PSJobLoggerStreamSuccess',
            'PSJobLoggerStreamError',
            'PSJobLoggerStreamWarning',
            'PSJobLoggerStreamVerbose',
            'PSJobLoggerStreamDebug',
            'PSJobLoggerStreamInformation',
            'PSJobLoggerStreamHost',
            'PSJobLoggerStreamProgress',
            'PSJobLoggerLogStreams'
            'PSJobLoggerPlainTextLogStreams'
        )
        FileList = 'PSJobLogger.psd1','PSJobLogger.psm1', 'DictLogger.psm1', 'en-US/about_PSJobLogger.help.txt'
        Tags = 'ForEach-Object','Parallel','AsJob','Logging','PSEdition_Core','Windows','Linux','MacOS'
        ProjectUri = 'https://github.com/neflyte/PSJobLogger'
        LicenseUri = 'https://github.com/neflyte/PSJobLogger/blob/main/LICENSE'
        ReleaseNotes = 'https://github.com/neflyte/PSJobLogger/blob/main/CHANGELOG.md'
    }
    $null = New-ModuleManifest @manifestArgs
}

task Mp3test {
    Remove-Module PSJobLogger -Force -ErrorAction SilentlyContinue
    Import-Module ./PSJobLogger -Force
    Push-Location hack
    try {
        Remove-Item test.log -Force -ErrorAction SilentlyContinue
        ./Process-Mp3Files.ps1 -Directory $HOME/Music/share -Logfile test.log
    } finally {
        Pop-Location
    }
}
