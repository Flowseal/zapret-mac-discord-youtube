using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;

namespace Nimbus;

internal static class Program
{
    private const string MutexName = @"Local\Nimbus.Windows.Gui";
    private const string ShowEventName = @"Local\Nimbus.Windows.Show";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--engine-host")
        {
            return EngineHost.Run(args[1]);
        }
        if (args.Length >= 2 && args[0] == "--self-test")
        {
            return SelfTest.Run(args[1]);
        }
        if (args.Length >= 2 && args[0] == "--motion-bench")
        {
            return MotionBench.Run(args[1]);
        }
        if (args.Length >= 2 && args[0] == "--render-screens")
        {
            return Screens.Render(args[1]);
        }

        using var mutex = new Mutex(false, MutexName);
        var owns = false;
        try
        {
            owns = mutex.WaitOne(args.Contains("--updated") ? TimeSpan.FromSeconds(15) : TimeSpan.Zero);
        }
        catch (AbandonedMutexException)
        {
            owns = true;
        }
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        if (!owns)
        {
            showEvent.Set();
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        Motion.UseDisplayRate();
        Theme.Apply(app.Resources);
        var controller = new AppController();
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("unhandled: " + e.Exception);
            e.Handled = true;
        };
        app.Startup += (_, _) =>
        {
            try
            {
                controller.Start(showOnLaunch: !args.Contains("--autostart"));
            }
            catch (Exception ex)
            {
                Log.Write("startup: " + ex);
                MessageBox.Show(ex.Message, "Nimbus", MessageBoxButton.OK, MessageBoxImage.Error);
                app.Shutdown(1);
                return;
            }
            var listener = new Thread(() =>
            {
                while (showEvent.WaitOne())
                {
                    app.Dispatcher.BeginInvoke(controller.ShowFromSecondInstance);
                }
            }) { IsBackground = true, Name = "show-listener" };
            listener.Start();
        };
        app.Exit += (_, _) => controller.Shutdown();
        var code = app.Run();
        mutex.ReleaseMutex();
        return code;
    }
}
