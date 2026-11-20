// MacDesk snow: flakes drift across every screen, settle on the tops of windows, the dock,
// the widget and the bottom of each screen, slide off a window when you move it and part
// under the cursor. Pauses while a fullscreen app (a game) is in front.
//
// Drawing: one click-through layered window per screen, painted by hand into a bitmap and
// handed to Windows with UpdateLayeredWindow, on its own thread paced by the compositor
// (DwmFlush), so it stays smooth and never touches MacDesk's UI thread. Only the pixels that
// changed are rewritten each frame. (WPF windows can't be used here: WPF removes
// WS_EX_LAYERED from GPU-rendered windows, which makes them catch every click.)
//
// Part of MacDesk (https://github.com/b33nthere/MacDesk) - MIT License.
// Written for C# 5 (the compiler Windows PowerShell 5.1 uses).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

public class SnowFlake { public double x, y, vx, vy, r, ph; public int b; public bool loose; }

public class SnowSurface
{
    public long key; public int l, r, t, bottom; public double maxH;
    public float[] h; public bool[] open; public bool seen, any;
    public double spillL, spillR, spillAtL, spillAtR;   // snow pouring off each edge, released in clumps
}

// one transparent, click-through window covering a screen
public class SnowLayer
{
    public int X, Y, W, H;
    public IntPtr Hwnd, MemDC, Bmp, OldBmp, Bits;
    public int[] Buf;                                     // our copy of the pixels (premultiplied BGRA)
    public List<int[]> Prev = new List<int[]>();          // rects drawn last frame (local x,y,w,h)
    public List<int[]> Cur = new List<int[]>();
    public bool Shown;
}

public static class Snow
{
    // ---------- options (set from MacDesk) ----------
    public static bool HideFromCapture = true;   // keep snow out of screenshots, OBS and Discord streams
    public static double Amount = 1.0;           // how much falls: 0.2 .. 3
    public static double SizeScale = 1.0;        // flake size: 0.6 .. 1.8
    public static double SpeedScale = 1.0;       // how fast it falls: 0.4 .. 2.5
    public static double WindBias = 0;           // steady wind in px/s: -60 (left) .. 60 (right)
    public static double PileScale = 1.0;        // how high drifts can get: 0 (no drifts) .. 2.5
    public static bool SettleOnWindows = true;   // settle on app windows (the dock, widget and ground always collect)
    public static volatile bool ClearRequested;  // sweep all settled snow off
    public static double Fps = 60;
    static bool dockHover;
    public static bool Running { get { return running; } }
    public static string LastProblem = "";

    const int CW = 3;                            // pile column width in px
    static volatile bool running;
    static bool paused;
    static Thread thread;
    static readonly List<SnowLayer> layers = new List<SnowLayer>();
    static readonly List<SnowFlake> flakes = new List<SnowFlake>();
    static readonly Dictionary<long, SnowSurface> surfs = new Dictionary<long, SnowSurface>();
    static readonly List<SnowSurface> active = new List<SnowSurface>();
    static readonly List<int[]> occ = new List<int[]>();   // l,t,r,b of windows above the current one
    static readonly List<int[]> mons = new List<int[]>();  // l,t,r,b
    static readonly Stopwatch clock = new Stopwatch();
    static double enumAcc, lastEnum, curEdt = 0.1, time, spawnAcc;
    static readonly Random rnd = new Random();
    static uint myPid;
    static double cx = -99999, cy = -99999, pcx = -99999, pcy = -99999, cvx, cvy; static bool cInit;
    static int ticks; static double dtSum, dtMax, dtSq, workSum;   // frame stats for Diag()
    static long drawnFlakes;
    static string monSig = "";

    // MacDesk's own dock bar and widget card: read on the UI thread, used on the snow thread
    static FrameworkElement bar, card; static IntPtr dockH, widgetH;
    static DispatcherTimer uiTimer;
    static readonly object elLock = new object();
    static int[] barRect, cardRect;              // l,t,r,b or null when hidden

    // ---------- public API (call from MacDesk's UI thread) ----------
    public static void Start(FrameworkElement dockBar, IntPtr dock, FrameworkElement widgetCard, IntPtr widget)
    {
        if (running) return;
        bar = dockBar; card = widgetCard; dockH = dock; widgetH = widget;
        myPid = (uint)Process.GetCurrentProcess().Id;
        LastProblem = "";
        ReadElements();
        if (uiTimer != null) uiTimer.Stop();
        uiTimer = new DispatcherTimer();
        uiTimer.Interval = TimeSpan.FromMilliseconds(100);
        uiTimer.Tick += delegate { ReadElements(); };
        uiTimer.Start();
        running = true;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Name = "MacDesk snow";
        thread.Start();
    }

    public static void Stop()
    {
        running = false;
        if (uiTimer != null) { uiTimer.Stop(); uiTimer = null; }
        Thread t = thread;
        if (t != null && t != Thread.CurrentThread) t.Join(2000);
        thread = null;
    }

