#requires -modules InvokeBuild
task Clean {
    Remove-Item PSJobLogger/PSJobLogger.psd1 -Force -ErrorAction SilentlyContinue
}

task Lint {
    Invoke-ScriptAnalyzer -Path ./PSJobLogger -Settings ./PSScriptAnalyzerSettings.psd1
}

task Test {
    Invoke-Pester
}

task Install-Dependencies {
    @('Pester','PSScriptAnalyzer') | ForEach-Object {
        Install-Module $_ -Force
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
        ModuleVersion = '0.4.0'
        Description = 'A logging class suitable for use with ForEach-Object -Parallel -AsJob'
        PowerShellVersion = '5.0'
        ScriptsToProcess = 'DictLogger.ps1'
        FunctionsToExport = @(
            'Initialize-PSJobLogger',
            'Initialize-PSJobLoggerDict',
            'Write-MessageToLogfile',
            'Add-LogMessageToQueue',
            'Write-LogOutput',
            'Write-LogError',
            'Write-LogWarning',
            'Write-LogVerbose',
            'Write-LogDebug',
            'Write-LogInformation',
            'Write-LogProgress',
            'Show-LogProgress',
            'Show-LogFromOneStream',
            'Show-Log',
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
            'PSJobLoggerStreamProgress',
            'PSJobLoggerLogStreams'
        )
        FileList = 'PSJobLogger.psd1','PSJobLogger.psm1', 'DictLogger.ps1'
        Tags = 'ForEach-Object','Parallel','AsJob','Logging','PSEdition_Core','Windows','Linux','MacOS'
        ProjectUri = 'https://github.com/neflyte/PSJobLogger'
        LicenseUri = 'https://github.com/neflyte/PSJobLogger/blob/main/LICENSE'
        ReleaseNotes = 'https://github.com/neflyte/PSJobLogger/blob/main/CHANGELOG.md'
    }
    $null = New-ModuleManifest @manifestArgs
}

task Mp3test {
    Remove-Item ./hack/test.log -Force -ErrorAction SilentlyContinue
    Remove-Module PSJobLogger -Force -ErrorAction SilentlyContinue
    Import-Module ./PSJobLogger -Force
    ./hack/Process-Mp3Files.ps1 -Directory $HOME/Music -Logfile ./hack/test.log
}
