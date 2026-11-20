# MacDesk - a macOS-style dock and a desktop clock / PC stats widget for Windows.
# Single PowerShell script, no install, no dependencies.
# Dock apps are configured in apps.json next to this script (created on first run).
# https://github.com/b33nthere/MacDesk  -  MIT License

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$global:MacDeskSelf = $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Root 'macdesk.log'
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
trap { Log ("ERROR: " + $_.Exception.Message + " @ " + $_.InvocationInfo.ScriptLineNumber); continue }
Set-Content -Path $LogFile -Value "start" -Encoding UTF8

# --- single instance ---
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\MacDesk', [ref]$createdNew)
if (-not $createdNew) { exit }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$refs = @(
    [System.Windows.Media.Imaging.BitmapSource].Assembly.Location,
    [System.Windows.DependencyObject].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location,
    [System.Windows.Window].Assembly.Location
)

Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class MD
{
    // ---------- icons via the Shell (works for Microsoft Store apps too) ----------
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm); }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx; public int cy; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int c, ref BITMAP bm);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint lines, byte[] bits, ref BITMAPINFO bi, uint usage);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFO {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        public uint m0, m1, m2, m3;
    }

    public static BitmapSource Icon(string parsingName, int size)
    {
        IShellItemImageFactory f;
        SHCreateItemFromParsingName(parsingName, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out f);
        IntPtr hbm;
        int hr = f.GetImage(new SIZE { cx = size, cy = size }, 0x4 /*ICONONLY*/, out hbm);
        if (hr != 0) hr = f.GetImage(new SIZE { cx = size, cy = size }, 0x0, out hbm);
        Marshal.ReleaseComObject(f);
        if (hr != 0) throw new Exception("GetImage failed " + hr);
        try
        {
            BITMAP bm = new BITMAP();
            GetObject(hbm, Marshal.SizeOf(typeof(BITMAP)), ref bm);
            int w = bm.bmWidth, h = Math.Abs(bm.bmHeight);
            BITMAPINFO bi = new BITMAPINFO();
            bi.biSize = 40; bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32;
            byte[] bits = new byte[w * h * 4];
            IntPtr dc = GetDC(IntPtr.Zero);
            GetDIBits(dc, hbm, 0, (uint)h, bits, ref bi, 0);
            ReleaseDC(IntPtr.Zero, dc);
            bool anyAlpha = false;
            for (int i = 3; i < bits.Length; i += 4) if (bits[i] != 0) { anyAlpha = true; break; }
            if (!anyAlpha) for (int i = 3; i < bits.Length; i += 4) bits[i] = 255;
            BitmapSource src = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, bits, w * 4);
            src.Freeze();
            return src;
        }
        finally { DeleteObject(hbm); }
    }

    // ---------- windows ----------
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);

    public static void ToolWindow(IntPtr h)
    {
        int ex = GetWindowLong(h, -20);
        SetWindowLong(h, -20, (ex | 0x80) & ~0x40000); // TOOLWINDOW, not APPWINDOW
    }
    public static void SendToBottom(IntPtr h)
    {
        SetWindowPos(h, new IntPtr(1), 0, 0, 0, 0, 0x0013); // HWND_BOTTOM, NOMOVE|NOSIZE|NOACTIVATE
    }
    public static void Focus(IntPtr h)
    {
        if (IsIconic(h)) ShowWindow(h, 9);
        SetForegroundWindow(h);
    }

    // is a fullscreen app (game, video) in the foreground?
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    public static bool ForegroundIsFullscreen(IntPtr self1, IntPtr self2)
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero || h == self1 || h == self2) return false;
        System.Text.StringBuilder sb = new System.Text.StringBuilder(64);
        GetClassName(h, sb, 64);
        string c = sb.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
        // a maximized window is not "fullscreen" (with an auto-hidden taskbar it covers the screen too)
        if (IsZoomed(h)) return false;
        RECT r; if (!GetWindowRect(h, out r)) return false;
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        return r.l == 0 && r.t == 0 && r.r == sw && r.b == sh;
    }
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);

    // ---------- reserve screen space for the dock (like the macOS dock), so maximized windows end above it ----------
    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string s);
    public static void ReserveBottom(IntPtr h, int heightPx)
    {
        APPBARDATA d = new APPBARDATA();
        d.cbSize = Marshal.SizeOf(typeof(APPBARDATA)); d.hWnd = h;
        d.uCallbackMessage = RegisterWindowMessage("MacDeskAppBar");
        SHAppBarMessage(0, ref d);                       // ABM_NEW
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        d.uEdge = 3;                                     // ABE_BOTTOM
        d.rc.l = 0; d.rc.r = sw; d.rc.t = sh - heightPx; d.rc.b = sh;
        SHAppBarMessage(2, ref d);                       // ABM_QUERYPOS
        d.rc.t = d.rc.b - heightPx;
        SHAppBarMessage(3, ref d);                       // ABM_SETPOS
    }
    public static void ReleaseBottom(IntPtr h)
    {
        APPBARDATA d = new APPBARDATA();
        d.cbSize = Marshal.SizeOf(typeof(APPBARDATA)); d.hWnd = h;
        SHAppBarMessage(1, ref d);                       // ABM_REMOVE
    }

    // ---------- CPU and RAM ----------
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint lo, hi; public ulong V { get { return ((ulong)hi << 32) | lo; } } }
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
    static ulong pIdle, pTotal;
    public static double Cpu()
    {
        FILETIME i, k, u; GetSystemTimes(out i, out k, out u);
        ulong idle = i.V, total = k.V + u.V;
        ulong di = idle - pIdle, dt = total - pTotal;
        pIdle = idle; pTotal = total;
        if (dt == 0) return 0;
        return Math.Max(0, Math.Min(100, 100.0 * (dt - di) / dt));
    }
    [StructLayout(LayoutKind.Sequential)]
    class MEMSTAT { public uint len = 64; public uint load; public ulong total, avail, tpf, apf, tv, av, ave; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);
    public static double[] Ram()
    {
        MEMSTAT m = new MEMSTAT(); GlobalMemoryStatusEx(m);
        return new double[] { (m.total - m.avail) / 1073741824.0, m.total / 1073741824.0 };
    }

    // ---------- NVIDIA GPU via nvidia-smi (background process, never blocks the UI) ----------
    public static volatile string GpuLine = "";
    static Process smi;
    public static void StartGpu(string exe)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe,
                "--query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits -l 2");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true;
            smi = new Process(); smi.StartInfo = psi;
            smi.OutputDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) GpuLine = e.Data; };
            smi.Start(); smi.BeginOutputReadLine();
        }
        catch { }
    }
    public static void StopGpu() { try { if (smi != null && !smi.HasExited) smi.Kill(); } catch { } }
}
'@

$ErrorActionPreference = 'Continue'

