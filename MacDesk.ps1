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
    [System.Xaml.XamlReader].Assembly.Location
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
        RECT r; if (!GetWindowRect(h, out r)) return false;
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        return r.l <= 0 && r.t <= 0 && r.r >= sw && r.b >= sh;
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

# ---------------------------------------------------------------- texts (English / Czech)
$lang = if ($env:MACDESK_LANG) { $env:MACDESK_LANG } else { (Get-Culture).TwoLetterISOLanguageName }
$cs = $lang -eq 'cs'
$T = if ($cs) {
    @{ Edit = 'Upravit aplikace v doku…'; Restart = 'Restartovat MacDesk'; Quit = 'Ukončit MacDesk'
       Cpu = 'Procesor'; Ram = 'Paměť RAM'; Gpu = 'Grafika'; Disk = 'Disk'; Free = 'volno' }
} else {
    @{ Edit = 'Edit dock apps…'; Restart = 'Restart MacDesk'; Quit = 'Quit MacDesk'
       Cpu = 'CPU'; Ram = 'Memory'; Gpu = 'GPU'; Disk = 'Disk'; Free = 'free' }
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
$IconSize = 52
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
        if ($hoverIndex -ge 0) {
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

    $entry = [pscustomobject]@{ App = $a; Slot = $slot; Scale = $scale; Dot = $dot; Index = $index }
    [void]$items.Add($entry)
    $slot.Tag = $index

    $slot.Add_MouseEnter({
        param($s, $e)
        $i = [int]$s.Tag
        Set-Scales $i
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
[void]$menu.Items.Add($mi1); [void]$menu.Items.Add($mi2); [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator)); [void]$menu.Items.Add($mi3)
$dock.ContextMenu = $menu

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
$dock.Add_ContentRendered({ Place-Dock })
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
$runTimer.Add_Tick({
    $running = @{}
    Get-Process | ForEach-Object { $running[$_.ProcessName.ToLower()] = $true }
    foreach ($it in $items) {
        $p = $it.App.proc
        $it.Dot.Visibility = if ($p -and $running.ContainsKey($p.ToLower())) { 'Visible' } else { 'Hidden' }
    }
})
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
    <Border CornerRadius="20" Background="#8C1C1C1E" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="18,14" Width="320" HorizontalAlignment="Left">
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

# ---------------------------------------------------------------- start
$dock.Add_Closed({
    $runTimer.Stop(); $wTimer.Stop(); $fsTimer.Stop()
    [MD]::StopGpu()
    try { $widget.Close() } catch {}
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
    if ($script:restarting) {
        $self = $global:MacDeskSelf
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $self + '"')
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
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($dkc)), $null, (New-Object System.Windows.Rect((($W - $dkc.ActualWidth) / 2), ($H - $dkc.ActualHeight), $dkc.ActualWidth, $dkc.ActualHeight)))
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [System.IO.File]::Create($env:MACDESK_SHOT); $enc.Save($fs); $fs.Close()
        Log "screenshot saved"
        $dock.Close()
    })
    $shotTimer.Start()
}

[void]$app.Run()
