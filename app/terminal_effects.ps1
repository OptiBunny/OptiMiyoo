#requires -Version 5.1
# Terminal appearance belongs to the user's existing profile. OptiMiyoo does
# not register a profile, install shaders, or change Terminal settings.
function Set-OptiTerminalCrtMode([ValidateSet('CRT','Smooth','Paused')][string]$Mode) {
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {
        $payload=@{Mode=$Mode}
        # Keep the chosen bunny effect across trusted prompts and menu returns.
        # A temporary Smooth/Paused mode must not replace that preference.
        if ($script:DisplayEffect -in 'CRT','Smooth') {$payload.Preference=[string]$script:DisplayEffect}
        return [bool](Invoke-ApplicationRpc -Operation Display.Mode -Payload $payload).Enabled
    }
    # The renderer uses its existing bunny-only effect when no full-screen
    # Terminal shader is supplied. This path deliberately performs no writes.
    return $false
}