# falling snow that settles on windows, the dock and the widget (Snow.cs next to this script)
$SnowSource = Join-Path $Root 'Snow.cs'
$HasSnow = $false
if (Test-Path $SnowSource) {
    try { Add-Type -ReferencedAssemblies $refs -TypeDefinition (Get-Content $SnowSource -Raw); $HasSnow = $true }
    catch { Log ("snow failed to load: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- settings
$SettingsPath = Join-Path $Root 'settings.json'
$Settings = [ordered]@{
    snow = $true; snowAmount = 1.0; snowSize = 1.0; snowSpeed = 1.0; snowWind = 0.0; snowPile = 1.0
    snowSettle = $true; snowHideCapture = $true; snowSaver = $false
    dockSize = 52; dockMagnify = $true; dockLabels = $true; dockDots = $true
    widget = $true; widgetStats = $true; widgetDate = $true
}
if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $Settings[$p.Name] = $p.Value }
    } catch {}
}
function Save-Settings {
    try { [IO.File]::WriteAllText($SettingsPath, ($Settings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch {}
}
function Apply-SnowSettings {
    if (-not $HasSnow) { return }
    [Snow]::Amount = [double]$Settings.snowAmount
    [Snow]::SizeScale = [double]$Settings.snowSize
    [Snow]::SpeedScale = [double]$Settings.snowSpeed
    [Snow]::WindBias = [double]$Settings.snowWind
    [Snow]::PileScale = [double]$Settings.snowPile
    [Snow]::SettleOnWindows = [bool]$Settings.snowSettle
    [Snow]::HideFromCapture = [bool]$Settings.snowHideCapture
    [Snow]::Fps = if ($Settings.snowSaver) { 30 } else { 60 }
}

# ---------------------------------------------------------------- texts (English / Czech)
$lang = if ($env:MACDESK_LANG) { $env:MACDESK_LANG } else { (Get-Culture).TwoLetterISOLanguageName }
$cs = $lang -eq 'cs'
$T = if ($cs) {
    @{ Edit = 'Upravit aplikace v doku…'; Restart = 'Restartovat MacDesk'; Quit = 'Ukončit MacDesk'
       Cpu = 'Procesor'; Ram = 'Paměť RAM'; Gpu = 'Grafika'; Disk = 'Disk'; Free = 'volno'
       Snow = 'Sníh'; Settings = 'Nastavení…'
       # settings window
       SetTitle = 'Nastavení'; TabSnow = 'Sníh'; TabDock = 'Dok'; TabWidget = 'Widget'; TabGeneral = 'Obecné'
       SnowHead = 'Sníh'; SnowDesc = 'Padající sníh, který se usazuje na oknech, doku a widgetu.'
       SnowOn = 'Padající sníh'; SnowOnSub = 'Při hře přes celou obrazovku se sám vypne.'
       SnowAmount = 'Množství'; SnowSize = 'Velikost vloček'; SnowSpeed = 'Rychlost padání'; SnowWind = 'Vítr'
       NoWind = 'bezvětří'; SnowPile = 'Výška závějí'; NoPile = 'bez závějí'
       SnowSettle = 'Usazovat na oknech'; SnowSettleSub = 'Dok, widget a spodek obrazovky sbírají sníh vždy.'
       SnowCapture = 'Skrýt na screenshotech'; SnowCaptureSub = 'Sníh neuvidí OBS, Discord stream ani snímky obrazovky.'
       SnowClear = 'Smést všechen sníh'; SnowClearBtn = 'Smést'
       SnowSaver = 'Úsporný režim'; SnowSaverSub = '30 snímků za sekundu místo 60 – zhruba poloviční zátěž grafiky.'
       DockHead = 'Dok'; DockDesc = 'Velikost ikon a chování doku.'
       DockSize = 'Velikost ikon'; DockMagnify = 'Zvětšování při najetí myší'; DockLabels = 'Názvy aplikací'; DockDots = 'Tečky u spuštěných aplikací'
       DockApps = 'Aplikace v doku'; DockAppsSub = 'Otevře apps.json – co je v doku a v jakém pořadí.'; DockAppsBtn = 'Upravit…'
       WidgetHead = 'Widget'; WidgetDesc = 'Hodiny a přehled výkonu na ploše.'
       WidgetOn = 'Zobrazit widget'; WidgetDate = 'Datum'; WidgetStats = 'Procesor, RAM, grafika a disk'
       GenHead = 'Obecné'; GenDesc = 'Spouštění a informace o MacDesku.'
       GenAuto = 'Spustit po přihlášení'; GenAutoSub = 'MacDesk se zapne sám se systémem Windows.'
       GenRestart = 'Restartovat MacDesk'; GenRestartBtn = 'Restartovat'; GenQuit = 'Ukončit MacDesk'; GenQuitBtn = 'Ukončit'
       GenAbout = 'MacDesk je open source (MIT).'; GenRepo = 'Otevřít na GitHubu' }
} else {
    @{ Edit = 'Edit dock apps…'; Restart = 'Restart MacDesk'; Quit = 'Quit MacDesk'
       Cpu = 'CPU'; Ram = 'Memory'; Gpu = 'GPU'; Disk = 'Disk'; Free = 'free'
       Snow = 'Snow'; Settings = 'Settings…'
       SetTitle = 'Settings'; TabSnow = 'Snow'; TabDock = 'Dock'; TabWidget = 'Widget'; TabGeneral = 'General'
       SnowHead = 'Snow'; SnowDesc = 'Falling snow that settles on your windows, the dock and the widget.'
       SnowOn = 'Falling snow'; SnowOnSub = 'Pauses by itself while a game runs fullscreen.'
       SnowAmount = 'Amount'; SnowSize = 'Flake size'; SnowSpeed = 'Falling speed'; SnowWind = 'Wind'
       NoWind = 'calm'; SnowPile = 'Drift height'; NoPile = 'no drifts'
       SnowSettle = 'Settle on windows'; SnowSettleSub = 'The dock, widget and bottom of the screen always collect snow.'
       SnowCapture = 'Hide from screenshots'; SnowCaptureSub = 'OBS, Discord streams and screenshots won''t show the snow.'
       SnowClear = 'Sweep all snow away'; SnowClearBtn = 'Sweep'
       SnowSaver = 'Power saving'; SnowSaverSub = '30 frames per second instead of 60, about half the GPU load.'
       DockHead = 'Dock'; DockDesc = 'Icon size and how the dock behaves.'
       DockSize = 'Icon size'; DockMagnify = 'Magnify on hover'; DockLabels = 'App names'; DockDots = 'Dots under running apps'
       DockApps = 'Dock apps'; DockAppsSub = 'Opens apps.json: which apps are in the dock and in what order.'; DockAppsBtn = 'Edit…'
       WidgetHead = 'Widget'; WidgetDesc = 'The desktop clock and PC stats.'
       WidgetOn = 'Show the widget'; WidgetDate = 'Date'; WidgetStats = 'CPU, memory, GPU and disk'
       GenHead = 'General'; GenDesc = 'Startup and about MacDesk.'
       GenAuto = 'Start at sign-in'; GenAutoSub = 'MacDesk starts together with Windows.'
       GenRestart = 'Restart MacDesk'; GenRestartBtn = 'Restart'; GenQuit = 'Quit MacDesk'; GenQuitBtn = 'Quit'
       GenAbout = 'MacDesk is open source (MIT).'; GenRepo = 'Open on GitHub' }
}

# ---------------------------------------------------------------- config
$ConfigPath = Join-Path $Root 'apps.json'
$global:MacDeskApps = $ConfigPath
if (-not (Test-Path $ConfigPath)) {
    # first run: build a dock from apps that are actually installed
    $start = @{}
    Get-StartApps | ForEach-Object { if (-not $start.ContainsKey($_.Name)) { $start[$_.Name] = $_.AppID } }
    $wanted = @(
        @{ n = @('File Explorer', 'Průzkumník souborů'); p = '' },
        @{ n = @('Brave', 'Google Chrome', 'Firefox', 'Opera GX Browser', 'Microsoft Edge'); p = $null; one = $true },
        @{ n = @('Discord'); p = 'Discord' },
        @{ n = @('Spotify'); p = 'Spotify' },
        @{ n = @('Steam'); p = 'steam' },
        @{ n = @('Visual Studio Code'); p = 'Code' },
        @{ n = @('Settings', 'Nastavení'); p = 'SystemSettings' }
    )
    $procOf = @{ 'Brave' = 'brave'; 'Google Chrome' = 'chrome'; 'Firefox' = 'firefox'; 'Opera GX Browser' = 'opera'; 'Microsoft Edge' = 'msedge' }
    $list = @()
    foreach ($w in $wanted) {
        foreach ($name in $w.n) {
            if ($start.ContainsKey($name)) {
                $proc = if ($null -eq $w.p) { $procOf[$name] } else { $w.p }
                $list += [ordered]@{ name = $name; appid = $start[$name]; proc = $proc }
                break
            }
        }
    }
    [IO.File]::WriteAllText($ConfigPath, ($list | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
    Log "apps.json created with $($list.Count) apps"
}

# ---------------------------------------------------------------- DOCK
$IconSize = [int]$Settings.dockSize
$apps = @((Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })

$dockXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize"
        SizeToContent="Height" UseLayoutRounding="True" Title="MacDesk Dock">
  <Grid x:Name="Root">
    <Grid.RowDefinitions>
      <RowDefinition Height="44"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Canvas Grid.Row="0" x:Name="LabelCanvas" ClipToBounds="False">
      <Border x:Name="Label" Visibility="Collapsed" CornerRadius="7" Padding="10,4"
              Background="#E6262628" BorderBrush="#33FFFFFF" BorderThickness="1">
        <TextBlock x:Name="LabelText" Foreground="#F2FFFFFF" FontSize="13" FontFamily="Segoe UI Variable Text, Segoe UI"/>
      </Border>
    </Canvas>
    <Grid Grid.Row="1" Margin="0,26,0,10">
      <Border x:Name="Bar" CornerRadius="22" Background="#A61C1C1E" BorderBrush="#40FFFFFF" BorderThickness="1"
              HorizontalAlignment="Center" VerticalAlignment="Bottom" Padding="10,0,10,4">
        <Border.Effect>
          <DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.45" Color="Black"/>
        </Border.Effect>
        <StackPanel x:Name="Icons" Orientation="Horizontal" VerticalAlignment="Bottom"/>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$dock = [System.Windows.Markup.XamlReader]::Parse($dockXaml)
$iconsPanel = $dock.FindName('Icons')
$label = $dock.FindName('Label')
$labelText = $dock.FindName('LabelText')
$labelCanvas = $dock.FindName('LabelCanvas')

$items = New-Object System.Collections.ArrayList

function Get-ParsingName($a) {
    if ($a.icon) { return $a.icon }
    if ($a.appid -match '^[A-Za-z]:\\') { return $a.appid }
    return "shell:AppsFolder\$($a.appid)"
}

function Start-DockApp($a) {
    # if it is running and has a window, switch to it
    if ($a.proc) {
        $p = Get-Process -Name $a.proc -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($p) { [MD]::Focus($p.MainWindowHandle); return }
    }
    try {
        if ($a.run) { Start-Process $a.run }
        elseif ($a.appid -match '^[A-Za-z]:\\') { Start-Process $a.appid }
        else { Start-Process 'explorer.exe' "shell:AppsFolder\$($a.appid)" }
    } catch {}
}

function Set-Scales($hoverIndex) {
    for ($i = 0; $i -lt $items.Count; $i++) {
        $target = 1.0
        if ($hoverIndex -ge 0 -and $Settings.dockMagnify) {
            $d = [Math]::Abs($i - $hoverIndex)
            if ($d -eq 0) { $target = 1.45 } elseif ($d -eq 1) { $target = 1.2 } elseif ($d -eq 2) { $target = 1.07 }
        }
        $st = $items[$i].Scale
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation($target, [TimeSpan]::FromMilliseconds(130))
        $anim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
        $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $anim)
        $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $anim)
        $w = $IconSize * $target + 10
        $wa = New-Object System.Windows.Media.Animation.DoubleAnimation($w, [TimeSpan]::FromMilliseconds(130))
        $items[$i].Slot.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $wa)
    }
}

$index = 0
foreach ($a in $apps) {
    $slot = New-Object System.Windows.Controls.Grid
    $slot.Width = $IconSize + 10
    $slot.Height = $IconSize + 14
    $slot.Background = [System.Windows.Media.Brushes]::Transparent
    $slot.Cursor = [System.Windows.Input.Cursors]::Hand

    $img = New-Object System.Windows.Controls.Image
    $img.Width = $IconSize; $img.Height = $IconSize
    $img.VerticalAlignment = 'Bottom'; $img.Margin = '0,0,0,8'
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
    try { $img.Source = [MD]::Icon((Get-ParsingName $a), 128) } catch {}
    $scale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $img.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 1.0)
    $img.RenderTransform = $scale

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 5; $dot.Height = 5; $dot.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(230, 255, 255, 255))
    $dot.VerticalAlignment = 'Bottom'; $dot.HorizontalAlignment = 'Center'; $dot.Margin = '0,0,0,1'
    $dot.Visibility = 'Hidden'

    [void]$slot.Children.Add($img)
    [void]$slot.Children.Add($dot)
    [void]$iconsPanel.Children.Add($slot)

    $entry = [pscustomobject]@{ App = $a; Slot = $slot; Scale = $scale; Dot = $dot; Img = $img; Index = $index }
    [void]$items.Add($entry)
    $slot.Tag = $index

    $slot.Add_MouseEnter({
        param($s, $e)
        $i = [int]$s.Tag
        Set-Scales $i
        if (-not $Settings.dockLabels) { return }
        $labelText.Text = $items[$i].App.name
        $label.Visibility = 'Visible'
        $label.UpdateLayout()
        $p = $s.TranslatePoint((New-Object System.Windows.Point(($s.ActualWidth / 2), 0)), $labelCanvas)
        [System.Windows.Controls.Canvas]::SetLeft($label, $p.X - $label.ActualWidth / 2)
        [System.Windows.Controls.Canvas]::SetTop($label, 4)
    })
    $slot.Add_MouseLeftButtonUp({
        param($s, $e)
        $i = [int]$s.Tag
        $st = $items[$i].Scale
        $b = New-Object System.Windows.Media.Animation.DoubleAnimation(1.45, 1.25, [TimeSpan]::FromMilliseconds(120))
        $b.AutoReverse = $true
        $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $b)
        Start-DockApp $items[$i].App
    })
    $index++
}

