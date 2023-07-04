#requires -modules InvokeBuild
task Lint {
    Invoke-ScriptAnalyzer -Path ./PSJobLogger -Settings ./PSScriptAnalyzerSettings.psd1
}

task Test {
    Invoke-Pester
}

task Build-Manifest {
    $manifestArgs = @{
        Path = './PSJobLogger/PSJobLogger.psd1'
        Guid = '7f941218-c9c8-409a-9406-454b0a7116f6'
        Author = 'Alan Lew'
        Copyright = '(c) 2023 Alexander W Lew. All Rights Reserved.'
        CompanyName = 'Alan Lew'
        RootModule = 'PSJobLogger.psm1'
        ModuleVersion = '0.1.0'
        Description = 'A logging class suitable for use with ForEach-Object -Parallel -AsJob'
        PowerShellVersion = '5.0'
        FunctionsToExport = @('Initialize-PSJobLogger')
        CmdletsToExport = @()
        AliasesToExport = @()
        VariablesToExport = @()
        FileList = 'PSJobLogger.psd1','PSJobLogger.psm1'
        Tags = 'ForEach-Object','Parallel','AsJob','Logging','PSEdition_Core','Windows','Linux','MacOS'
        ProjectUri = 'https://github.com/neflyte/PSJobLogger'
        LicenseUri = 'https://github.com/neflyte/PSJobLogger/blob/main/LICENSE'
        ReleaseNotes = 'https://github.com/neflyte/PSJobLogger/blob/main/CHANGELOG.md'
    }
    $null = New-ModuleManifest @manifestArgs
}
