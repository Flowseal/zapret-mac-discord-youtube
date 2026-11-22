using System;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Security.Principal;
using System.Text;

namespace Nimbus;

/// <summary>
/// "Автозапуск": a logon task with highest privileges. The Run registry key cannot start an app that
/// requires administrator rights without a UAC prompt, so Task Scheduler is used instead.
/// </summary>
internal static class Autostart
{
    private const string TaskName = "Nimbus";

    public static bool IsEnabled => Schtasks(out _, "/Query", "/TN", TaskName) == 0;

    public static void Enable()
    {
        var user = WindowsIdentity.GetCurrent().Name;
        var xml = $"""
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Nimbus — zapret для Windows</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{SecurityElement.Escape(user)}</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>{SecurityElement.Escape(user)}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>{SecurityElement.Escape(Paths.ExecutablePath)}</Command><Arguments>--autostart</Arguments></Exec></Actions>
</Task>
""";
        var file = Path.Combine(Path.GetTempPath(), $"nimbus-task-{Guid.NewGuid():N}.xml");
        try
        {
            File.WriteAllText(file, xml, Encoding.Unicode);
            if (Schtasks(out var output, "/Create", "/TN", TaskName, "/XML", file, "/F") != 0)
            {
                throw new InvalidOperationException(output.Trim());
            }
        }
        finally
        {
            try { File.Delete(file); } catch { }
        }
    }

    public static void Disable()
    {
        if (Schtasks(out var output, "/Delete", "/TN", TaskName, "/F") != 0 && IsEnabled)
        {
            throw new InvalidOperationException(output.Trim());
        }
    }

    private static int Schtasks(out string output, params string[] args)
    {
        var psi = new ProcessStartInfo("schtasks.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(psi)!;
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            p.WaitForExit(15000);
            output = stderr.Result + stdout.Result;
            return p.HasExited ? p.ExitCode : -1;
        }
        catch (Exception ex)
        {
            output = ex.Message;
            return -1;
        }
    }
}
