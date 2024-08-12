using module ../PSJobLogger/PSJobLogger.psm1
using namespace System.Collections.Generic
using namespace System.IO

function Invoke-FlushStream {
    param(
        [PSJobLogger]$JobLogger
    )
    $JobLogger.FlushPlainTextStreams()
}

function FlushAndCapture {
    param(
        [PSJobLogger]$JobLogger,
        [FileInfo]$LogCapture
    )
    Invoke-FlushStream -JobLogger $JobLogger *>"${LogCapture}"
}

Export-ModuleMember -Function Invoke-FlushStream,FlushAndCapture
