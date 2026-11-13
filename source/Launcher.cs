// OPC V7 launcher by Bradley Williams
// Tiny .NET Framework 4.x exe (already part of Windows 10/11).
// Starts OPC-V7.ps1 elevated with Windows PowerShell 5.1 and no console window.
// If OPC-V7.ps1 sits next to this exe it is used (handy for editing),
// otherwise the copy embedded in this exe is unpacked to %LOCALAPPDATA%\OPCV7\app.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("OPC V7")]
[assembly: AssemblyProduct("OPC V7 - Optimal Performance Cleaner")]
[assembly: AssemblyDescription("OPC V7 - Optimal Performance Cleaner")]
[assembly: AssemblyCompany("Bradley Williams")]
[assembly: AssemblyCopyright("Copyright (c) Bradley Williams. Perpetual Free License.")]
[assembly: AssemblyVersion("7.0.0.0")]
[assembly: AssemblyFileVersion("7.0.0.0")]

static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    static void Fail(string msg)
    {
        MessageBoxW(IntPtr.Zero, msg, "OPC V7", 0x10);
    }

    static string ResolveScript()
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        string sibling = Path.Combine(exeDir, "OPC-V7.ps1");
        if (File.Exists(sibling)) return sibling;

        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OPCV7", "app");
        Directory.CreateDirectory(dir);
        string target = Path.Combine(dir, "OPC-V7.ps1");

        byte[] data;
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("OPC-V7.ps1"))
        {
            if (s == null) throw new FileNotFoundException("Embedded script missing from this build.");
            using (MemoryStream ms = new MemoryStream()) { s.CopyTo(ms); data = ms.ToArray(); }
        }
        bool same = false;
        if (File.Exists(target))
        {
            byte[] existing = File.ReadAllBytes(target);
            if (existing.Length == data.Length)
            {
                same = true;
                for (int i = 0; i < data.Length; i++) { if (existing[i] != data[i]) { same = false; break; } }
            }
        }
        if (!same) File.WriteAllBytes(target, data);
        return target;
    }

    static string PowerShellPath()
    {
        string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        // A 32-bit process on 64-bit Windows must use Sysnative to reach 64-bit PowerShell (sfc/DISM need it).
        string sys = (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess) ? "Sysnative" : "System32";
        string ps = Path.Combine(win, sys, @"WindowsPowerShell\v1.0\powershell.exe");
        if (File.Exists(ps)) return ps;
        return "powershell.exe";
    }

    [STAThread]
    static int Main()
    {
        string script;
        try { script = ResolveScript(); }
        catch (Exception ex) { Fail("Could not prepare OPC V7:\n\n" + ex.Message); return 1; }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = PowerShellPath();
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"";
        psi.UseShellExecute = true;
        psi.Verb = "runas";
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = Path.GetDirectoryName(script);

        try { Process.Start(psi); return 0; }
        catch (Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223) // user said No on the UAC prompt
            {
                Fail("OPC V7 needs administrator rights to optimize Windows.\n\nRun it again and choose Yes on the prompt.");
                return 2;
            }
            Fail("Could not start PowerShell:\n\n" + ex.Message);
            return 1;
        }
    }
}