$iconsPanel.Add_MouseLeave({ Set-Scales -1; $label.Visibility = 'Collapsed' })

# context menu
$menu = New-Object System.Windows.Controls.ContextMenu
$mi1 = New-Object System.Windows.Controls.MenuItem; $mi1.Header = $T.Edit
$mi1.Add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $global:MacDeskApps + '"') })
$mi2 = New-Object System.Windows.Controls.MenuItem; $mi2.Header = $T.Restart
$script:restarting = $false
$mi2.Add_Click({
    $script:restarting = $true
    $dock.Close()
})
$mi3 = New-Object System.Windows.Controls.MenuItem; $mi3.Header = $T.Quit
$mi3.Add_Click({ $dock.Close() })
$miSet = New-Object System.Windows.Controls.MenuItem; $miSet.Header = $T.Settings; $miSet.FontWeight = 'SemiBold'
$miSet.Add_Click({ Show-SettingsWindow })
[void]$menu.Items.Add($miSet)
if ($HasSnow) {
    $miSnow = New-Object System.Windows.Controls.MenuItem; $miSnow.Header = $T.Snow
    $miSnow.IsCheckable = $true
    $miSnow.Add_Click({ Set-Setting 'snow' ([bool]$miSnow.IsChecked) })
    [void]$menu.Items.Add($miSnow)
    $menu.Add_Opened({ $miSnow.IsChecked = [bool]$Settings.snow })
}
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($mi1); [void]$menu.Items.Add($mi2); [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator)); [void]$menu.Items.Add($mi3)
$dock.ContextMenu = $menu

