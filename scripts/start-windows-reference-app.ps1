param(
    [Parameter(Mandatory)][string] $AppId,
    [Parameter(Mandatory)][string] $ResultPath,
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'

if ($Worker) {
    $result = [ordered]@{ launcherIsAdministrator = $null; processId = $null; error = $null }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $result.launcherIsAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($result.launcherIsAdministrator) { throw 'The interactive task still has administrator privileges.' }
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FilesReferenceActivation
{
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(ref Guid classId, IntPtr outer, uint context, ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IApplicationActivationManager manager);

    public static uint Activate(string appId)
    {
        var classId = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
        var interfaceId = typeof(IApplicationActivationManager).GUID;
        const uint LocalServer = 4;
        const uint NoErrorUI = 2;
        IApplicationActivationManager manager;
        Marshal.ThrowExceptionForHR(CoCreateInstance(ref classId, IntPtr.Zero, LocalServer, ref interfaceId, out manager));
        try
        {
            uint processId;
            Marshal.ThrowExceptionForHR(manager.ActivateApplication(appId, null, NoErrorUI, out processId));
            return processId;
        }
        finally { Marshal.FinalReleaseComObject(manager); }
    }
}
'@
        $result.processId = [FilesReferenceActivation]::Activate($AppId)
    } catch {
        $result.error = $_.Exception.Message
    }
    $temporary = "$ResultPath.tmp"
    $result | ConvertTo-Json | Set-Content -LiteralPath $temporary
    Move-Item -LiteralPath $temporary -Destination $ResultPath
    exit ([int]($null -ne $result.error))
}

$taskName = "FilesReference-$([Guid]::NewGuid())"
$argument = "-NoProfile -NonInteractive -STA -WindowStyle Hidden -File `"$PSCommandPath`" -AppId `"$AppId`" -ResultPath `"$ResultPath`" -Worker"
$action = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path -Argument $argument
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
try {
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while (-not (Test-Path -LiteralPath $ResultPath) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $ResultPath)) { throw 'The interactive activation task did not publish a result.' }
    $result = Get-Content -Raw -LiteralPath $ResultPath | ConvertFrom-Json
    if ($result.error) { throw $result.error }
    Write-Output "Activated Files PID $($result.processId) from the limited interactive task."
} finally {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
