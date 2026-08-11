using System.Diagnostics;
using System.Reflection;

namespace LanjingQuiz;

internal static class Program
{
    private const string AppName = "LanjingQuiz";
    private const int ServerPort = 3000;

    private static string? _dataDir;
    private static string? _serverPath;
    private static Process? _server;
    private static NotifyIcon? _tray;

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, "LanjingQuizTraySingleInstance", out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("蓝鲸助手已在运行。", "蓝鲸助手");
            return;
        }

        _dataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppName, "data");
        Directory.CreateDirectory(_dataDir);

        _serverPath = ExtractServer();

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        BuildTray();
        StartServer();

        Application.Run();
    }

    /// <summary>Extract the embedded server exe once per version into
    /// %LOCALAPPDATA%\LanjingQuiz\app\&lt;version&gt;\.</summary>
    private static string ExtractServer()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppName, "app", version);
        var path = Path.Combine(dir, "LanjingQuiz-server.exe");
        if (File.Exists(path)) return path;

        Directory.CreateDirectory(dir);
        using var stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream("server.exe")
            ?? throw new InvalidOperationException("服务组件缺失:server.exe 未嵌入。请用 ServerExePath 属性构建。");
        using var output = File.Create(path);
        stream.CopyTo(output);
        return path;
    }

    private static void StartServer()
    {
        var info = new ProcessStartInfo
        {
            FileName = _serverPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        info.Environment["LANJING_LOCAL_DIR"] = _dataDir;
        info.Environment["LANJING_OPEN_BROWSER"] = "1";
        info.Environment["PORT"] = ServerPort.ToString();
        _server = Process.Start(info);
        if (_server != null)
        {
            _server.EnableRaisingEvents = true;
            _server.Exited += (_, _) =>
            {
                _tray?.ShowBalloonTip(3000, "蓝鲸助手", "服务已停止,可重新打开浏览器访问或退出。", ToolTipIcon.Info);
            };
        }
    }

    private static void BuildTray()
    {
        var iconStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico");
        _tray = new NotifyIcon
        {
            Icon = iconStream != null ? new Icon(iconStream) : SystemIcons.Application,
            Text = "蓝鲸助手",
            Visible = true,
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开浏览器", null, (_, _) => OpenBrowser());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Exit());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => OpenBrowser();
    }

    private static void OpenBrowser()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = $"http://127.0.0.1:{ServerPort}",
                UseShellExecute = true,
            });
        }
        catch
        {
            // Best-effort: the service may not be up yet.
        }
    }

    private static void Exit()
    {
        try
        {
            if (_server is { HasExited: false })
            {
                _server.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Already gone.
        }
        _tray?.Dispose();
        Application.Exit();
    }
}
