using module ./PSJLStreams.psm1

class PSJLLogStreams {
    static $AllStreams = @(
        [PSJLStreams]::Success,
        [PSJLStreams]::Error,
        [PSJLStreams]::Warning,
        [PSJLStreams]::Verbose,
        [PSJLStreams]::Debug,
        [PSJLStreams]::Information,
        [PSJLStreams]::Progress,
        [PSJLStreams]::Host
    )
    static $PlainTextStreams = @(
        [PSJLStreams]::Success,
        [PSJLStreams]::Error,
        [PSJLStreams]::Warning,
        [PSJLStreams]::Verbose,
        [PSJLStreams]::Debug,
        [PSJLStreams]::Information,
        [PSJLStreams]::Host
    )
}