    public static string Diag()
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("running=").Append(running).Append(" paused=").Append(paused).Append(" flakes=").Append(flakes.Count).Append(" drawn=").Append(drawnFlakes).Append(" problem=").Append(LastProblem);
        if (sprites != null) { int nz = 0; foreach (int v in sprites[(10 * 4 + 3) * SUB * SUB]) if (v != 0) nz++; sb.Append(" spritePx=").Append(nz); }
        if (flakes.Count > 0) { SnowFlake f0 = flakes[0]; sb.Append(String.Format(" f0=({0:0},{1:0} r={2:0.0} b={3})", f0.x, f0.y, f0.r, f0.b)); }
        if (layers.Count > 0) sb.Append(" L0=").Append(layers[0].X).Append(',').Append(layers[0].Y).Append(' ').Append(layers[0].W).Append('x').Append(layers[0].H);
        foreach (SnowLayer L in layers.ToArray()) sb.Append(" | layer ex=").Append(GetWindowLong(L.Hwnd, -20).ToString("X8"));
        if (ticks > 1)
        {
            double avg = dtSum / ticks, sd = Math.Sqrt(Math.Max(0, dtSq / ticks - avg * avg));
            sb.Append(String.Format(" | frames={0} avg={1:0.0}ms sd={2:0.0}ms max={3:0.0}ms work={4:0.00}ms",
                ticks, avg * 1000, sd * 1000, dtMax * 1000, workSum / ticks * 1000));
        }
        return sb.ToString();
    }

    static void ReadElements()
    {
        int[] b = ElementRect(bar), c = ElementRect(card);
        lock (elLock) { barRect = b; cardRect = c; }
    }

    static int[] ElementRect(FrameworkElement el)
    {
        if (el == null || !el.IsVisible || el.ActualWidth < 10) return null;
        try
        {
            Point a = el.PointToScreen(new Point(0, 0));
            Point b = el.PointToScreen(new Point(el.ActualWidth, el.ActualHeight));
            return new int[] { (int)Math.Round(a.X), (int)Math.Round(a.Y), (int)Math.Round(b.X), (int)Math.Round(b.Y) };
        }
        catch { return null; }
    }

    // ---------- the snow thread ----------
    static void Run()
    {
        timeBeginPeriod(1);
        try
        {
            MakeSprites();
            monSig = LoadMonitors();
            CreateLayers();
            flakes.Clear(); surfs.Clear(); active.Clear();
            int n = Target();
            for (int i = 0; i < n; i++) flakes.Add(NewFlake(true));
            clock.Restart();
            ticks = 0; dtSum = 0; dtSq = 0; dtMax = 0; workSum = 0; lastEnum = 0; paused = false;
            Enumerate();
            double lastFrame = clock.Elapsed.TotalSeconds, lastSlow = lastFrame;
            while (running)
            {
                MSG msg;
                while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
                double now = clock.Elapsed.TotalSeconds;
                if (now - lastSlow >= 0.5) { lastSlow = now; SlowCheck(); if (!running) break; }
                if (paused) { Thread.Sleep(100); lastFrame = clock.Elapsed.TotalSeconds; continue; }

                double frameSec = 1.0 / Math.Max(10, Math.Min(240, Fps));
                if (now - lastFrame >= frameSec - 0.003)
                {
                    double dt = now - lastFrame; lastFrame = now;
                    ticks++; dtSum += dt; dtSq += dt * dt; if (dt > dtMax) dtMax = dt;
                    Frame(Math.Min(dt, 0.05));
                    workSum += clock.Elapsed.TotalSeconds - now;
                }
                // wait for the compositor's next frame, so frames land evenly on the screen's refresh
                double before = clock.Elapsed.TotalSeconds;
                if (DwmFlush() != 0 || clock.Elapsed.TotalSeconds - before < 0.002) Thread.Sleep(1);
            }
        }
        catch (Exception ex) { LastProblem = ex.GetType().Name + ": " + ex.Message; }
        finally
        {
            running = false;
            DestroyLayers();
            timeEndPeriod(1);
        }
    }

    static void SlowCheck()
    {
        // safety: a layer that catches clicks would lock the whole desktop - switch snow off
        foreach (SnowLayer L in layers)
        {
            int ex = GetWindowLong(L.Hwnd, -20);
            if ((ex & 0x80020) != 0x80020) { LastProblem = "layer lost click-through, ex=" + ex.ToString("X8"); running = false; return; }
        }
        // screens changed (monitor plugged in, resolution changed) -> rebuild the layers
        string sig = LoadMonitors();
        if (sig != monSig)
        {
            monSig = sig;
            DestroyLayers(); CreateLayers();
            flakes.Clear(); surfs.Clear(); active.Clear();
            return;
        }
        bool full = FullscreenForeground();
        if (full && !paused)
        {
            paused = true;
            foreach (SnowLayer L in layers) ShowWindow(L.Hwnd, 0);
        }
        else if (!full && paused)
        {
            paused = false;
            foreach (SnowLayer L in layers) ShowWindow(L.Hwnd, 4);   // SW_SHOWNOACTIVATE
        }
        if (!paused)
            foreach (SnowLayer L in layers)
            {
                SetWindowPos(L.Hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0013); // stay on top
                SetWindowDisplayAffinity(L.Hwnd, HideFromCapture ? 0x11u : 0u);
            }
    }

    static void Frame(double dt)
    {
        time += dt;
        if (ClearRequested)
        {
            ClearRequested = false;
            foreach (SnowSurface s in surfs.Values) Release(s, 0, -40);
        }
        enumAcc += dt;
        if (enumAcc >= 0.1) { enumAcc = 0; Enumerate(); }
        UpdateCursor(dt);
        Step(dt);
        foreach (SnowLayer L in layers) Paint(L);
    }

    // ---------- simulation ----------
    static int Target()
    {
        double total = 0;
        foreach (int[] m in mons) total += m[2] - m[0];
        return (int)(total * 0.075 * Amount);
    }

    static SnowFlake NewFlake(bool anywhere)
    {
        double total = 0;
        foreach (int[] mm in mons) total += mm[2] - mm[0];
        double pick = rnd.NextDouble() * total;
        int[] m = mons[0];
        foreach (int[] mm in mons) { double w = mm[2] - mm[0]; if (pick < w) { m = mm; break; } pick -= w; }
        SnowFlake f = new SnowFlake();
        f.x = m[0] + rnd.NextDouble() * (m[2] - m[0]);
        f.y = anywhere ? m[1] + rnd.NextDouble() * (m[3] - m[1]) : m[1] - 4 - rnd.NextDouble() * 40;
        double r0 = 1.0 + Math.Pow(rnd.NextDouble(), 2.2) * 2.6;
        f.r = r0 * SizeScale;
        f.vy = (22 + r0 * 13) * SpeedScale;
        f.ph = rnd.NextDouble() * Math.PI * 2;
        f.b = r0 > 2.6 ? 3 : r0 > 1.9 ? 2 : r0 > 1.35 ? 1 : 0;
        return f;
    }

    static SnowFlake Loose(double x, double y, double vx, double vy)
    {
        SnowFlake f = new SnowFlake();
        f.x = x; f.y = y; f.vx = vx; f.vy = vy; f.loose = true;
        double r0 = 1.0 + rnd.NextDouble() * 1.4;
        f.r = r0 * SizeScale; f.ph = rnd.NextDouble() * 6.28;
        f.b = r0 > 1.9 ? 2 : 1;
        return f;
    }

    // how much snow (px^2) a flake adds to a pile when it lands
    static double Volume(SnowFlake f) { return Math.PI * f.r * f.r * 0.9; }

    // Turn an amount of settled snow back into loose flakes - exactly as much snow as was taken,
    // never more, so snow thrown up and landing again can't multiply.
    static double shed;
    static void Shed(double vol, double x, double xJit, double y, double yJit, double vx, double vxJit, double vy, double vyJit)
    {
        shed += vol;
        while (shed > 0)
        {
            SnowFlake f = Loose(x + rnd.NextDouble() * xJit, y - rnd.NextDouble() * yJit,
                vx + (rnd.NextDouble() - 0.5) * vxJit, vy - rnd.NextDouble() * vyJit);
            double fv = Volume(f);
            if (fv > shed)
            {
                if (rnd.NextDouble() < shed / fv && flakes.Count < 1600) flakes.Add(f);
                shed = 0;
                break;
            }
            shed -= fv;
            if (flakes.Count < 1600) flakes.Add(f);
        }
    }

    static void Step(double dt)
    {
        int target = Target();
        int normal = 0;
        double wind = Math.Sin(time * 0.05) * 9 + Math.Sin(time * 0.17 + 1.3) * 5 + WindBias;
        const double R = 90, R2 = R * R;

        // while the cursor is on the dock, snow doesn't settle there (it would cover the icons)
        dockHover = false;
        SnowSurface dk;
        if (surfs.TryGetValue(1, out dk))
            dockHover = cx >= dk.l - 10 && cx < dk.r + 10 && cy >= dk.t - 70 && cy <= dk.bottom + 4;

        for (int i = flakes.Count - 1; i >= 0; i--)
        {
            SnowFlake f = flakes[i];
            if (f.loose)
            {
                f.vy += 420 * dt; if (f.vy > 260) f.vy = 260;
                f.vx -= f.vx * Math.Min(1, 1.2 * dt);
            }
            else
            {
                normal++;
                double term = (22 + f.r / SizeScale * 13) * SpeedScale;
                f.vy += (term - f.vy) * Math.Min(1, 2 * dt);
                double tvx = wind + Math.Sin(time * (0.6 + f.r * 0.15) + f.ph) * (6 + f.r * 4);
                f.vx += (tvx - f.vx) * Math.Min(1, 1.5 * dt);
            }
            double dx = f.x - cx, dy = f.y - cy, d2 = dx * dx + dy * dy;
            if (d2 < R2 && d2 > 0.01)
            {
                double d = Math.Sqrt(d2), k = 1 - d / R;
                f.vx += (dx / d * 700 * k + cvx * 2.5 * k) * dt;
                f.vy += (dy / d * 500 * k + cvy * 2.5 * k) * dt;
            }
            if (f.vx > 1500) f.vx = 1500; else if (f.vx < -1500) f.vx = -1500;
            if (f.vy > 1500) f.vy = 1500; else if (f.vy < -1500) f.vy = -1500;

            double nx = f.x + f.vx * dt, ny = f.y + f.vy * dt;
            if (f.vy > 0 && Land(f, nx, ny)) { RemoveAt(i); continue; }
            f.x = nx; f.y = ny;

            int[] m = MonAt(f.x, f.y);
            if (m == null) m = MonAtX(f.x);
            if (m == null || f.y > m[3] + 4 || f.y < m[1] - 300) RemoveAt(i);
        }

        // new flakes from the top
        if (normal < target)
        {
            spawnAcc += target * dt / 7.0;
            while (spawnAcc >= 1 && normal < target) { flakes.Add(NewFlake(false)); spawnAcc -= 1; normal++; }
        }
        else spawnAcc = 0;

        // melt slowly, even out, sweep with the cursor, shake the dock pile off when hovering the dock
        foreach (SnowSurface s in active)
        {
            if (!s.any) continue;
            bool anyLeft = false;
            double melt = (s.maxH * 0.0006 + 0.0015) * dt, frac = 0.0012 * dt, spread = Math.Min(0.25, dt * 0.8);
            int nn = s.h.Length;
            float prev = 0;
            for (int c = 0; c < nn; c++)
            {
                float cur = s.h[c];
                if (cur <= 0 && (c + 1 >= nn || s.h[c + 1] <= 0) && prev <= 0) { prev = cur; continue; }
                double v = cur;
                if (s.open[c])
                {
                    bool lo = c > 0 && s.open[c - 1], ro = c + 1 < nn && s.open[c + 1];
                    if (lo) v += (prev - cur) * spread;
                    if (ro) v += (s.h[c + 1] - cur) * spread;
                }
                v -= v * frac + melt;
                prev = cur;
                s.h[c] = v > 0 ? (float)v : 0f;
                if (v > 0) anyLeft = true;
            }
            s.any = anyLeft;
            if (!s.any) continue;

            if (s.key == 1 && dockHover)
            {
                SlideOff(s, dt);
                continue;
            }
            if (s.key > -10) MaybeBreakOff(s, dt);         // not the bottom of the screen
            // sweep along the whole path the cursor took since the last frame, so a fast
            // swipe clears a continuous trench instead of a row of separate dents
            double minX = Math.Min(pcx, cx), maxX = Math.Max(pcx, cx), minY = Math.Min(pcy, cy), maxY = Math.Max(pcy, cy);
            if (maxX < s.l - 16 || minX > s.r + 16 || maxY < s.t - s.maxH - 12 || minY > s.t + 6) continue;
            double len = Math.Sqrt((cx - pcx) * (cx - pcx) + (cy - pcy) * (cy - pcy));
            int steps = Math.Max(1, (int)Math.Ceiling(len / 6.0));
            if (steps > 400) steps = 400;
            for (int st = 1; st <= steps; st++)
            {
                double k = (double)st / steps;
                Carve(s, pcx + (cx - pcx) * k, pcy + (cy - pcy) * k);
            }
        }
    }

    static void Carve(SnowSurface s, double x, double y)
    {
        if (x < s.l - 16 || x > s.r + 16 || y < s.t - s.maxH - 12 || y > s.t + 6) return;
        int c0 = Math.Max(0, (int)((x - 16 - s.l) / CW)), c1 = Math.Min(s.h.Length - 1, (int)((x + 16 - s.l) / CW));
        for (int c = c0; c <= c1; c++)
        {
            if (!s.open[c]) continue;
            double colX = s.l + c * CW + CW * 0.5;
            double keep = Math.Max(0, s.t - y - 3 + Math.Abs(colX - x) * 0.4);
            if (s.h[c] > keep + 0.3)
            {
                double removed = s.h[c] - keep;
                s.h[c] = (float)keep;
                double side = colX < x ? -1 : 1;
                Shed(removed * CW, colX - CW * 0.5, CW, s.t - keep, removed,
                    Clamp(cvx * 0.45, 700) + side * 85, 90,
                    -50 + Math.Max(-300, Math.Min(0, cvy * 0.3)), 130);
            }
        }
    }

    static void RemoveAt(int i)
    {
        int end = flakes.Count - 1;
        flakes[i] = flakes[end];
        flakes.RemoveAt(end);
    }

    static bool Land(SnowFlake f, double nx, double ny)
    {
        SnowSurface best = null; int bc = 0; double bt = double.MaxValue;
        foreach (SnowSurface s in active)
        {
            if (nx < s.l || nx >= s.r) continue;
            if (s.key == 1 && dockHover) continue;
            int c = (int)((nx - s.l) / CW);
            if (c < 0 || c >= s.h.Length || !s.open[c]) continue;
            double top = s.t - s.h[c];
            if (f.y <= top && ny >= top && top < bt) { bt = top; best = s; bc = c; }
        }
        if (best == null) return false;
        // a big flake is spread as several small portions so the pile stays smooth
        double amt = Volume(f) / CW;
        while (amt > 0.001)
        {
            double part = Math.Min(0.45, amt);
            Deposit(best, bc, part, f.vx);
            amt -= part;
        }
        return true;
    }

    // snow rests where it lands unless the slope gets too steep - then it slides, and off the edge it falls
    static void Deposit(SnowSurface s, int c, double amt, double vx)
    {
        int n = s.h.Length;
        for (int k = 0; k < 14; k++)
        {
            int a = c - 1, b = c + 1;
            bool ea = a < 0 || !s.open[a], eb = b >= n || !s.open[b];
            double ha = ea ? -1 : s.h[a], hb = eb ? -1 : s.h[b];
            int nb; double hn; bool edge;
            if (ha < hb || (ha == hb && rnd.Next(2) == 0)) { nb = a; hn = ha; edge = ea; }
            else { nb = b; hn = hb; edge = eb; }
            double hc = s.h[c] + amt;
            bool slide = edge ? hc > 1.8 : hc - hn > 1.6;
            if (!slide)
            {
                if (hc > s.maxH) { Overflow(s, c, hc - s.maxH); return; }
                s.h[c] = (float)hc;
                s.any = true;
                return;
            }
            if (edge)
            {
                EdgeSpill(s, c, nb < c ? -1 : 1, amt);
                return;
            }
            c = nb;
        }
        s.h[c] = (float)Math.Min(s.h[c] + amt, s.maxH);
        s.any = true;
    }

    // a full pile: the extra snow creeps along the top towards the nearer edge and pours off there
    static void Overflow(SnowSurface s, int c, double extra)
    {
        int n = s.h.Length;
        s.h[c] = (float)s.maxH;
        s.any = true;
        int dir = c < n / 2 ? -1 : 1;
        int j = c;
        while (extra > 0.001)
        {
            int nj = j + dir;
            if (nj < 0 || nj >= n || !s.open[nj]) { EdgeSpill(s, j, dir, extra); return; }
            j = nj;
            double room = s.maxH - s.h[j];
            if (room > 0.05)
            {
                double put = Math.Min(room, extra);
                s.h[j] += (float)put; extra -= put;
            }
        }
    }

    // snow falling off an edge collects for a moment and drops as a clump, not grain by grain
    static void EdgeSpill(SnowSurface s, int c, int dir, double amt)
    {
        double vol = amt * CW;
        double ex = s.l + (dir > 0 ? (c + 1) * CW : c * CW) + dir * 2.0;
        double ey = s.t - s.h[c] - 1;
        if (dir < 0)
        {
            s.spillL += vol;
            if (s.spillAtL <= 0) s.spillAtL = 35 + rnd.NextDouble() * 90;
            if (s.spillL >= s.spillAtL) { Clump(s.spillL, ex, ey, -1); s.spillL = 0; s.spillAtL = 0; }
        }
        else
        {
            s.spillR += vol;
            if (s.spillAtR <= 0) s.spillAtR = 35 + rnd.NextDouble() * 90;
            if (s.spillR >= s.spillAtR) { Clump(s.spillR, ex, ey, 1); s.spillR = 0; s.spillAtR = 0; }
        }
    }

    // a lump of snow that falls together
    static void Clump(double vol, double x, double y, int dir)
    {
        double vx = dir * (18 + rnd.NextDouble() * 30), vy = rnd.NextDouble() * 15;
        double size = Math.Sqrt(vol) * 0.5 + 2;
        Shed(vol, x - (dir < 0 ? size : 0), size, y + size * 0.5, size, vx, 14, vy, 12);
    }

    // now and then a full pile breaks at an edge and a slab of snow slides off
    static void MaybeBreakOff(SnowSurface s, double dt)
    {
        if (rnd.NextDouble() > dt * 0.25) return;           // look about every 4 s
        int n = s.h.Length, open = 0, full = 0, first = -1, last = -1;
        for (int c = 0; c < n; c++)
        {
            if (!s.open[c]) continue;
            open++; if (first < 0) first = c; last = c;
            if (s.h[c] > s.maxH * 0.8) full++;
        }
        if (open < 12 || full < open * 0.5) return;
        int dir = rnd.Next(2) == 0 ? -1 : 1;
        int width = Math.Min(open / 3, 5 + rnd.Next(14));
        double vx = dir * (25 + rnd.NextDouble() * 35);
        for (int k = 0; k < width; k++)
        {
            int c = dir < 0 ? first + k : last - k;
            if (c < 0 || c >= n || !s.open[c]) break;
            double take = s.h[c] * (0.45 + 0.4 * (1 - (double)k / width));
            s.h[c] -= (float)take;
            double x = s.l + c * CW;
            Shed(take * CW, x, CW, s.t - s.h[c], take, vx + (rnd.NextDouble() - 0.5) * 10, 8, -8 + rnd.NextDouble() * 6, 10);
        }
    }

    // while the cursor is on the dock the snow slides off it: fast right by the cursor, slowly elsewhere
    static void SlideOff(SnowSurface s, double dt)
    {
        int n = s.h.Length;
        bool left = false;
        for (int c = 0; c < n; c++)
        {
            if (s.h[c] <= 0.02 || !s.open[c]) continue;
            double colX = s.l + c * CW + CW * 0.5;
            double d = Math.Abs(colX - cx);
            double rate = d < 45 ? 4.0 : d < 200 ? 0.5 + 3.5 * (1 - (d - 45) / 155) : 0.5;   // share per second
            double take = s.h[c] * Math.Min(1, rate * dt);
            if (s.h[c] - take < 0.05) take = s.h[c];
            s.h[c] -= (float)take;
            if (s.h[c] > 0) left = true;
            double dir = colX < cx ? -1 : 1;
            double push = d < 45 ? 90 : 30;
            Shed(take * CW, colX - CW * 0.5, CW, s.t - s.h[c], take, dir * push + Clamp(cvx * 0.3, 300), 40, -25 - (d < 45 ? 60 : 0), 40);
        }
        s.any = left;
    }

    // the pile falls off as loose snow (window moved, closed or minimized)
    static void Release(SnowSurface s, double vx, double vy)
    {
        if (!s.any) return;
        for (int c = 0; c < s.h.Length; c++)
        {
            double hh = s.h[c];
            s.h[c] = 0;
            if (hh < 0.05 || !s.open[c]) continue;
            Shed(hh * CW, s.l + c * CW, CW, s.t, hh, Clamp(vx * 0.5, 900), 50, Clamp(vy * 0.5, 900), 30);
        }
        s.any = false;
    }

    static double Clamp(double v, double m) { return v > m ? m : v < -m ? -m : v; }

    static void UpdateCursor(double dt)
    {
        POINT p; if (!GetCursorPos(out p)) return;
        if (!cInit) { cx = p.x; cy = p.y; pcx = cx; pcy = cy; cInit = true; }
        double vx = (p.x - cx) / dt, vy = (p.y - cy) / dt;
        double k = Math.Min(1, dt * 12);
        cvx += (vx - cvx) * k; cvy += (vy - cvy) * k;
        pcx = cx; pcy = cy;
        cx = p.x; cy = p.y;
    }

    // ---------- what the snow can settle on ----------
    static readonly EnumProc enumCb = OnWindow;

    static void Enumerate()
    {
        double now = clock.Elapsed.TotalSeconds;
        curEdt = Math.Max(0.05, now - lastEnum); lastEnum = now;
        foreach (SnowSurface s in surfs.Values) s.seen = false;
        occ.Clear(); active.Clear();
        EnumWindows(enumCb, IntPtr.Zero);                     // top to bottom in z-order
        for (int i = 0; i < mons.Count; i++)
        {
            int[] m = mons[i];
            Surface(-10 - i, m[0], m[2], m[3], 18, 0, m[3]);   // the bottom of each screen
        }
        List<long> gone = new List<long>();
        foreach (KeyValuePair<long, SnowSurface> kv in surfs) if (!kv.Value.seen) gone.Add(kv.Key);
        foreach (long k in gone) { Release(surfs[k], 0, 0); surfs.Remove(k); }
    }

    static bool OnWindow(IntPtr h, IntPtr l)
    {
        if (!IsWindowVisible(h) || IsIconic(h)) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (pid == myPid)
        {
            int[] br, cr;
            lock (elLock) { br = barRect; cr = cardRect; }
            if (h == dockH && br != null) ElementSurface(1, br, 8, 18);
            else if (h == widgetH && cr != null) ElementSurface(2, cr, 10, 16);
            return true;
        }
        int cloaked;
        if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
        int ex = GetWindowLong(h, -20);
        if ((ex & 0x80) != 0 || (ex & 0x20) != 0) return true;   // tool windows, click-through overlays
        if (GetWindowTextLength(h) == 0) return true;
        StringBuilder sb = new StringBuilder(64);
        GetClassName(h, sb, 64);
        string cls = sb.ToString();
        if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return true;
        RECT r;
        if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) GetWindowRect(h, out r);
        if (r.r - r.l < 80 || r.b - r.t < 40) return true;
        int[] m = MonAt((r.l + r.r) / 2, Math.Max(r.t, 0) + 1);
        bool atTop = m != null && r.t <= m[1] + 1;            // maximized: nothing can fall on it
        if (!atTop && SettleOnWindows) Surface(h.ToInt64(), r.l, r.r, r.t, 10, 6, r.b);
        occ.Add(new int[] { r.l, r.t, r.r, r.b });
        return true;
    }

    static void ElementSurface(long key, int[] rc, double maxH, int inset)
    {
        Surface(key, rc[0], rc[2], rc[1], maxH, inset, rc[3]);
        occ.Add(new int[] { rc[0], rc[1], rc[2], rc[3] });
    }

    static void Surface(long key, int l, int r, int t, double maxH, int inset, int bottom)
    {
        SnowSurface s;
        int n = Math.Max(1, (r - l) / CW);
        if (surfs.TryGetValue(key, out s))
        {
            if (s.l != l || s.r != r || s.t != t)
            {
                Release(s, (l - s.l) / curEdt, (t - s.t) / curEdt);
                s.l = l; s.r = r; s.t = t;
                if (s.h.Length != n) { s.h = new float[n]; s.open = new bool[n]; }
            }
        }
        else
        {
            s = new SnowSurface();
            s.key = key; s.l = l; s.r = r; s.t = t; s.maxH = maxH;
            s.h = new float[n]; s.open = new bool[n];
            surfs[key] = s;
        }
        s.bottom = bottom;
        s.maxH = maxH * PileScale;
        s.seen = true;
        int probe = t - 2;
        for (int c = 0; c < n; c++)
        {
            int x = l + c * CW + CW / 2;
            bool o = c * CW >= inset && (n - c) * CW >= inset && MonAt(x, probe < 0 ? 0 : probe) != null;
            if (o) foreach (int[] q in occ) if (x >= q[0] && x < q[2] && probe >= q[1] && probe < q[3]) { o = false; break; }
            s.open[c] = o;
        }
        active.Add(s);
    }

    // ---------- drawing ----------
    // flake sprites: [size][brightness][sub-pixel x][sub-pixel y], premultiplied white
    // sizes: flake radius 0.6 .. 6.35 px in steps of 0.25 (big enough for the largest size setting)
    const int SP = 24, SUB = 4, NSIZE = 24;
    const double RMIN = 0.6, RSTEP = 0.25;
    static int[][] sprites;
    static readonly double[] alphaLevels = { 0.5, 0.66, 0.82, 0.95 };

    static void MakeSprites()
    {
        if (sprites != null) return;
        int[][] all = new int[NSIZE * 4 * SUB * SUB][];
        for (int si = 0; si < NSIZE; si++)
        {
            double rr = (RMIN + si * RSTEP) * 1.6;
            for (int ai = 0; ai < 4; ai++)
                for (int sx = 0; sx < SUB; sx++)
                    for (int sy = 0; sy < SUB; sy++)
                    {
                        int[] px = new int[SP * SP];
                        double ccx = SP / 2 + (sx + 0.5) / SUB, ccy = SP / 2 + (sy + 0.5) / SUB;
                        for (int y = 0; y < SP; y++)
                            for (int x = 0; x < SP; x++)
                            {
                                double ex = x + 0.5 - ccx, ey = y + 0.5 - ccy;
                                if (ex * ex + ey * ey > (rr + 1.5) * (rr + 1.5)) continue;
                                double acc = 0;
                                for (int qy = 0; qy < 3; qy++)
                                    for (int qx = 0; qx < 3; qx++)
                                    {
                                        double ux = x + (qx + 0.5) / 3 - ccx, uy = y + (qy + 0.5) / 3 - ccy;
                                        double d = Math.Sqrt(ux * ux + uy * uy) / rr;
                                        acc += d < 0.45 ? 1 - d * 0.2 : d < 1 ? 0.91 * Math.Pow((1 - d) / 0.55, 1.6) : 0;
                                    }
                                int a = (int)Math.Round(255 * alphaLevels[ai] * acc / 9);
                                if (a < 0) a = 0; if (a > 255) a = 255;
                                px[y * SP + x] = (a << 24) | (a << 16) | (a << 8) | a;
                            }
                        all[((si * 4 + ai) * SUB + sx) * SUB + sy] = px;
                    }
        }
        sprites = all;
    }

    static void Paint(SnowLayer L)
    {
        int W = L.W, H = L.H;
        int[] buf = L.Buf;
        // erase what was drawn last frame
        foreach (int[] rc in L.Prev)
            for (int y = rc[1]; y < rc[1] + rc[3]; y++) Array.Clear(buf, y * W + rc[0], rc[2]);
        L.Cur.Clear();

        foreach (SnowSurface s in active)
        {
            if (!s.any) continue;
            if (s.r < L.X || s.l > L.X + W || s.t < L.Y || s.t - s.maxH - 3 > L.Y + H) continue;
            PaintPile(L, s);
        }

        int x0 = L.X - SP, x1 = L.X + W, y0 = L.Y - SP, y1 = L.Y + H;
        foreach (SnowFlake f in flakes)
        {
            if (f.x < x0 || f.x > x1 || f.y < y0 || f.y > y1) continue;
            double lx = f.x - L.X, ly = f.y - L.Y;
            int fx = (int)Math.Floor(lx), fy = (int)Math.Floor(ly);
            int sx = (int)((lx - fx) * SUB), sy = (int)((ly - fy) * SUB);
            int si = (int)Math.Round((f.r - RMIN) / RSTEP); if (si < 0) si = 0; if (si >= NSIZE) si = NSIZE - 1;
            int[] sp = sprites[((si * 4 + f.b) * SUB + sx) * SUB + sy];
            int ox = fx - SP / 2, oy = fy - SP / 2;
            int ext = (int)((RMIN + si * RSTEP) * 1.6) + 2;          // only the pixels the flake covers
            int ax = Math.Max(0, Math.Max(ox, fx - ext)), ay = Math.Max(0, Math.Max(oy, fy - ext));
            int bx = Math.Min(W, Math.Min(ox + SP, fx + ext + 2)), by = Math.Min(H, Math.Min(oy + SP, fy + ext + 2));
            if (ax >= bx || ay >= by) continue;
            for (int y = ay; y < by; y++)
            {
                int row = y * W, srow = (y - oy) * SP - ox;
                for (int x = ax; x < bx; x++)
                {
                    int s = sp[srow + x];
                    if (s == 0) continue;
                    int d = buf[row + x];
                    buf[row + x] = d == 0 ? s : Over(s, d);
                }
            }
            L.Cur.Add(new int[] { ax, ay, bx - ax, by - ay });
            drawnFlakes++;
        }

        // hand the changed areas to Windows
        int dl = int.MaxValue, dt = int.MaxValue, dr = int.MinValue, db = int.MinValue;
        foreach (int[] rc in L.Prev) { Copy(L, rc); Grow(rc, ref dl, ref dt, ref dr, ref db); }
        foreach (int[] rc in L.Cur) { Copy(L, rc); Grow(rc, ref dl, ref dt, ref dr, ref db); }
        List<int[]> tmp = L.Prev; L.Prev = L.Cur; L.Cur = tmp;
        if (dl < dr && dt < db) Present(L, dl, dt, dr, db);
    }

    static void Grow(int[] rc, ref int l, ref int t, ref int r, ref int b)
    {
        if (rc[0] < l) l = rc[0]; if (rc[1] < t) t = rc[1];
        if (rc[0] + rc[2] > r) r = rc[0] + rc[2]; if (rc[1] + rc[3] > b) b = rc[1] + rc[3];
    }

    static void Copy(SnowLayer L, int[] rc)
    {
        for (int y = rc[1]; y < rc[1] + rc[3]; y++)
        {
            int off = y * L.W + rc[0];
            Marshal.Copy(L.Buf, off, new IntPtr(L.Bits.ToInt64() + (long)off * 4), rc[2]);
        }
    }

    static int Over(int s, int d)
    {
        int sa = (s >> 24) & 255, inv = 255 - sa;
        int a = sa + (((d >> 24) & 255) * inv + 127) / 255;
        int r = (s >> 16 & 255) + (((d >> 16) & 255) * inv + 127) / 255;
        int g = (s >> 8 & 255) + (((d >> 8) & 255) * inv + 127) / 255;
        int b = (s & 255) + ((d & 255) * inv + 127) / 255;
        if (a > 255) a = 255; if (r > a) r = a; if (g > a) g = a; if (b > a) b = a;
        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    static void PaintPile(SnowLayer L, SnowSurface s)
    {
        int n = s.h.Length, c = 0, W = L.W, H = L.H;
        int[] buf = L.Buf;
        while (c < n)
        {
            while (c < n && (!s.open[c] || s.h[c] < 0.25)) c++;
            if (c >= n) break;
            int a = c;
            while (c < n && s.open[c] && s.h[c] >= 0.25) c++;
            int b = c;                                           // columns [a, b)
            int gx0 = s.l + a * CW, gx1 = s.l + b * CW;          // pixels [gx0, gx1)
            int lx0 = Math.Max(0, gx0 - L.X), lx1 = Math.Min(W, gx1 - L.X);
            if (lx0 >= lx1) continue;
            int base0 = s.t - L.Y;                               // the surface line (local)
            int top = H, bottom = -1;
            for (int lx = lx0; lx < lx1; lx++)
            {
                // smoothed height at this pixel, tapering at the ends of the run
                double u = (lx + L.X + 0.5 - s.l) / CW - 0.5;
                int c0 = (int)Math.Floor(u); double fr = u - c0;
                double h0 = Smooth(s, c0, a, b), h1 = Smooth(s, c0 + 1, a, b);
                double hh = h0 + (h1 - h0) * fr;
                if (hh <= 0.05) continue;
                double yTop = base0 - hh;                        // fractional top of the snow
                int yStart = (int)Math.Floor(yTop), yEnd = base0;
                for (int y = Math.Max(0, yStart - 1); y <= Math.Min(H - 1, yEnd); y++)
                {
                    double cover;
                    if (y < yStart) cover = 0;
                    else if (y == yStart) cover = 1 - (yTop - yStart);
                    else cover = 1;
                    int px;
                    if (y == yStart - 1 || cover <= 0)
                    {
                        px = (40 << 24) | (26 << 16) | (30 << 8) | 36;   // faint outline above the snow
                    }
                    else
                    {
                        double g = hh > 1 ? (y - yTop) / hh : 0;          // 0 at the top, 1 at the bottom
                        int A = (int)(255 * Math.Min(1, cover));
                        int R = (int)((255 - 29 * g) * A / 255), G = (int)((255 - 20 * g) * A / 255), B = (int)((255 - 8 * g) * A / 255);
                        px = (A << 24) | (R << 16) | (G << 8) | B;
                        if (y == yStart && cover < 1)
                        {
                            int d = buf[y * W + lx];
                            if (d != 0) px = Over(px, d);
                        }
                    }
                    int idx = y * W + lx;
                    buf[idx] = buf[idx] == 0 || (px >> 24 & 255) == 255 ? px : Over(px, buf[idx]);
                    if (y < top) top = y; if (y > bottom) bottom = y;
                }
            }
            if (bottom >= top) L.Cur.Add(new int[] { lx0, top, lx1 - lx0, bottom - top + 1 });
        }
    }

    static double Smooth(SnowSurface s, int c, int a, int b)
    {
        if (c < a) return s.h[a] * 0.4;
        if (c >= b) return s.h[b - 1] * 0.4;
        double hl = c > a ? s.h[c - 1] : s.h[c] * 0.4;
        double hr = c < b - 1 ? s.h[c + 1] : s.h[c] * 0.4;
        return (hl + 2 * s.h[c] + hr) / 4;
    }

    // ---------- layered windows ----------
    static readonly WndProc wndProc = DefWindowProc;
    static bool classDone;

    static void CreateLayers()
    {
        IntPtr hInst = GetModuleHandle(null);
        if (!classDone)
        {
            WNDCLASSEX wc = new WNDCLASSEX();
            wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc);
            wc.hInstance = hInst;
            wc.lpszClassName = "MacDeskSnow";
            RegisterClassEx(ref wc);                              // fails harmlessly if it already exists
            classDone = true;
        }
        IntPtr screen = GetDC(IntPtr.Zero);
        foreach (int[] m in mons)
        {
            SnowLayer L = new SnowLayer();
            L.X = m[0]; L.Y = m[1]; L.W = m[2] - m[0]; L.H = m[3] - m[1];
            L.Buf = new int[L.W * L.H];
            // WS_EX_LAYERED | TRANSPARENT | TOOLWINDOW | NOACTIVATE | TOPMOST: drawn on top, clicks go through
            L.Hwnd = CreateWindowEx(0x80000 | 0x20 | 0x80 | 0x08000000 | 0x8, "MacDeskSnow", "MacDesk Snow",
                unchecked((int)0x80000000), L.X, L.Y, L.W, L.H, IntPtr.Zero, IntPtr.Zero, hInst, IntPtr.Zero);
            if (L.Hwnd == IntPtr.Zero) throw new Exception("CreateWindowEx failed " + Marshal.GetLastWin32Error());
            BITMAPINFO bi = new BITMAPINFO();
            bi.biSize = 40; bi.biWidth = L.W; bi.biHeight = -L.H; bi.biPlanes = 1; bi.biBitCount = 32;
            L.Bmp = CreateDIBSection(screen, ref bi, 0, out L.Bits, IntPtr.Zero, 0);
            L.MemDC = CreateCompatibleDC(screen);
            L.OldBmp = SelectObject(L.MemDC, L.Bmp);
            if (HideFromCapture) SetWindowDisplayAffinity(L.Hwnd, 0x11);   // WDA_EXCLUDEFROMCAPTURE
            Present(L, -1, -1, -1, -1);                                     // first, full update
            ShowWindow(L.Hwnd, 4);                                          // SW_SHOWNOACTIVATE
            layers.Add(L);
        }
        ReleaseDC(IntPtr.Zero, screen);
    }

    static void DestroyLayers()
    {
        foreach (SnowLayer L in layers)
        {
            try
            {
                if (L.Hwnd != IntPtr.Zero) DestroyWindow(L.Hwnd);
                if (L.MemDC != IntPtr.Zero) { SelectObject(L.MemDC, L.OldBmp); DeleteDC(L.MemDC); }
                if (L.Bmp != IntPtr.Zero) DeleteObject(L.Bmp);
            }
            catch { }
        }
        layers.Clear();
    }

    static void Present(SnowLayer L, int l, int t, int r, int b)
    {
        POINT dst = new POINT(); dst.x = L.X; dst.y = L.Y;
        SIZE sz = new SIZE(); sz.cx = L.W; sz.cy = L.H;
        POINT src = new POINT();
        BLENDFUNCTION bf = new BLENDFUNCTION(); bf.BlendOp = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
        if (l < 0)
        {
            UpdateLayeredWindow(L.Hwnd, IntPtr.Zero, ref dst, ref sz, L.MemDC, ref src, 0, ref bf, 2);
            return;
        }
        RECT dirty = new RECT(); dirty.l = l; dirty.t = t; dirty.r = r; dirty.b = b;
        GCHandle hd = GCHandle.Alloc(dst, GCHandleType.Pinned), hs = GCHandle.Alloc(sz, GCHandleType.Pinned),
                 hp = GCHandle.Alloc(src, GCHandleType.Pinned), hb = GCHandle.Alloc(bf, GCHandleType.Pinned),
                 hr = GCHandle.Alloc(dirty, GCHandleType.Pinned);
        try
        {
            ULWINFO info = new ULWINFO();
            info.cbSize = Marshal.SizeOf(typeof(ULWINFO));
            info.pptDst = hd.AddrOfPinnedObject(); info.psize = hs.AddrOfPinnedObject();
            info.hdcSrc = L.MemDC; info.pptSrc = hp.AddrOfPinnedObject();
            info.pblend = hb.AddrOfPinnedObject(); info.dwFlags = 2; info.prcDirty = hr.AddrOfPinnedObject();
            if (!UpdateLayeredWindowIndirect(L.Hwnd, ref info))
                UpdateLayeredWindow(L.Hwnd, IntPtr.Zero, ref dst, ref sz, L.MemDC, ref src, 0, ref bf, 2);
        }
        finally { hd.Free(); hs.Free(); hp.Free(); hb.Free(); hr.Free(); }
    }

    // ---------- screens & fullscreen ----------
    static bool FullscreenForeground()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (pid == myPid) return false;
        StringBuilder sb = new StringBuilder(64);
        GetClassName(h, sb, 64);
        string c = sb.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
        if (IsZoomed(h)) return false;
        RECT r; if (!GetWindowRect(h, out r)) return false;
        foreach (int[] m in mons) if (r.l <= m[0] && r.t <= m[1] && r.r >= m[2] && r.b >= m[3]) return true;
        return false;
    }

    static int[] MonAt(double x, double y)
    {
        foreach (int[] m in mons) if (x >= m[0] && x < m[2] && y >= m[1] && y < m[3]) return m;
        return null;
    }
    static int[] MonAtX(double x)
    {
        foreach (int[] m in mons) if (x >= m[0] && x < m[2]) return m;
        return null;
    }

    static readonly MonitorEnumProc monCb = OnMonitor;
    static readonly List<int[]> monScan = new List<int[]>();
    static string LoadMonitors()
    {
        monScan.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, monCb, IntPtr.Zero);
        StringBuilder sb = new StringBuilder();
        foreach (int[] m in monScan) sb.Append(m[0]).Append(',').Append(m[1]).Append(',').Append(m[2]).Append(',').Append(m[3]).Append(';');
        string sig = sb.ToString();
        if (sig != monSig || mons.Count == 0) { mons.Clear(); mons.AddRange(monScan); }
        return sig;
    }
    static bool OnMonitor(IntPtr hm, IntPtr hdc, IntPtr rc, IntPtr data)
    {
        MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (GetMonitorInfo(hm, ref mi)) monScan.Add(new int[] { mi.rcMonitor.l, mi.rcMonitor.t, mi.rcMonitor.r, mi.rcMonitor.b });
        return true;
    }

    // ---------- Win32 ----------
    delegate bool EnumProc(IntPtr h, IntPtr l);
    delegate bool MonitorEnumProc(IntPtr hm, IntPtr hdc, IntPtr rc, IntPtr data);
    delegate IntPtr WndProc(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public POINT pt; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX
    {
        public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFO
    {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        public uint m0, m1, m2, m3;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ULWINFO
    {
        public int cbSize; public IntPtr hdcDst, pptDst, psize, hdcSrc, pptSrc; public uint crKey;
        public IntPtr pblend; public uint dwFlags; public IntPtr prcDirty;
    }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc p, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr hm, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(int ex, string cls, string title, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")]
    static extern bool UpdateLayeredWindow(IntPtr h, IntPtr hdcDst, ref POINT dst, ref SIZE size, IntPtr hdcSrc, ref POINT src, int key, ref BLENDFUNCTION bf, int flags);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindowIndirect(IntPtr h, ref ULWINFO info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
    [DllImport("dwmapi.dll")] static extern int DwmFlush();
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int size);
}