# ---------------------------------------------------------------- applying settings live
$script:saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:saveTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:saveTimer.Add_Tick({ $script:saveTimer.Stop(); Save-Settings })

function Set-Setting($key, $value) {
    $Settings[$key] = $value
    $script:saveTimer.Stop(); $script:saveTimer.Start()      # save shortly after the last change
    switch -Wildcard ($key) {
        'snow' { if ($HasSnow) { if ($value) { Start-Snow } else { [Snow]::Stop() } } }
        'snow?*' { Apply-SnowSettings }
        'dockSize' { Apply-DockLayout }
        'dockDots' { Update-Dots }
        'widget*' { Apply-WidgetSettings }
    }
}

function Apply-DockLayout {
    $script:IconSize = [int]$Settings.dockSize
    foreach ($it in $items) {
        $it.Slot.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null)
        $it.Slot.Width = $IconSize + 10; $it.Slot.Height = $IconSize + 14
        $it.Img.Width = $IconSize; $it.Img.Height = $IconSize
    }
    $dock.FindName('Bar').CornerRadius = New-Object System.Windows.CornerRadius ([Math]::Round($IconSize * 0.42))
    $dock.Width = $items.Count * ($IconSize + 10) + 20 + 3 * $IconSize
    if ($dock.IsLoaded -and -not $env:MACDESK_SHOT) {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($dock)).Handle
        $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($dock).DpiScaleY
        [MD]::ReserveBottom($h, [int](($IconSize + 40) * $scale))
    }
}

