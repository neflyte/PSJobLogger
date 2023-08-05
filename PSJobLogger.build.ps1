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
        Install-Module $_ -Force -ErrorAction Stop
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
        ModuleList = @(
            'DictLogger.psm1'
        )
        FunctionsToExport = @(
            'Add-LogMessageToQueue',
            'ConvertFrom-DictLogger',
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
            'PSJobLoggerStreamProgress',
            'PSJobLoggerLogStreams'
        )
        FileList = 'PSJobLogger.psd1','PSJobLogger.psm1', 'DictLogger.psm1'
        Tags = 'ForEach-Object','Parallel','AsJob','Logging','PSEdition_Core','Windows','Linux','MacOS'
        ProjectUri = 'https://github.com/neflyte/PSJobLogger'
        LicenseUri = 'https://github.com/neflyte/PSJobLogger/blob/main/LICENSE'
        ReleaseNotes = 'https://github.com/neflyte/PSJobLogger/blob/main/CHANGELOG.md'
    }
    $null = New-ModuleManifest @manifestArgs
}

task Mp3test {
    Push-Location hack
    Remove-Item test.log -Force -ErrorAction SilentlyContinue
    Remove-Module PSJobLogger -Force -ErrorAction SilentlyContinue
    Remove-Module DictLogger -Force -ErrorAction SilentlyContinue
    Import-Module ../PSJobLogger -Force -ErrorAction Stop
    ./Process-Mp3Files.ps1 -Directory $HOME/Music/share -Logfile test.log
    Pop-Location
}
