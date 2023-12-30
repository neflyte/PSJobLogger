using module ../PSJobLogger
using namespace System.Collections.Generic
using namespace System.IO

function Invoke-FlushStream {
    [CmdletBinding()]
    param(
        [PSJobLogger]$JobLogger
    )
    $JobLogger.FlushPlainTextStreams()
}

function FlushAndCapture {
    [CmdletBinding()]
    param(
        [PSJobLogger]$JobLogger,
        [FileInfo]$LogCapture
    )
    Invoke-FlushStream -JobLogger $JobLogger *>"${LogCapture}"
}

Export-ModuleMember -Function Invoke-FlushStream,FlushAndCapture