function Get-AutostartPath { Join-Path ([Environment]::GetFolderPath('Startup')) 'MacDesk.lnk' }
function Set-Autostart([bool]$on) {
    $lnkPath = Get-AutostartPath
    if ($on) {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $lnk.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($global:MacDeskSelf)`""
        $lnk.WindowStyle = 7; $lnk.Description = 'MacDesk dock and widget'
        $lnk.Save()
    } elseif (Test-Path $lnkPath) { Remove-Item $lnkPath -Force }
}

# ---------------------------------------------------------------- SETTINGS WINDOW
$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Width="760" Height="640" WindowStartupLocation="CenterScreen" Title="MacDesk"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="3" Background="#38FFFFFF" Margin="2,2,4,2"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="42" Height="24" CornerRadius="12" Background="#40FFFFFF">
              <Ellipse x:Name="Knob" Width="20" Height="20" Fill="White" HorizontalAlignment="Left" Margin="2,0,0,0">
                <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="1" Opacity="0.3"/></Ellipse.Effect>
              </Ellipse>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#FF0A84FF"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Knob" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Ellipse Width="18" Height="18" Fill="White">
              <Ellipse.Effect><DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.35"/></Ellipse.Effect>
            </Ellipse>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Rail" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="{TemplateBinding Background}"/></Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Slide" TargetType="Slider">
      <Setter Property="Width" Value="190"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="22" Background="Transparent">
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Rail}" Background="#FF0A84FF" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Rail}" Background="#38FFFFFF" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource Knob}"/></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="7" Background="#2BFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" Padding="14,5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#42FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#1AFFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" CornerRadius="7" Background="Transparent" Padding="8,6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#14FFFFFF"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="B" Property="Background" Value="#2EFFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="14" Background="#F51E1E21" BorderBrush="#40FFFFFF" BorderThickness="1" Margin="16">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="6" Opacity="0.5"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="200"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- sidebar -->
      <Border x:Name="Side" Grid.Column="0" Background="#14FFFFFF" CornerRadius="14,0,0,14" BorderBrush="#14FFFFFF" BorderThickness="0,0,1,0">
        <StackPanel Margin="12,16,12,12">
          <StackPanel Orientation="Horizontal" Margin="6,0,0,18">
            <Ellipse x:Name="Dot1" Width="12" Height="12" Fill="#FFFF5F57" Margin="0,0,8,0" Cursor="Hand"/>
            <Ellipse Width="12" Height="12" Fill="#FFFEBC2E" Margin="0,0,8,0"/>
            <Ellipse Width="12" Height="12" Fill="#FF28C840"/>
          </StackPanel>
          <TextBlock x:Name="AppName" Text="MacDesk" Foreground="White" FontSize="20" FontWeight="SemiBold" Margin="8,0,0,14"/>
          <StackPanel x:Name="NavPanel"/>
        </StackPanel>
      </Border>

      <!-- content -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid x:Name="Head" Grid.Row="0" Background="Transparent" Margin="28,20,20,6">
          <StackPanel>
            <TextBlock x:Name="PageTitle" Foreground="White" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock x:Name="PageDesc" Foreground="#A6FFFFFF" FontSize="13" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
          <Button x:Name="CloseBtn" HorizontalAlignment="Right" VerticalAlignment="Top" Width="30" Height="30" Cursor="Hand" ToolTip="Esc">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="B" CornerRadius="15" Background="Transparent">
                  <TextBlock Text="&#x2715;" Foreground="#CCFFFFFF" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#26FFFFFF"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,8,0,16">
          <Grid Margin="28,6,28,10">
            <StackPanel x:Name="PageSnow"/>
            <StackPanel x:Name="PageDock" Visibility="Collapsed"/>
            <StackPanel x:Name="PageWidget" Visibility="Collapsed"/>
            <StackPanel x:Name="PageGeneral" Visibility="Collapsed"/>
          </Grid>
        </ScrollViewer>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$script:settingsWin = $null

function New-Brush([string]$hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }

function New-Card($page) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 10; $b.Background = New-Brush '#12FFFFFF'; $b.BorderBrush = New-Brush '#14FFFFFF'
    $b.BorderThickness = 1; $b.Margin = '0,0,0,14'
    $sp = New-Object System.Windows.Controls.StackPanel
    $b.Child = $sp
    [void]$page.Children.Add($b)
    return $sp
}

function Add-Row($card, [string]$title, [string]$sub, $control, [string]$value) {
    if ($card.Children.Count -gt 0) {
        $line = New-Object System.Windows.Controls.Border
        $line.Height = 1; $line.Background = New-Brush '#14FFFFFF'; $line.Margin = '14,0,14,0'
        [void]$card.Children.Add($line)
    }
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '16,11,14,11'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $left = New-Object System.Windows.Controls.StackPanel
    $left.VerticalAlignment = 'Center'; $left.Margin = '0,0,16,0'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $title; $t.Foreground = [System.Windows.Media.Brushes]::White; $t.FontSize = 14
    [void]$left.Children.Add($t)
    if ($sub) {
        $s = New-Object System.Windows.Controls.TextBlock
        $s.Text = $sub; $s.Foreground = New-Brush '#8CFFFFFF'; $s.FontSize = 12; $s.TextWrapping = 'Wrap'; $s.Margin = '0,2,0,0'
        [void]$left.Children.Add($s)
    }
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$g.Children.Add($left)
    $right = New-Object System.Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
    $vt = $null
    if ($null -ne $value) {
        $vt = New-Object System.Windows.Controls.TextBlock
        $vt.Text = $value; $vt.Foreground = New-Brush '#B3FFFFFF'; $vt.FontSize = 13; $vt.Width = 74
        $vt.TextAlignment = 'Right'; $vt.VerticalAlignment = 'Center'; $vt.Margin = '0,0,12,0'
        [void]$right.Children.Add($vt)
    }
    [void]$right.Children.Add($control)
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$g.Children.Add($right)
    [void]$card.Children.Add($g)
    return $vt
}

function New-Switch($win, [string]$key) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $win.FindResource('Switch')
    $cb.IsChecked = [bool]$Settings[$key]
    $cb.Tag = $key
    $cb.Add_Click({ param($s, $e) Set-Setting $s.Tag ([bool]$s.IsChecked) })
    return $cb
}

# a slider bound to a setting; $fmt turns the value into the text shown next to it
function Add-SliderRow($win, $card, [string]$title, [string]$key, [double]$min, [double]$max, [double]$step, [scriptblock]$fmt) {
    $sl = New-Object System.Windows.Controls.Slider
    $sl.Style = $win.FindResource('Slide')
    $sl.Minimum = $min; $sl.Maximum = $max; $sl.SmallChange = $step; $sl.LargeChange = $step
    $sl.TickFrequency = $step; $sl.IsSnapToTickEnabled = $true
    $sl.Value = [double]$Settings[$key]
    $vt = Add-Row $card $title $null $sl (& $fmt $sl.Value)
    $sl.Tag = @{ Key = $key; Label = $vt; Fmt = $fmt }
    $sl.Add_ValueChanged({
        param($s, $e)
        $info = $s.Tag
        $v = [Math]::Round($s.Value, 2)
        $info.Label.Text = & $info.Fmt $v
        Set-Setting $info.Key $v
    })
}

function New-Btn($win, [string]$text, [scriptblock]$onClick) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $win.FindResource('Btn'); $b.Content = $text
    $b.Add_Click($onClick)
    return $b
}

function Show-SettingsWindow {
    if ($script:settingsWin) { $script:settingsWin.Activate(); return }
    $win = [System.Windows.Markup.XamlReader]::Parse($settingsXaml)
    $win.Title = "MacDesk – $($T.SetTitle)"
    $script:settingsWin = $win
    $win.Add_Closed({ $script:settingsWin = $null; Save-Settings })
    $win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $win.FindName('CloseBtn').Add_Click({ $script:settingsWin.Close() })
    $win.FindName('Dot1').Add_MouseLeftButtonUp({ $script:settingsWin.Close() })
    foreach ($n in 'Side', 'Head') {
        $win.FindName($n).Add_MouseLeftButtonDown({ param($s, $e) if ($e.ButtonState -eq 'Pressed') { try { $script:settingsWin.DragMove() } catch {} } })
    }

    $pct = { param($v) '{0:0} %' -f ($v * 100) }

    # --- snow
    $p = $win.FindName('PageSnow')
    if ($HasSnow) {
        $c = New-Card $p
        [void](Add-Row $c $T.SnowOn $T.SnowOnSub (New-Switch $win 'snow') $null)
        $c = New-Card $p
        Add-SliderRow $win $c $T.SnowAmount 'snowAmount' 0.2 3 0.1 $pct
        Add-SliderRow $win $c $T.SnowSize 'snowSize' 0.6 1.8 0.1 $pct
        Add-SliderRow $win $c $T.SnowSpeed 'snowSpeed' 0.4 2.5 0.1 { param($v) ([double]$v).ToString('0.0', $(if ($cs) { [Globalization.CultureInfo]::GetCultureInfo('cs-CZ') } else { [Globalization.CultureInfo]::InvariantCulture })) + '×' }
        Add-SliderRow $win $c $T.SnowWind 'snowWind' -60 60 5 { param($v) if ($v -eq 0) { $T.NoWind } elseif ($v -lt 0) { '← {0:0}' -f (-$v) } else { '{0:0} →' -f $v } }
        Add-SliderRow $win $c $T.SnowPile 'snowPile' 0 2.5 0.1 { param($v) if ($v -eq 0) { $T.NoPile } else { '{0:0} %' -f ($v * 100) } }
        $c = New-Card $p
        [void](Add-Row $c $T.SnowSettle $T.SnowSettleSub (New-Switch $win 'snowSettle') $null)
        [void](Add-Row $c $T.SnowCapture $T.SnowCaptureSub (New-Switch $win 'snowHideCapture') $null)
        [void](Add-Row $c $T.SnowSaver $T.SnowSaverSub (New-Switch $win 'snowSaver') $null)
        [void](Add-Row $c $T.SnowClear $null (New-Btn $win $T.SnowClearBtn { [Snow]::ClearRequested = $true }) $null)
    }

    # --- dock
    $p = $win.FindName('PageDock')
    $c = New-Card $p
    Add-SliderRow $win $c $T.DockSize 'dockSize' 36 80 2 { param($v) '{0:0} px' -f $v }
    [void](Add-Row $c $T.DockMagnify $null (New-Switch $win 'dockMagnify') $null)
    [void](Add-Row $c $T.DockLabels $null (New-Switch $win 'dockLabels') $null)
    [void](Add-Row $c $T.DockDots $null (New-Switch $win 'dockDots') $null)
    $c = New-Card $p
    [void](Add-Row $c $T.DockApps $T.DockAppsSub (New-Btn $win $T.DockAppsBtn { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $global:MacDeskApps + '"') }) $null)

    # --- widget
    $p = $win.FindName('PageWidget')
    $c = New-Card $p
    [void](Add-Row $c $T.WidgetOn $null (New-Switch $win 'widget') $null)
    [void](Add-Row $c $T.WidgetDate $null (New-Switch $win 'widgetDate') $null)
    [void](Add-Row $c $T.WidgetStats $null (New-Switch $win 'widgetStats') $null)

    # --- general
    $p = $win.FindName('PageGeneral')
    $c = New-Card $p
    $auto = New-Object System.Windows.Controls.CheckBox
    $auto.Style = $win.FindResource('Switch'); $auto.IsChecked = (Test-Path (Get-AutostartPath))
    $auto.Add_Click({ param($s, $e) try { Set-Autostart ([bool]$s.IsChecked) } catch {} })
    [void](Add-Row $c $T.GenAuto $T.GenAutoSub $auto $null)
    $c = New-Card $p
    [void](Add-Row $c $T.GenRestart $null (New-Btn $win $T.GenRestartBtn { $script:settingsWin.Close(); $script:restarting = $true; $dock.Close() }) $null)
    [void](Add-Row $c $T.GenQuit $null (New-Btn $win $T.GenQuitBtn { $script:settingsWin.Close(); $dock.Close() }) $null)
    $c = New-Card $p
    [void](Add-Row $c $T.GenAbout 'github.com/b33nthere/MacDesk' (New-Btn $win $T.GenRepo { Start-Process 'https://github.com/b33nthere/MacDesk' }) $null)

    # --- sidebar navigation
    if (-not $HasSnow) { $win.FindName('PageSnow').Visibility = 'Collapsed' }
    $pages = [ordered]@{}
    if ($HasSnow) { $pages['PageSnow'] = @($T.TabSnow, [string][char]0x2744, '#FF5AC8FA', $T.SnowHead, $T.SnowDesc) }
    $pages['PageDock'] = @($T.TabDock, [string][char]0x25AC, '#FF0A84FF', $T.DockHead, $T.DockDesc)
    $pages['PageWidget'] = @($T.TabWidget, [string][char]0x25F7, '#FFFF9F0A', $T.WidgetHead, $T.WidgetDesc)
    $pages['PageGeneral'] = @($T.TabGeneral, [string][char]0x2699, '#FF8E8E93', $T.GenHead, $T.GenDesc)
    $nav = $win.FindName('NavPanel')
    $script:navPages = $pages
    $first = $true
    foreach ($key in $pages.Keys) {
        $info = $pages[$key]
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $win.FindResource('Nav'); $rb.GroupName = 'nav'; $rb.Tag = $key
        $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'
        $ic = New-Object System.Windows.Controls.Border
        $ic.Width = 24; $ic.Height = 24; $ic.CornerRadius = 6; $ic.Background = New-Brush $info[2]; $ic.Margin = '0,0,10,0'
        $gl = New-Object System.Windows.Controls.TextBlock
        $gl.Text = $info[1]; $gl.Foreground = [System.Windows.Media.Brushes]::White; $gl.FontSize = 13
        $gl.FontFamily = 'Segoe UI Symbol'; $gl.HorizontalAlignment = 'Center'; $gl.VerticalAlignment = 'Center'
        $ic.Child = $gl
        $tx = New-Object System.Windows.Controls.TextBlock
        $tx.Text = $info[0]; $tx.Foreground = [System.Windows.Media.Brushes]::White; $tx.FontSize = 14; $tx.VerticalAlignment = 'Center'
        [void]$row.Children.Add($ic); [void]$row.Children.Add($tx)
        $rb.Content = $row
        $rb.Add_Checked({
            param($s, $e)
            $w = $script:settingsWin
            foreach ($k in $script:navPages.Keys) { $w.FindName($k).Visibility = if ($k -eq $s.Tag) { 'Visible' } else { 'Collapsed' } }
            $w.FindName('PageTitle').Text = $script:navPages[$s.Tag][3]
            $w.FindName('PageDesc').Text = $script:navPages[$s.Tag][4]
        })
        [void]$nav.Children.Add($rb)
        if ($first) { $rb.IsChecked = $true; $first = $false }
    }
    $win.Show()
    $win.Activate()
}

# fixed window width with room for magnified icons (the window never moves while animating)
$dock.Width = $items.Count * ($IconSize + 10) + 20 + 3 * $IconSize
function Place-Dock {
    $sw = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $sh = [System.Windows.SystemParameters]::PrimaryScreenHeight
    $dock.Left = [Math]::Round(($sw - $dock.ActualWidth) / 2)
    $dock.Top = $sh - $dock.ActualHeight - 4
}
$dock.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($dock)).Handle
    [MD]::ToolWindow($h)
})
$dock.Add_ContentRendered({
    Place-Dock
    if (-not $env:MACDESK_SHOT) {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($dock)).Handle
        $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($dock).DpiScaleY
        [MD]::ReserveBottom($h, [int](($IconSize + 40) * $scale))
        if ($HasSnow -and $Settings.snow) { Start-Snow }
    }
})
function Start-Snow {
    try {
        Apply-SnowSettings
        $hd = (New-Object System.Windows.Interop.WindowInteropHelper($dock)).Handle
        $hw = (New-Object System.Windows.Interop.WindowInteropHelper($widget)).Handle
        [Snow]::Start($dock.FindName('Bar'), $hd, $widget.FindName('Card'), $hw)
        Log "snow started"
    } catch { Log ("snow failed: " + $_.Exception.Message) }
}
$dock.Add_SizeChanged({ Place-Dock })

# hide the dock while a game or video runs fullscreen
$fsTimer = New-Object System.Windows.Threading.DispatcherTimer
$fsTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$fsTimer.Add_Tick({
    $hd = (New-Object System.Windows.Interop.WindowInteropHelper($dock)).Handle
    $hw = (New-Object System.Windows.Interop.WindowInteropHelper($widget)).Handle
    $full = [MD]::ForegroundIsFullscreen($hd, $hw)
    $want = if ($full) { 'Hidden' } else { 'Visible' }
    if ($dock.Visibility -ne $want) { $dock.Visibility = $want }
})

# running-app indicators
$runTimer = New-Object System.Windows.Threading.DispatcherTimer
$runTimer.Interval = [TimeSpan]::FromSeconds(2)
function Update-Dots {
    $running = @{}
    if ($Settings.dockDots) { Get-Process | ForEach-Object { $running[$_.ProcessName.ToLower()] = $true } }
    foreach ($it in $items) {
        $p = $it.App.proc
        $it.Dot.Visibility = if ($p -and $running.ContainsKey($p.ToLower())) { 'Visible' } else { 'Hidden' }
    }
}
$runTimer.Add_Tick({ Update-Dots })
$runTimer.Start()

# ---------------------------------------------------------------- WIDGET
$widgetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="False" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" Title="MacDesk Widget">
  <StackPanel Margin="20">
    <StackPanel.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.55" Color="Black"/>
    </StackPanel.Effect>
    <TextBlock x:Name="Clock" Text="00:00" Foreground="White" FontSize="96" FontWeight="Light"
               FontFamily="Segoe UI Variable Display, Segoe UI Light, Segoe UI"/>
    <TextBlock x:Name="Date" Text="" Foreground="#E6FFFFFF" FontSize="22" Margin="4,-8,0,18"
               FontFamily="Segoe UI Variable Display, Segoe UI"/>
    <Border x:Name="Card" CornerRadius="20" Background="#8C1C1C1E" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="18,14" Width="320" HorizontalAlignment="Left">
      <StackPanel x:Name="Stats"/>
    </Border>
  </StackPanel>
</Window>
'@
$widget = [System.Windows.Markup.XamlReader]::Parse($widgetXaml)
$clock = $widget.FindName('Clock')
$dateTb = $widget.FindName('Date')
$statsPanel = $widget.FindName('Stats')
$cz = if ($env:MACDESK_LANG) { [System.Globalization.CultureInfo]::GetCultureInfo($(if ($cs) { 'cs-CZ' } else { 'en-US' })) } else { [System.Globalization.CultureInfo]::CurrentCulture }

function New-StatRow($title, [string]$color) {
    $g = New-Object System.Windows.Controls.StackPanel
    $g.Margin = '0,6,0,6'
    $top = New-Object System.Windows.Controls.DockPanel
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $title; $t.Foreground = [System.Windows.Media.Brushes]::White; $t.FontSize = 14; $t.FontFamily = 'Segoe UI Variable Text, Segoe UI'
    $v = New-Object System.Windows.Controls.TextBlock
    $v.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(220, 255, 255, 255))
    $v.FontSize = 14; $v.HorizontalAlignment = 'Right'; $v.FontFamily = 'Segoe UI Variable Text, Segoe UI'
    [System.Windows.Controls.DockPanel]::SetDock($v, 'Right')
    [void]$top.Children.Add($v); [void]$top.Children.Add($t)
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 6; $track.CornerRadius = 3; $track.Margin = '0,6,0,0'
    $track.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(50, 255, 255, 255))
    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 6; $fill.CornerRadius = 3; $fill.HorizontalAlignment = 'Left'; $fill.Width = 0
    $fill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $track.Child = $fill
    [void]$g.Children.Add($top); [void]$g.Children.Add($track)
    [void]$statsPanel.Children.Add($g)
    return [pscustomobject]@{ Value = $v; Fill = $fill; Panel = $g }
}
$sysDrive = $env:SystemDrive.TrimEnd(':')
$rowCpu  = New-StatRow $T.Cpu '#FF0A84FF'
$rowRam  = New-StatRow $T.Ram '#FF30D158'
$rowGpu  = New-StatRow $T.Gpu '#FFFF9F0A'
$rowDisk = New-StatRow ("{0} {1}:" -f $T.Disk, $sysDrive) '#FFBF5AF2'
$BarW = 282

function Set-Bar($row, [double]$pct) {
    $w = [Math]::Max(0, [Math]::Min(1, $pct / 100)) * $BarW
    $an = New-Object System.Windows.Media.Animation.DoubleAnimation($w, [TimeSpan]::FromMilliseconds(400))
    $row.Fill.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $an)
}

$smiPath = 'C:\Windows\System32\nvidia-smi.exe'
if (Test-Path $smiPath) { [MD]::StartGpu($smiPath) } else { $rowGpu.Panel.Visibility = 'Collapsed' }
[void][MD]::Cpu()

function Update-Widget {
    $now = Get-Date
    $clock.Text = $now.ToString('HH:mm', $cz)
    $d = $now.ToString('dddd d. MMMM', $cz)
    $dateTb.Text = $d.Substring(0, 1).ToUpper() + $d.Substring(1)

    $cpu = [MD]::Cpu()
    $rowCpu.Value.Text = ('{0:0} %' -f $cpu); Set-Bar $rowCpu $cpu

    $ram = [MD]::Ram()
    $rowRam.Value.Text = ('{0:0.0} / {1:0} GB' -f $ram[0], $ram[1]); Set-Bar $rowRam (100 * $ram[0] / $ram[1])

    $g = [MD]::GpuLine
    if ($g) {
        $parts = $g.Split(',') | ForEach-Object { $_.Trim() }
        $rowGpu.Value.Text = ('{0} %  ·  {1} °C' -f $parts[0], $parts[1]); Set-Bar $rowGpu ([double]$parts[0])
    } else { $rowGpu.Value.Text = '–' }

    try {
        $drv = New-Object System.IO.DriveInfo($sysDrive)
        $free = $drv.AvailableFreeSpace / 1GB; $tot = $drv.TotalSize / 1GB
        $rowDisk.Value.Text = ('{0:0} GB {1}' -f $free, $T.Free); Set-Bar $rowDisk (100 * ($tot - $free) / $tot)
    } catch {}
}

$widget.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($widget)).Handle
    [MD]::ToolWindow($h)
    [MD]::SendToBottom($h)
})
$widget.Add_Activated({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($widget)).Handle
    [MD]::SendToBottom($h)
})
$widget.Add_ContentRendered({
    $widget.Left = 40
    $widget.Top = 30
})

$wTimer = New-Object System.Windows.Threading.DispatcherTimer
$wTimer.Interval = [TimeSpan]::FromSeconds(2)
$wTimer.Add_Tick({ Update-Widget })
$wTimer.Start()
Update-Widget

function Apply-WidgetSettings {
    $dateTb.Visibility = if ($Settings.widgetDate) { 'Visible' } else { 'Collapsed' }
    $widget.FindName('Card').Visibility = if ($Settings.widgetStats) { 'Visible' } else { 'Collapsed' }
    $want = if ($Settings.widget) { 'Visible' } else { 'Hidden' }
    if ($widget.Visibility -ne $want) { $widget.Visibility = $want }
}
Apply-WidgetSettings

# ---------------------------------------------------------------- start
$dock.Add_Closed({
    $runTimer.Stop(); $wTimer.Stop(); $fsTimer.Stop()
    if ($HasSnow) { try { [Snow]::Stop() } catch {} }
    try { if ($script:settingsWin) { $script:settingsWin.Close() } } catch {}
    [MD]::StopGpu()
    try { [MD]::ReleaseBottom((New-Object System.Windows.Interop.WindowInteropHelper($dock)).Handle) } catch {}
    try { $widget.Close() } catch {}
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
    if ($script:restarting) {
        # conhost --headless runs PowerShell with no console window at all
        # (-WindowStyle Hidden is ignored when Windows Terminal is the default terminal)
        $self = $global:MacDeskSelf
        Start-Process "$env:SystemRoot\System32\conhost.exe" -ArgumentList '--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $self + '"')
    }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

Log "windows ready, icons: $($items.Count)"
$widget.Show()
Log "widget shown"
$fsTimer.Start()
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$dock.Show()
Log ("dock shown: {0}x{1} @ {2},{3}" -f $dock.ActualWidth, $dock.ActualHeight, $dock.Left, $dock.Top)

# Screenshot mode for the README: renders only MacDesk's own windows onto a plain
# background (never captures the real screen), saves a PNG and quits.
if ($env:MACDESK_SHOT) {
    # demo values instead of this PC's real numbers
    $wTimer.Stop()
    $clock.Text = '9:41'
    $rowCpu.Value.Text = '12 %'; Set-Bar $rowCpu 12
    $rowRam.Value.Text = '9.8 / 32 GB'; Set-Bar $rowRam 31
    $rowGpu.Value.Text = '8 %  ·  41 °C'; Set-Bar $rowGpu 8; $rowGpu.Panel.Visibility = 'Visible'
    $rowDisk.Value.Text = '412 GB free'; Set-Bar $rowDisk 56
    $script:shotStep = 0
    $shotTimer = New-Object System.Windows.Threading.DispatcherTimer
    $shotTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
    $shotTimer.Add_Tick({
        $script:shotStep++
        $hi = [Math]::Min(2, $items.Count - 1)
        if ($script:shotStep -eq 1) {
            Set-Scales $hi
            $labelText.Text = $items[$hi].App.name
            $label.Visibility = 'Visible'
            return
        }
        if ($script:shotStep -eq 2) {
            $label.UpdateLayout()
            $p = $items[$hi].Slot.TranslatePoint((New-Object System.Windows.Point(($items[$hi].Slot.ActualWidth / 2), 0)), $labelCanvas)
            [System.Windows.Controls.Canvas]::SetLeft($label, $p.X - $label.ActualWidth / 2)
            [System.Windows.Controls.Canvas]::SetTop($label, 4)
            return
        }
        $shotTimer.Stop()
        $W = 1600; $H = 900
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $bg = New-Object System.Windows.Media.LinearGradientBrush
        $bg.StartPoint = New-Object System.Windows.Point(0, 0); $bg.EndPoint = New-Object System.Windows.Point(1, 1)
        foreach ($stop in @(@('#FF140C2E', 0.0), @('#FF4B2390', 0.55), @('#FF0A0A16', 1.0))) {
            $bg.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($stop[0]), $stop[1])))
        }
        $dc.DrawRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, $W, $H)))
        $wc = $widget.Content; $dkc = $dock.Content
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($wc)), $null, (New-Object System.Windows.Rect(30, 20, $wc.ActualWidth, $wc.ActualHeight)))
        $dkX = ($W - $dkc.ActualWidth) / 2; $dkY = $H - $dkc.ActualHeight
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($dkc)), $null, (New-Object System.Windows.Rect($dkX, $dkY, $dkc.ActualWidth, $dkc.ActualHeight)))
        if ($env:MACDESK_SHOT_SNOW) {
            # illustrative snow for the README picture (the real snow is drawn by Snow.cs)
            $rng = New-Object System.Random 7
            $white = [System.Windows.Media.Brushes]::White
            $pile = New-Object System.Windows.Media.LinearGradientBrush ([System.Windows.Media.Color]::FromRgb(255, 255, 255)), ([System.Windows.Media.Color]::FromRgb(226, 235, 247)), 90
            $drawPile = {
                param($x0, $x1, $y, $h)
                $g = New-Object System.Windows.Media.StreamGeometry
                $ctx = $g.Open()
                $ctx.BeginFigure((New-Object System.Windows.Point($x0, ($y + 0.5))), $true, $true)
                $n = [int](($x1 - $x0) / 3)
                for ($i = 0; $i -le $n; $i++) {
                    $t = $i / $n
                    $edge = [Math]::Min(1, [Math]::Min($t, 1 - $t) * 9)
                    $hh = $h * $edge * (0.82 + 0.18 * [Math]::Sin($i * 0.21) * [Math]::Cos($i * 0.07))
                    $ctx.LineTo((New-Object System.Windows.Point(($x0 + $i * 3), ($y - $hh))), $true, $true)
                }
                $ctx.LineTo((New-Object System.Windows.Point($x1, ($y + 0.5))), $true, $true)
                $ctx.Close(); $g.Freeze()
                $dc.DrawGeometry($pile, $null, $g)
            }
            $cardEl = $widget.FindName('Card')
            $cp = $cardEl.TranslatePoint((New-Object System.Windows.Point(0, 0)), $wc)
            & $drawPile (30 + $cp.X + 14) (30 + $cp.X + $cardEl.ActualWidth - 14) (20 + $cp.Y) 9
            & $drawPile 0 $W $H 12
            for ($i = 0; $i -lt 170; $i++) {
                $r = 1.0 + [Math]::Pow($rng.NextDouble(), 2.2) * 2.6
                $a = 0.45 + 0.5 * ($r - 1) / 2.6
                $rb = New-Object System.Windows.Media.RadialGradientBrush
                $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb([byte](255 * $a), 255, 255, 255), 0)))
                $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb([byte](220 * $a), 250, 252, 255), 0.45)))
                $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 240, 246, 255), 1)))
                $dc.DrawEllipse($rb, $null, (New-Object System.Windows.Point(($rng.NextDouble() * $W), ($rng.NextDouble() * ($H - 30)))), ($r * 1.6), ($r * 1.6))
            }
        }
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [System.IO.File]::Create($env:MACDESK_SHOT); $enc.Save($fs); $fs.Close()
        Log "screenshot saved"
        if (-not $env:MACDESK_SHOT_SETTINGS) { $dock.Close(); return }
        # also render the settings window (its own content only), at 2x for a sharp image
        Show-SettingsWindow
        $script:setTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:setTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
        $script:setTimer.Add_Tick({
            $script:setTimer.Stop()
            $root = $script:settingsWin.Content
            $sw2 = [int]$root.ActualWidth + 32; $sh2 = [int]$root.ActualHeight + 32
            $rtb2 = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(($sw2 * 2), ($sh2 * 2), 192, 192, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb2.Render($root)
            $enc2 = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc2.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb2))
            $fs2 = [System.IO.File]::Create($env:MACDESK_SHOT_SETTINGS); $enc2.Save($fs2); $fs2.Close()
            Log "settings screenshot saved"
            $dock.Close()
        })
        $script:setTimer.Start()
    })
    $shotTimer.Start()
}

[void]$app.Run()
