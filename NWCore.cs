// ==================================================================
// NightWatch UI library.
//
// This file is compiled once into %LOCALAPPDATA%\NightWatch\NW.Core.<hash>.dll
// and loaded from there on every later run, so the C# compiler is only ever
// invoked when the source actually changes.
//
// The whole user interface lives here - the custom-drawn controls AND the
// layout that assembles them into the dialogs. It used to live in
// StudyBreak.ps1 instead, which meant PowerShell had to build every control
// and every table cell at run time: about 420ms per dialog, against about
// 40ms for the same layout written in C#. StudyBreak.ps1 is now a thin
// launcher that loads this library, handles the break state and shows the
// dialogs.
//
// Compiled with: Add-Type -ReferencedAssemblies System.Drawing,
// System.Windows.Forms -OutputAssembly NW.Core.dll -OutputType Library
// ==================================================================

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace NW
{
    public static class Theme
    {
        // -----------------------------------------------------------------
        // Palette: black and orange.
        //
        // Matched to the QR Studio window: neutral near-black backgrounds,
        // a hairline grey border, and one saturated orange carrying every
        // accent - the ring, the primary button, the selected preset, the
        // header glow. The orange is the Tailwind orange-500 ramp, so the
        // three oranges sit at clearly different depths instead of all
        // looking like the same shade.
        // -----------------------------------------------------------------
        public static readonly Color BgDeep      = Color.FromArgb(11, 11, 13);
        public static readonly Color Bg          = Color.FromArgb(17, 17, 19);
        public static readonly Color Surface     = Color.FromArgb(23, 23, 26);
        public static readonly Color Border      = Color.FromArgb(46, 46, 52);
        public static readonly Color BorderSoft  = Color.FromArgb(34, 34, 39);
        public static readonly Color Text        = Color.FromArgb(245, 245, 247);
        public static readonly Color TextMuted   = Color.FromArgb(158, 158, 168);
        public static readonly Color TextDim     = Color.FromArgb(120, 120, 130);
        public static readonly Color Cyan        = Color.FromArgb(249, 115, 22);
        public static readonly Color Blue        = Color.FromArgb(217, 84, 15);
        public static readonly Color Violet      = Color.FromArgb(154, 52, 18);
        public static readonly Color Danger      = Color.FromArgb(230, 60, 40);
        public static readonly Color Success     = Color.FromArgb(247, 179, 43);

        public static bool Animations = true;

        // ---------------------------------------------------------------
        // The real NightWatch icon.
        //
        // The script loads assets/icon.png, crops it to the mark and hands
        // the bitmap over. Null means "not supplied", and the emblem then
        // falls back to drawing the crescent itself.
        // ---------------------------------------------------------------
        private static Bitmap _brand;
        public static Bitmap Brand { get { return _brand; } }
        public static void SetBrandImage(Bitmap b) { _brand = b; }

        // ---------------------------------------------------------------
        // Cached fonts and string formats.
        //
        // These used to be allocated inside OnPaint, which runs up to 30
        // times a second for every animated control. A Font is not cheap:
        // each one is a GDI handle plus a font-family lookup, so a screen
        // full of buttons was creating and destroying hundreds of them per
        // second. They are immutable, so they are built once and shared.
        //
        // Never dispose anything these return - the cache hands the same
        // instance out again.
        // ---------------------------------------------------------------
        private static readonly Dictionary<string, Font> _fonts = new Dictionary<string, Font>();
        private static StringFormat _center;

        private static Font Cached(string family, float size, FontStyle style)
        {
            string key = family + "|" + size.ToString("R") + "|" + (int)style;
            Font f;
            if (_fonts.TryGetValue(key, out f)) return f;
            f = new Font(family, size, style, GraphicsUnit.Point);
            _fonts[key] = f;
            return f;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SystemParametersInfo(uint a, uint b, ref bool c, uint d);

        public static void DetectReducedMotion()
        {
            try {
                bool on = true;
                // SPI_GETCLIENTAREAANIMATION
                if (SystemParametersInfo(0x1042, 0, ref on, 0)) Animations = on;
            } catch { Animations = true; }
        }

        public static void Setup(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        }

        public static GraphicsPath Rounded(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            if (r.Width <= 0 || r.Height <= 0) { p.AddRectangle(r); return p; }
            int d = radius * 2;
            if (d > Math.Min(r.Width, r.Height)) d = Math.Min(r.Width, r.Height);
            p.AddArc(r.X,          r.Y,          d, d, 180, 90);
            p.AddArc(r.Right - d,  r.Y,          d, d, 270, 90);
            p.AddArc(r.Right - d,  r.Bottom - d, d, d,   0, 90);
            p.AddArc(r.X,          r.Bottom - d, d, d,  90, 90);
            p.CloseFigure();
            return p;
        }

        public static StringFormat Center()
        {
            if (_center == null) {
                _center = new StringFormat {
                    Alignment = StringAlignment.Center,
                    LineAlignment = StringAlignment.Center,
                    FormatFlags = StringFormatFlags.NoWrap
                };
            }
            return _center;
        }

        /// <summary>Layered low-alpha strokes approximate a soft glow cheaply.</summary>
        public static void Glow(Graphics g, GraphicsPath path, Color c, int radius, int strength)
        {
            if (strength <= 0) return;
            for (int i = 0; i < 3; i++)
            {
                int a = Math.Max(1, (int)(strength * (0.16 / (i + 1))));
                float w = radius + (float)(i + 1) * 2.2f;
                using (var pen = new Pen(Color.FromArgb(a, c), w) {
                    StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                    g.DrawPath(pen, path);
            }
        }

        public static Font Ui(float size, FontStyle style)
        {
            return Cached("Segoe UI", size, style);
        }

        public static Font UiSemibold(float size)
        {
            try { return Cached("Segoe UI Semibold", size, FontStyle.Regular); }
            catch { return Cached("Segoe UI", size, FontStyle.Bold); }
        }

        /// <summary>Monospaced digits so timers do not jitter as they change.</summary>
        public static Font Num(float size, FontStyle style)
        {
            return Cached("Consolas", size, style);
        }
    }

    /// <summary>
    /// Base for NW controls that sit on a solid parent surface.
    ///
    /// Derives from Panel, not Control. A plain Control does NOT lay its
    /// children out with margins, so a docked child with a Margin was simply
    /// ignored: the header's inner row and the card's grid ended up flush to
    /// the edges, the emblem hung off the left of the window and the status
    /// chip ran into the right frame. Panel honours Margin, which is what
    /// keeps the header and card content aligned with the body.
    ///
    /// BackColor = Transparent only works when WinForms can ask the parent to
    /// repaint this control's rectangle. On a live composited window that
    /// repaint is not guaranteed, and when it is skipped the control's own
    /// back buffer is simply left untouched - which is black. It showed up as
    /// a black block behind the countdown ring, and it is intermittent: the
    /// same build captured clean on one run and broken on the next.
    ///
    /// -SelfTest cannot catch it, because DrawToBitmap (WM_PRINT) always takes
    /// the working path. Only -Capture, a real screen grab, can.
    ///
    /// So these controls never depend on that machinery at paint time: each
    /// paints its own background from BackFill.
    /// </summary>
    public abstract class SurfaceControl : Panel
    {
        private Color _backFill = Color.Empty;

        /// <summary>
        /// Colour painted behind this control. It must match whatever the
        /// control sits on, otherwise a rounded corner shows up as a square
        /// edge.
        ///
        /// Setting it also makes the control's BackColor opaque instead of
        /// transparent. A transparent control is composited by asking the
        /// PARENT to repaint the control's rectangle; if the parent has not
        /// painted that rectangle yet, the child shows a torn, half-drawn
        /// patch - that is exactly the intermittent black block that used to
        /// appear behind the countdown ring. Because BackFill always equals
        /// the colour behind the control, painting it opaque is visually
        /// identical to being transparent (the rounded corners still blend
        /// in) and it removes the parent-repaint dependency entirely.
        /// </summary>
        public Color BackFill {
            get { return _backFill; }
            set {
                _backFill = value;
                if (!value.IsEmpty) BackColor = value;
            }
        }

        protected SurfaceControl()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                     ControlStyles.SupportsTransparentBackColor, true);
            // Without SupportsTransparentBackColor this assignment throws and
            // every NW control fails to construct, taking its whole dialog
            // with it. Keep the flag even though BackFill now does the work.
            BackColor = Color.Transparent;
        }

        /// <summary>
        /// Paint the background. Every derived OnPaint must call this first:
        /// AllPaintingInWmPaint suppresses WM_ERASEBKGND, so overriding
        /// OnPaintBackground would never run.
        /// </summary>
        protected void PaintBack(Graphics g)
        {
            if (BackFill.IsEmpty) return;
            var r = ClientRectangle;
            if (r.Width <= 0 || r.Height <= 0) return;
            using (var b = new SolidBrush(BackFill)) g.FillRectangle(b, r);
        }
    }

    /// <summary>Rounded surface with a subtle sheen and hairline border.</summary>
    public class Card : SurfaceControl
    {
        private int _Radius = 16;
        public int Radius { get { return _Radius; } set { _Radius = value; } }
        private Color _Fill = Theme.Surface;
        public Color Fill { get { return _Fill; } set { _Fill = value; } }
        private Color _BorderColor = Theme.BorderSoft;
        public Color BorderColor { get { return _BorderColor; } set { _BorderColor = value; } }
        private int _GlowStrength = 0;
        public int GlowStrength { get { return _GlowStrength; } set { _GlowStrength = value; } }
        private Color _GlowColor = Theme.Cyan;
        public Color GlowColor { get { return _GlowColor; } set { _GlowColor = value; } }

        // Set by UI.NewTimingCard so callers can drive the live countdown.
        // Both are properties, not fields: a public field on a
        // marshal-by-reference class (every Control is one) is exactly the
        // case the C# compiler warns about, and the value can come back
        // unmarshalled.
        public Ring Ring { get; set; }
        public Label TimeLabel { get; set; }

        public Card()
        {
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; Theme.Setup(g);
            PaintBack(g);
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = Theme.Rounded(r, Radius))
            {
                if (GlowStrength > 0) Theme.Glow(g, p, GlowColor, Radius, GlowStrength);
                using (var b = new SolidBrush(Fill)) g.FillPath(b, p);
                // No top-half sheen gradient: the ring and the labels sitting on
                // the card paint a flat Fill, so a gradient underneath would
                // show a seam along the edge of anything painted over it. The
                // glow and the border already carry the depth.
                using (var pen = new Pen(BorderColor, 1f)) g.DrawPath(pen, p);
            }
        }
    }

    /// <summary>Header strip: gradient, one restrained bloom, hairline base.</summary>
    public class HeaderBand : Panel
    {
        public HeaderBand()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.BgDeep;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; Theme.Setup(g);
            var r = new Rectangle(0, 0, Width, Height);
            using (var lg = new LinearGradientBrush(r, Theme.BgDeep, Theme.Bg, LinearGradientMode.Vertical))
                g.FillRectangle(lg, r);

            for (int i = 4; i >= 1; i--)
            {
                int rr = 46 * i;
                using (var b = new SolidBrush(Color.FromArgb(6, Theme.Cyan)))
                    g.FillEllipse(b, -rr / 2, -rr / 3, rr, rr);
            }
            using (var b2 = new SolidBrush(Color.FromArgb(5, Theme.Violet)))
                g.FillEllipse(b2, Width - 90, -30, 140, 140);

            using (var pen = new Pen(Theme.BorderSoft, 1f))
                g.DrawLine(pen, 0, Height - 1, Width, Height - 1);
        }
    }

    /// <summary>Crescent moon + pause bars: the NightWatch mark, drawn not shipped as a bitmap.</summary>
    public class Emblem : SurfaceControl
    {
        private Color _Tint = Theme.Cyan;
        public Color Tint { get { return _Tint; } set { _Tint = value; } }
        public Emblem()
        {
            // Opaque rather than transparent: the mark repaints the band's
            // gradient over its whole rectangle, so there is nothing for the
            // OS to composite and no reason to ask the band to repaint
            // behind it.
            BackColor = Theme.BgDeep;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; Theme.Setup(g);
            // The mark sits on HeaderBand's vertical BgDeep->Bg gradient and
            // spans the band's full height, so it repaints that same gradient
            // instead of asking the band to repaint it. A flat fill would show
            // a visible seam along the bottom of the mark.
            using (var band = new LinearGradientBrush(
                       new Rectangle(0, 0, Width, Height),
                       Theme.BgDeep, Theme.Bg, LinearGradientMode.Vertical))
                g.FillRectangle(band, new Rectangle(0, 0, Width, Height));

            float s = Math.Min(Width, Height);
            if (s < 4) return;

            // The real NightWatch icon, when the script has supplied it.
            // It is drawn straight onto the band gradient painted above, so
            // the rounded corners of the artwork melt into the header
            // instead of showing up as a pasted-on rectangle.
            var brand = Theme.Brand;
            if (brand != null)
            {
                var bBox = new RectangleF((Width - s) / 2f, (Height - s) / 2f, s, s);
                var oldInterp = g.InterpolationMode;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(brand, bBox);
                g.InterpolationMode = oldInterp;
                return;
            }

            var box = new RectangleF((Width - s) / 2f, (Height - s) / 2f, s, s);

            // Crescent = circle minus an offset circle (alternate fill).
            var moon = new GraphicsPath();
            moon.AddEllipse(box);
            var cut = new GraphicsPath();
            float k = s * 0.26f;
            cut.AddEllipse(box.X + k, box.Y - k * 0.62f, s, s);
            moon.FillMode = FillMode.Alternate;
            moon.AddPath(cut, true);

            using (var lg = new LinearGradientBrush(box, Theme.Cyan, Theme.Violet, LinearGradientMode.Vertical))
                g.FillPath(lg, moon);

            float bw = Math.Max(1.5f, s * 0.10f);
            float bh = s * 0.44f;
            float gap = s * 0.14f;
            float by = box.Y + (s - bh) / 2f;
            float bx = box.X + (s - (bw * 2 + gap)) / 2f;
            using (var b = new SolidBrush(Color.FromArgb(255, 244, 232)))
            {
                g.FillRectangle(b, bx, by, bw, bh);
                g.FillRectangle(b, bx + bw + gap, by, bw, bh);
            }
        }
    }

    public enum BtnVariant { Ghost, Primary, Danger }

    /// <summary>
    /// Owner-drawn button: rounded, animated hover/press, optional selected state.
    /// Implements IButtonControl so Form.AcceptButton / CancelButton work, which
    /// is what gives the dialogs their Enter / Escape behaviour.
    /// </summary>
    public class NWButton : SurfaceControl, IButtonControl
    {
        private float _hover, _press, _focus;
        private bool _hovering, _pressing;
        private Timer _anim;

        public DialogResult DialogResult { get; set; }

        public void NotifyDefault(bool value) { }

        // Control does not provide PerformClick (only Button does), so the
        // interface member has to be implemented for AcceptButton/CancelButton.
        public void PerformClick()
        {
            if (!Enabled || !Visible) return;
            OnClick(EventArgs.Empty);
        }

        private bool _selected;
        public bool Selected {
            get { return _selected; }
            // Must be a property, not a field: a field assignment does not
            // invalidate, so the chip would keep its old look until some
            // unrelated repaint happened to redraw it.
            set { if (_selected != value) { _selected = value; Invalidate(); } }
        }
        private BtnVariant _Variant = BtnVariant.Ghost;
        public BtnVariant Variant { get { return _Variant; } set { _Variant = value; } }
        private Color _Accent = Theme.Cyan;
        public Color Accent { get { return _Accent; } set { _Accent = value; } }
        private int _Radius = 10;
        public int Radius { get { return _Radius; } set { _Radius = value; } }
        private int _Symbol = 0;
        public int Symbol { get { return _Symbol; } set { _Symbol = value; } }   // 0 none, 1 minus, 2 plus, 3 check
        private bool _SymbolOnly = false;
        public bool SymbolOnly { get { return _SymbolOnly; } set { _SymbolOnly = value; } }
        private string _Caption = "";
        public string Caption { get { return _Caption; } set { _Caption = value; } }

        public NWButton()
        {
            SetStyle(ControlStyles.Selectable, true);
            SetStyle(ControlStyles.StandardDoubleClick, false);
            ForeColor = Theme.Text;
            Cursor = Cursors.Hand;
            TabStop = true;
            AccessibleRole = AccessibleRole.PushButton;
            _anim = new Timer();
            // 33ms ~= 30fps. Hover tints and a sweeping arc do not need 60fps,
            // and each tick invalidates the control, so this is the single
            // biggest lever on how busy the UI feels.
            _anim.Interval = Theme.Animations ? 33 : 120;
            _anim.Tick += delegate {
                float dh = (_hovering ? 1f : 0f) - _hover;
                float dp = (_pressing ? 1f : 0f) - _press;
                float df = (Focused ? 1f : 0f) - _focus;
                if (Math.Abs(dh) < .01f && Math.Abs(dp) < .01f && Math.Abs(df) < .01f) { _anim.Stop(); return; }
                float k = Theme.Animations ? 0.30f : 1f;
                _hover += dh * k; _press += dp * k; _focus += df * k;
                Invalidate();
            };
        }

        private void Kick()
        {
            if (!Theme.Animations) {
                _hover = _hovering ? 1f : 0f;
                _press = _pressing ? 1f : 0f;
                _focus = Focused ? 1f : 0f;
                Invalidate(); return;
            }
            if (!_anim.Enabled) _anim.Start();
        }

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); _hovering = true;  Kick(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); _hovering = false; _pressing = false; Kick(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); _pressing = true;  Focus(); Kick(); }
        protected override void OnMouseUp(MouseEventArgs e)   { base.OnMouseUp(e);   _pressing = false; Kick(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Kick(); Invalidate(); }
        protected override void OnLostFocus(EventArgs e){ base.OnLostFocus(e); Kick(); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e){ base.OnEnabledChanged(e); Invalidate(); }

        protected override bool IsInputKey(Keys k)
        {
            return k == Keys.Space || k == Keys.Enter || base.IsInputKey(k);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { _pressing = true; Kick(); e.Handled = true; }
            base.OnKeyDown(e);
        }

        protected override void OnKeyUp(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter)
            {
                _pressing = false; Kick();
                if (Enabled && Focused) PerformClick();
                e.Handled = true;
            }
            base.OnKeyUp(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; Theme.Setup(g);
            PaintBack(g);
            var r = new Rectangle(0, 0, Width - 1, Height - 1);

            Color fill, edge, txt;
            bool emphasis = false;

            if (Variant == BtnVariant.Primary)
            {
                // A solid orange block, the way the primary action reads in
                // QR Studio. The hover blends it a shade lighter.
                fill = Blend(Color.FromArgb(236, 100, 14), Theme.Cyan, (int)(_hover * 70));
                edge = Theme.Cyan; txt = Color.White; emphasis = true;
            }
            else if (Variant == BtnVariant.Danger)
            {
                fill = Blend(Color.FromArgb(52, 22, 16), Theme.Danger, (int)(_hover * 60));
                edge = Theme.Danger; txt = Theme.Danger; emphasis = true;
            }
            else if (Selected)
            {
                fill = Blend(Color.FromArgb(52, 32, 16), Theme.Cyan, (int)(_hover * 40));
                edge = Theme.Cyan; txt = Theme.Text; emphasis = true;
            }
            else
            {
                fill = Blend(Theme.Surface, Color.White, (int)(_hover * 10));
                edge = Theme.Border;
                txt = Blend(Theme.TextMuted, Theme.Text, (int)(_hover * 160));
            }

            if (_press > 0f)
            {
                fill = Blend(fill, Color.Black, (int)(_press * 45));
                txt  = Blend(txt, Color.White, (int)(_press * 60));
            }

            if (!Enabled)
            {
                fill = Blend(Theme.Surface, Theme.Bg, 140);
                edge = Theme.BorderSoft;
                txt  = Theme.TextDim;
                emphasis = false;
            }

            using (var p = Theme.Rounded(r, Radius))
            {
                if (emphasis) Theme.Glow(g, p, Variant == BtnVariant.Primary ? Theme.Blue : edge, Radius, Enabled ? 90 : 0);
                using (var b = new SolidBrush(fill)) g.FillPath(b, p);
                using (var pen = new Pen(edge, emphasis ? 1.4f : 1f)) g.DrawPath(pen, p);
            }

            // Keyboard focus ring: doubled inset so it reads on any fill.
            if (_focus > 0f)
            {
                var fr = new Rectangle(2, 2, Math.Max(1, r.Width - 4), Math.Max(1, r.Height - 4));
                using (var p2 = Theme.Rounded(fr, Math.Max(2, Radius - 2)))
                using (var pen = new Pen(Color.FromArgb((int)(210 * _focus), Theme.Cyan), 1.6f))
                    g.DrawPath(pen, p2);
            }

            if (SymbolOnly) { DrawSymbol(g, r, txt); return; }

            // Theme.UiSemibold and Theme.Center hand back shared, cached
            // instances - disposing them here would break every later paint.
            using (var b = new SolidBrush(txt))
                g.DrawString(Caption, Theme.UiSemibold(9.75f), b, r, Theme.Center());
        }

        private void DrawSymbol(Graphics g, Rectangle r, Color txt)
        {
            float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
            float s = Math.Min(r.Width, r.Height) * 0.2f;
            using (var pen = new Pen(txt, 2f) {
                StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            {
                if (Symbol == 1) g.DrawLine(pen, cx - s, cy, cx + s, cy);
                if (Symbol == 2)
                {
                    g.DrawLine(pen, cx - s, cy, cx + s, cy);
                    g.DrawLine(pen, cx, cy - s, cx, cy + s);
                }
                if (Symbol == 3)
                    g.DrawLines(pen, new PointF[] {
                        new PointF(cx - s, cy), new PointF(cx - s * 0.25f, cy + s * 0.8f), new PointF(cx + s, cy - s * 0.9f) });
            }
        }

        public static Color Blend(Color a, Color b, int amount)
        {
            if (amount <= 0) return a;
            if (amount >= 255) return b;
            return Color.FromArgb(
                a.A + (b.R - a.A) * amount / 255,
                a.R + (b.R - a.R) * amount / 255,
                a.G + (b.G - a.G) * amount / 255,
                a.B + (b.B - a.B) * amount / 255);
        }
    }

    /// <summary>Circular timer with glow and a tabular centre readout.</summary>
    public class Ring : SurfaceControl
    {
        private double _value, _shown;
        private Timer _anim;

        public double Value {
            get { return _value; }
            set { _value = Math.Max(0, Math.Min(1, value)); Kick(); }
        }
        private string _CenterBig = "";
        public string CenterBig { get { return _CenterBig; } set { _CenterBig = value; } }
        private string _CenterSmall = "";
        public string CenterSmall { get { return _CenterSmall; } set { _CenterSmall = value; } }
        private Color _Accent = Theme.Cyan;
        public Color Accent { get { return _Accent; } set { _Accent = value; } }
        private Color _Track = Theme.BorderSoft;
        public Color Track { get { return _Track; } set { _Track = value; } }
        private float _Thickness = 7f;
        public float Thickness { get { return _Thickness; } set { _Thickness = value; } }

        public Ring()
        {
            _anim = new Timer();
            _anim.Interval = Theme.Animations ? 33 : 100;
            _anim.Tick += delegate {
                double d = _value - _shown;
                if (Math.Abs(d) < 0.002) { _anim.Stop(); return; }
                _shown += d * (Theme.Animations ? 0.25 : 1.0);
                Invalidate();
            };
        }

        private void Kick()
        {
            if (!Theme.Animations) { _shown = _value; Invalidate(); return; }
            if (!_anim.Enabled) _anim.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; Theme.Setup(g);
            PaintBack(g);
            float pad = Thickness + 3f;
            float d = Math.Min(Width, Height) - pad * 2f;
            if (d <= 8) return;
            var box = new RectangleF((Width - d) / 2f, (Height - d) / 2f, d, d);

            using (var pen = new Pen(Track, Thickness) {
                StartCap = LineCap.Round, EndCap = LineCap.Round })
                g.DrawEllipse(pen, box);

            double frac = _shown;
            if (frac > 0.0001)
            {
                float sweep = (float)(360.0 * frac);
                using (var glow = new Pen(Color.FromArgb(38, Accent), Thickness + 7f) {
                    StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawArc(glow, box, -90f, sweep);
                using (var glow2 = new Pen(Color.FromArgb(70, Accent), Thickness + 3f) {
                    StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawArc(glow2, box, -90f, sweep);
                using (var pen = new Pen(Accent, Thickness) {
                    StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawArc(pen, box, -90f, sweep);

                if (frac < 0.999)
                {
                    double ang = (-90f + sweep) * Math.PI / 180.0;
                    float hx = box.X + box.Width / 2f + (float)(Math.Cos(ang) * d / 2.0);
                    float hy = box.Y + box.Height / 2f + (float)(Math.Sin(ang) * d / 2.0);
                    using (var b = new SolidBrush(Color.FromArgb(255, 248, 238)))
                        g.FillEllipse(b, hx - 2.4f, hy - 2.4f, 4.8f, 4.8f);
                }
            }

            if (CenterBig != "")
            {
                using (var b = new SolidBrush(Theme.Text))
                    g.DrawString(CenterBig, Theme.Num(17f, FontStyle.Bold), b,
                        new RectangleF(box.X, box.Y + d * 0.22f, d, d * 0.34f), Theme.Center());

                if (CenterSmall != "")
                {
                    using (var b = new SolidBrush(Theme.TextDim))
                        g.DrawString(CenterSmall, Theme.Ui(7.5f, FontStyle.Regular), b,
                            new RectangleF(box.X, box.Y + d * 0.55f, d, d * 0.20f), Theme.Center());
                }
            }
        }
    }
}


// ==================================================================
// The dialogs.
//
// The layout that assembles the custom-drawn controls into the three
// windows used to be written in PowerShell. That works, but PowerShell
// has to create every control and every table cell through its own
// adapter at run time, which measured at about 420ms per dialog. The
// same layout written here costs about 40ms - the same order of
// magnitude as building the equivalent with plain WinForms controls.
//
// The window classes are typed rather than plain Forms, so the script
// (and the -SelfTest harness) can reach the controls it needs to drive
// without the reflection-and-script-scope gymnastics that the
// PowerShell version needed.
// ==================================================================
namespace NW
{
    public class PickerForm : Form
    {
        public Card Card { get; set; }
        public TextBox NumBox { get; set; }
        public Label ErrLabel { get; set; }
        public NWButton StartButton { get; set; }
        public List<NWButton> Presets { get; private set; }
        public Timer Clock { get; set; }
        public int ChosenMinutes { get; set; }
        public bool UsingCustom { get; set; }
        public DateTime BaseTime { get; set; }

        public PickerForm() { Presets = new List<NWButton>(); }
    }

    public class ActiveForm : Form
    {
        public Card Card { get; set; }
        public Timer Clock { get; set; }
        public NWButton KeepButton { get; set; }
        public bool EndNow { get; set; }
    }

    public static class UI
    {
        public const int FORM_W = 468;
        public const int BTN_H = 42;
        public const int RADIUS = 12;
        public const int HEADER_H = 70;

        static Icon _icon;

        /// <summary>The window icon. Each form gets its own copy.</summary>
        public static void SetIcon(Icon icon) { _icon = icon; }

        // -----------------------------------------------------------------
        // Window sizing
        //
        // The window is sized to the content it actually holds, not to a
        // number guessed once. The layout reports the height it needs, so
        // the window ends up exactly that tall: no action buttons clipped
        // off the bottom, and no dead space under them.
        //
        // This also fixes the DPI problem for free. The AutoSize rows take
        // their height from the font, so on a 150% or 200% display the
        // measurement grows with the text instead of the window staying
        // the same size and cutting the content off.
        // -----------------------------------------------------------------
        static void FitToContent(Form f, TableLayoutPanel content, int headerHeight, int width)
        {
            f.PerformLayout();
            int inner = width - content.Padding.Horizontal;
            int need = content.GetPreferredSize(new Size(inner, 0)).Height;
            f.ClientSize = new Size(width, headerHeight + need);
        }

        // -----------------------------------------------------------------
        // Layout helpers
        // -----------------------------------------------------------------
        static void ConfigureBase(Form f, string title, int height)
        {
            f.Text = title;
            f.ClientSize = new Size(FORM_W, height);
            f.StartPosition = FormStartPosition.CenterScreen;
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.MaximizeBox = false;
            f.MinimizeBox = false;
            f.TopMost = true;
            f.BackColor = Theme.Bg;
            f.ForeColor = Theme.Text;
            // Critical: without this, Windows rescales every coordinate on a
            // non-100% DPI display and controls end up overlapping.
            f.AutoScaleMode = AutoScaleMode.None;
            f.ShowInTaskbar = false;
            if (_icon != null) {
                try { f.Icon = (Icon)_icon.Clone(); } catch { }
            }
        }

        public static TableLayoutPanel NewGrid(int cols)
        {
            TableLayoutPanel t = new TableLayoutPanel();
            t.Dock = DockStyle.Fill;
            t.ColumnCount = cols;
            t.RowCount = 0;
            t.BackColor = Color.Transparent;
            t.Margin = new Padding(0);
            for (int i = 0; i < cols; i++)
                t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / cols));
            return t;
        }

        public static int AddRow(TableLayoutPanel stack, string type, float value)
        {
            if (type == "Abs") stack.RowStyles.Add(new RowStyle(SizeType.Absolute, value));
            else if (type == "Fill") stack.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            else stack.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            stack.RowCount = stack.RowStyles.Count;
            return stack.RowCount - 1;
        }

        public static int AddCol(TableLayoutPanel grid, string type, float value)
        {
            if (type == "Abs") grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, value));
            else if (type == "Fill") grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            else grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            return grid.ColumnStyles.Count - 1;
        }

        /// <summary>Vertical text stack: AutoSize rows only, with a
        /// percent-100 spacer top and bottom so the block sits centred.</summary>
        static TableLayoutPanel NewVStack(TableLayoutPanel parent, int col)
        {
            TableLayoutPanel t = NewGrid(1);
            parent.Controls.Add(t, col, 0);
            AddRow(t, "Fill", 0);
            return t;
        }

        public static Label NewLabel(string text, float size, Color color, bool bold,
                                     int bottomMargin, int wrapWidth)
        {
            Label l = new Label();
            l.Text = text;
            l.Font = (Font)Theme.Ui(size, bold ? FontStyle.Bold : FontStyle.Regular).Clone();
            l.ForeColor = color;
            l.BackColor = Color.Transparent;
            l.AutoSize = true;
            l.Dock = DockStyle.Fill;
            l.TextAlign = ContentAlignment.TopLeft;
            l.Margin = new Padding(0, 0, 0, bottomMargin);
            // Without an upper bound an AutoSize label runs off the edge of its
            // column and gets clipped. Wrapping keeps every line inside.
            if (wrapWidth > 0) l.MaximumSize = new Size(wrapWidth, 0);
            return l;
        }

        public static void AddText(TableLayoutPanel stack, string text, float size, Color color,
                                   bool bold, int bottomMargin, int wrapWidth)
        {
            int r = AddRow(stack, "Auto", 0);
            stack.Controls.Add(NewLabel(text, size, color, bold, bottomMargin, wrapWidth), 0, r);
        }

        public static Label AddAccent(TableLayoutPanel stack, string text, float size, Color color,
                                      int bottomMargin, int wrapWidth)
        {
            Label l = new Label();
            l.Text = text;
            l.Font = (Font)Theme.UiSemibold(size).Clone();
            l.ForeColor = color;
            l.BackColor = Color.Transparent;
            l.AutoSize = true;
            l.Dock = DockStyle.Fill;
            l.TextAlign = ContentAlignment.TopLeft;
            l.Margin = new Padding(0, 0, 0, bottomMargin);
            if (wrapWidth > 0) l.MaximumSize = new Size(wrapWidth, 0);
            int r = AddRow(stack, "Auto", 0);
            stack.Controls.Add(l, 0, r);
            return l;
        }

        public static NWButton NewNWButton(string caption, BtnVariant variant, Color? accent,
                                           int symbol, bool symbolOnly, int marginRight, int marginLeft)
        {
            NWButton b = new NWButton();
            b.Dock = DockStyle.Fill;
            b.Caption = caption;
            b.Variant = variant;
            b.Symbol = symbol;
            b.SymbolOnly = symbolOnly;
            b.Radius = RADIUS;
            if (accent.HasValue) b.Accent = accent.Value;
            b.Font = (Font)Theme.UiSemibold(9.75f).Clone();
            b.Margin = new Padding(marginLeft, 0, marginRight, 0);
            // Buttons sit on transparent grids over Theme.Bg. Paint that
            // background ourselves so the rounded corners never fall back to
            // a black block.
            b.BackFill = Theme.Bg;
            return b;
        }

        public static void NewHeader(TableLayoutPanel parent, string chip, Color chipColor)
        {
            HeaderBand band = new HeaderBand();
            band.Dock = DockStyle.Fill;
            band.Margin = new Padding(0);
            // Padding, not Margin: a docked child of a Panel ignores its own
            // Margin, so the header row would run edge to edge.
            band.Padding = new Padding(22, 0, 22, 0);

            TableLayoutPanel inner = NewGrid(3);
            inner.ColumnStyles.Clear();
            // 62px, not 54: the real icon needs room to be recognisable.
            AddCol(inner, "Abs", 62);
            AddCol(inner, "Fill", 0);
            // The status chip gets the width its text actually needs, so a
            // long one like "PROTECTION ARMED" stays on one line instead of
            // wrapping into two.
            int chipWidth = 0;
            if (!string.IsNullOrEmpty(chip)) {
                chipWidth = TextRenderer.MeasureText(chip, Theme.UiSemibold(8f)).Width + 10;
            }
            AddCol(inner, "Abs", chipWidth);
            inner.Margin = new Padding(0);
            int r = AddRow(inner, "Fill", 0);

            Emblem em = new Emblem();
            em.Dock = DockStyle.Fill;
            em.Margin = new Padding(0, 0, 8, 0);
            em.AccessibleName = "NightWatch";

            TableLayoutPanel txt = new TableLayoutPanel();
            txt.Dock = DockStyle.Fill;
            txt.ColumnCount = 1;
            txt.RowCount = 2;
            txt.BackColor = Color.Transparent;
            txt.Margin = new Padding(0);
            txt.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            txt.RowStyles.Add(new RowStyle(SizeType.Percent, 60f));
            txt.RowStyles.Add(new RowStyle(SizeType.Percent, 40f));

            Label t1 = new Label();
            t1.Text = "NIGHTWATCH";
            t1.Font = (Font)Theme.UiSemibold(13f).Clone();
            t1.ForeColor = Theme.Text;
            t1.BackColor = Color.Transparent;
            t1.AutoSize = false;
            t1.Dock = DockStyle.Fill;
            t1.TextAlign = ContentAlignment.BottomLeft;
            t1.Margin = new Padding(0);

            Label t2 = new Label();
            t2.Text = "study-break sentinel";
            t2.Font = (Font)Theme.Ui(8.5f, FontStyle.Regular).Clone();
            t2.ForeColor = Theme.TextDim;
            t2.BackColor = Color.Transparent;
            t2.AutoSize = false;
            t2.Dock = DockStyle.Fill;
            t2.TextAlign = ContentAlignment.TopLeft;
            t2.Margin = new Padding(0);

            txt.Controls.Add(t1, 0, 0);
            txt.Controls.Add(t2, 0, 1);
            inner.Controls.Add(em, 0, 0);
            inner.Controls.Add(txt, 1, 0);

            if (!string.IsNullOrEmpty(chip)) {
                Label chipLbl = new Label();
                chipLbl.Text = chip;
                chipLbl.Font = (Font)Theme.UiSemibold(8f).Clone();
                chipLbl.ForeColor = chipColor;
                chipLbl.BackColor = Color.Transparent;
                chipLbl.TextAlign = ContentAlignment.MiddleRight;
                chipLbl.Dock = DockStyle.Fill;
                chipLbl.AutoSize = false;
                chipLbl.Margin = new Padding(0);
                inner.Controls.Add(chipLbl, 2, 0);
            }

            band.Controls.Add(inner);
            parent.Controls.Add(band, 0, r);
        }

        /// <summary>
        /// The timing card: ring on the left, kicker/time/relative/footnote on
        /// the right. One implementation, reused by every dialog, so the call
        /// sites cannot drift apart.
        /// </summary>
        public static Card NewTimingCard(string kicker, string timeText, string relText,
                                          string footText, Color tint, string ringBig,
                                          string ringSmall, double ringValue)
        {
            Card card = new Card();
            card.Dock = DockStyle.Fill;
            card.Radius = 16;
            card.Margin = new Padding(0);
            // No glow. It bled outside the rounded corners and read as a
            // brown strip around the card. A clean hairline border is what
            // the card should have.
            card.GlowStrength = 0;
            card.GlowColor = tint;
            // The card has rounded corners, so the area outside them has to be
            // painted with whatever is behind the card or the corners go
            // square and black. The timing card always sits on a Theme.Bg panel.
            card.BackFill = Theme.Bg;
            // Same reason as the header band: a docked child ignores its
            // Margin, so the inset has to come from the card's Padding.
            card.Padding = new Padding(18, 14, 18, 14);

            TableLayoutPanel grid = NewGrid(2);
            grid.ColumnStyles.Clear();
            AddCol(grid, "Abs", 106);
            AddCol(grid, "Fill", 0);
            // Opaque, not transparent: a transparent child forces WinForms to
            // repaint every ancestor's background into it on every invalidate,
            // which is measurably slower.
            grid.BackColor = Theme.Surface;
            grid.Margin = new Padding(0);
            AddRow(grid, "Fill", 0);

            Ring ring = new Ring();
            ring.Dock = DockStyle.Fill;
            ring.Margin = new Padding(0, 0, 16, 0);
            ring.Accent = tint;
            ring.Thickness = 7f;
            // Paint the card's own surface behind the ring. Relying on the
            // ring's transparent background instead produced an intermittent
            // black block behind the countdown on a live window.
            ring.BackFill = card.Fill;
            ring.CenterBig = ringBig;
            ring.CenterSmall = ringSmall;
            ring.Value = ringValue;
            ring.AccessibleName = "Duration timer";

            TableLayoutPanel txt = NewVStack(grid, 1);
            // Leave room for the ring column, the card padding and a little
            // slack, so the footnote wraps instead of running under the card
            // edge on wide-DPI setups where the point-sized fonts render larger.
            int wrapW = FORM_W - 44 - 106 - 16 - 36 - 8;
            AddText(txt, kicker, 8f, Theme.TextDim, true, 5, wrapW);
            Label timeLabel = AddAccent(txt, timeText, 15f, tint, 3, wrapW);
            AddText(txt, relText, 9f, Theme.TextMuted, false, 0, wrapW);
            AddText(txt, footText, 8.5f, Theme.TextDim, false, 0, wrapW);            AddRow(txt, "Fill", 0);

            grid.Controls.Add(ring, 0, 0);
            card.Controls.Add(grid);

            card.Ring = ring;
            card.TimeLabel = timeLabel;
            // Set the text again here. The label is created with it, but the
            // clock that drives it starts writing to it immediately, and a
            // countdown that shows blank for even one tick is a broken
            // countdown.
            if (card.TimeLabel != null) card.TimeLabel.Text = timeText;
            return card;
        }

        // -----------------------------------------------------------------
        // Picker state
        // -----------------------------------------------------------------
        static void SyncTiming(PickerForm f, int minutes, bool custom)
        {
            DateTime end = f.BaseTime.AddMinutes(minutes);
            Color tint = custom ? Theme.Blue : Theme.Cyan;
            f.Card.Ring.CenterBig = minutes.ToString();
            f.Card.Ring.Value = Math.Max(0.06, Math.Min(1.0, (double)(minutes / 120.0)));
            f.Card.Ring.Accent = tint;
            f.Card.GlowColor = tint;
            f.Card.TimeLabel.Text = end.ToString("HH:mm:ss");
            f.Card.TimeLabel.ForeColor = tint;
        }

        static void SyncAction(PickerForm f, int minutes)
        {
            f.StartButton.Caption = minutes == 1 ? "Start 1-minute break"
                                                 : "Start " + minutes + "-minute break";
            f.StartButton.Enabled = minutes >= 1 && minutes <= 1440;
        }

        static void SetCustom(PickerForm f, int delta)
        {
            int cur = 0;
            int.TryParse(f.NumBox.Text, out cur);
            int next = cur + delta;
            if (next < 1) next = 1;
            if (next > 1440) next = 1440;
            f.NumBox.Text = next.ToString();
        }

        // -----------------------------------------------------------------
        // Duration picker
        // -----------------------------------------------------------------
        public static PickerForm NewPickerForm()
        {
            PickerForm form = new PickerForm();
            ConfigureBase(form, "NightWatch - Study Break", 400);

            TableLayoutPanel outer = NewGrid(1);
            outer.BackColor = Theme.Bg;
            form.Controls.Add(outer);

            AddRow(outer, "Abs", HEADER_H);
            NewHeader(outer, "STANDBY", Theme.TextDim);

            TableLayoutPanel pad = NewGrid(1);
            pad.BackColor = Theme.Bg;
            pad.Padding = new Padding(22, 18, 22, 16);
            AddRow(outer, "Fill", 0);
            outer.Controls.Add(pad, 0, 1);

            // Title
            int r = AddRow(pad, "Auto", 0);
            Label title = new Label();
            title.Text = "How long is your break?";
            title.Font = (Font)Theme.UiSemibold(13.5f).Clone();
            title.ForeColor = Theme.Text;
            title.BackColor = Color.Transparent;
            title.AutoSize = true;
            title.Dock = DockStyle.Fill;
            title.Margin = new Padding(0, 0, 0, 5);
            pad.Controls.Add(title, 0, r);

            r = AddRow(pad, "Auto", 0);
            pad.Controls.Add(NewLabel("Auto-shutdown pauses for exactly this long, then resumes.",
                                       8.75f, Theme.TextDim, false, 0, 0), 0, r);
            AddRow(pad, "Abs", 16);

            // Timing card
            Card card = NewTimingCard("PROTECTION PAUSED", "22:21:24", "30 minutes from now",
                "Auto-shutdown comes back when the break ends", Theme.Cyan, "30", "MINUTES", 0.25);
            r = AddRow(pad, "Abs", 170);
            pad.Controls.Add(card, 0, r);

            // Presets
            AddRow(pad, "Abs", 16);
            int[] presets = { 15, 30, 40, 60 };
            TableLayoutPanel presetRow = NewGrid(presets.Length);
            presetRow.RowStyles.Clear();
            AddRow(presetRow, "Fill", 0);
            r = AddRow(pad, "Abs", 44);
            pad.Controls.Add(presetRow, 0, r);

            foreach (int val in presets) {
                NWButton b = NewNWButton(val + " min", BtnVariant.Ghost, null, 0, false, 0,
                                         val == 15 ? 0 : 8);
                b.Tag = val;
                b.Selected = (val == 30);
                b.AccessibleName = "Take a " + val + " minute study break";
                b.Click += delegate {
                    form.ChosenMinutes = val;
                    form.UsingCustom = false;
                    form.NumBox.Text = val.ToString();
                    form.ErrLabel.Text = "";
                    foreach (NWButton pb in form.Presets) pb.Selected = ((int)pb.Tag == val);
                    SyncTiming(form, val, false);
                    SyncAction(form, val);
                };
                form.Presets.Add(b);
                presetRow.Controls.Add(b, form.Presets.Count - 1, 0);
            }

            // Custom duration
            // Its own AutoSize row with a margin under it. It used to sit in a
            // fixed 22px row, which left it flush against the field below with
            // no breathing room, and the row was so short the text looked
            // cut off.
            r = AddRow(pad, "Auto", 0);
            pad.Controls.Add(NewLabel("OR SET A CUSTOM DURATION", 8f, Theme.TextMuted, true, 6, 0), 0, r);

            r = AddRow(pad, "Abs", 40);
            // The minus button, the number field and the plus button are one
            // group with fixed spacing, centred in the row. Docked to the
            // edges of the window they read as three unrelated controls.
            TableLayoutPanel customRow = NewGrid(3);
            customRow.Anchor = AnchorStyles.None;
            customRow.Width = 286;
            customRow.Height = 40;
            customRow.ColumnStyles.Clear();
            AddCol(customRow, "Abs", 40);
            AddCol(customRow, "Abs", 190);
            AddCol(customRow, "Abs", 40);
            customRow.Margin = new Padding(0);
            AddRow(customRow, "Fill", 0);
            pad.Controls.Add(customRow, 0, r);

            NWButton btnMinus = NewNWButton("", BtnVariant.Ghost, null, 1, true, 8, 0);
            btnMinus.AccessibleName = "Decrease duration by one minute";
            btnMinus.Click += delegate { SetCustom(form, -1); };

            Card field = new Card();
            field.Dock = DockStyle.Fill;
            field.Radius = 10;
            field.Margin = new Padding(0, 0, 8, 0);

            TextBox num = new TextBox();
            num.Dock = DockStyle.Fill;
            num.Text = "30";
            num.TextAlign = HorizontalAlignment.Center;
            num.Font = (Font)Theme.Num(11.5f, FontStyle.Regular).Clone();
            num.ForeColor = Theme.Text;
            // TextBox cannot be transparent; match the card fill behind it.
            num.BackColor = Theme.Surface;
            num.BorderStyle = BorderStyle.None;
            num.MaxLength = 6;
            num.Margin = new Padding(4, 0, 4, 0);
            num.AccessibleName = "Custom break duration in minutes, from 1 to 1440";
            field.Controls.Add(num);

            NWButton btnPlus = NewNWButton("", BtnVariant.Ghost, null, 2, true, 0, 8);
            btnPlus.AccessibleName = "Increase duration by one minute";
            btnPlus.Click += delegate { SetCustom(form, 1); };

            customRow.Controls.Add(btnMinus, 0, 0);
            customRow.Controls.Add(field, 1, 0);
            customRow.Controls.Add(btnPlus, 2, 0);

            r = AddRow(pad, "Abs", 22);
            Label errLabel = NewLabel("", 8.5f, Theme.Danger, false, 0, 0);
            pad.Controls.Add(errLabel, 0, r);

            // Footer
            AddRow(pad, "Fill", 0);
            r = AddRow(pad, "Abs", BTN_H);
            TableLayoutPanel actionRow = NewGrid(2);
            actionRow.ColumnStyles.Clear();
            AddCol(actionRow, "Abs", 96);
            AddCol(actionRow, "Fill", 0);
            AddRow(actionRow, "Fill", 0);
            pad.Controls.Add(actionRow, 0, r);

            NWButton btnCancel = NewNWButton("Cancel", BtnVariant.Ghost, null, 0, false, 8, 0);
            NWButton btnStart = NewNWButton("Start 30-minute break", BtnVariant.Primary,
                                            Theme.Cyan, 0, false, 0, 0);
            btnStart.Font = (Font)Theme.UiSemibold(10f).Clone();
            btnStart.AccessibleName = "Start the study break";
            actionRow.Controls.Add(btnCancel, 0, 0);
            actionRow.Controls.Add(btnStart, 1, 0);

            // --- selection wiring ---
            form.Card = card;
            form.NumBox = num;
            form.ErrLabel = errLabel;
            form.StartButton = btnStart;
            form.ChosenMinutes = 30;
            form.UsingCustom = false;
            form.BaseTime = DateTime.Now;

            // Live validation: never silently accept an out-of-range value.
            num.TextChanged += delegate {
                int v;
                bool ok = int.TryParse(form.NumBox.Text, out v) && v >= 1 && v <= 1440;
                form.UsingCustom = true;
                foreach (NWButton pb in form.Presets) pb.Selected = false;
                if (!ok) {
                    form.ErrLabel.Text = string.IsNullOrWhiteSpace(form.NumBox.Text)
                        ? "" : "Enter a whole number from 1 to 1440.";
                    form.StartButton.Enabled = false;
                    return;
                }
                form.ErrLabel.Text = "";
                form.ChosenMinutes = v;
                SyncTiming(form, v, true);
                SyncAction(form, v);
            };

            btnCancel.Click += delegate { form.ChosenMinutes = 0; form.Close(); };

            btnStart.Click += delegate {
                int v;
                if (!int.TryParse(form.NumBox.Text, out v) || v < 1 || v > 1440) {
                    form.ErrLabel.Text = "Enter a whole number from 1 to 1440.";
                    form.NumBox.Focus();
                    return;
                }
                form.ChosenMinutes = v;
                form.Close();
            };

            // Keep the on-screen end time honest against the wall clock.
            // Timing only - never touch the action state or the ring value
            // here, or this timer would restart the ring animation every second.
            Timer clock = new Timer();
            clock.Interval = 1000;
            clock.Tick += delegate {
                form.BaseTime = DateTime.Now;
                SyncTiming(form, form.ChosenMinutes, form.UsingCustom);
            };
            form.Clock = clock;

            form.AcceptButton = btnStart;
            form.CancelButton = btnCancel;

            SyncTiming(form, 30, false);
            SyncAction(form, 30);
            FitToContent(form, pad, HEADER_H, FORM_W);
            return form;
        }

        // -----------------------------------------------------------------
        // Active break (live countdown)
        // -----------------------------------------------------------------
        public static ActiveForm NewActiveForm(DateTime expiresAt, int totalMinutes)
        {
            ActiveForm form = new ActiveForm();
            ConfigureBase(form, "NightWatch", 340);

            TableLayoutPanel outer = NewGrid(1);
            outer.BackColor = Theme.Bg;
            form.Controls.Add(outer);

            AddRow(outer, "Abs", HEADER_H);
            NewHeader(outer, "BREAK ACTIVE", Theme.Success);

            TableLayoutPanel pad = NewGrid(1);
            pad.BackColor = Theme.Bg;
            pad.Padding = new Padding(22, 18, 22, 18);
            AddRow(outer, "Fill", 0);
            outer.Controls.Add(pad, 0, 1);

            int r = AddRow(pad, "Auto", 0);
            Label h = new Label();
            h.Text = "You're on a break";
            h.Font = (Font)Theme.UiSemibold(13.5f).Clone();
            h.ForeColor = Theme.Text;
            h.BackColor = Color.Transparent;
            h.AutoSize = true;
            h.Dock = DockStyle.Fill;
            h.Margin = new Padding(0, 0, 0, 14);
            pad.Controls.Add(h, 0, r);

            int total = Math.Max(1, totalMinutes);
            Card card = NewTimingCard("BREAK ENDS AT", expiresAt.ToString("HH:mm:ss"),
                "of a " + total + "-minute break", "Auto-shutdown stays paused until the break ends.",
                Theme.Success, "0", "MIN LEFT", 1.0);
            r = AddRow(pad, "Abs", 170);
            pad.Controls.Add(card, 0, r);

            AddRow(pad, "Fill", 0);
            r = AddRow(pad, "Abs", BTN_H);
            TableLayoutPanel split = NewGrid(2);
            AddRow(split, "Fill", 0);
            pad.Controls.Add(split, 0, r);

            NWButton btnKeep = NewNWButton("Keep break", BtnVariant.Ghost, null, 0, false, 8, 0);
            NWButton btnEnd = NewNWButton("End break now", BtnVariant.Danger, Theme.Danger, 0, false, 0, 8);
            split.Controls.Add(btnKeep, 0, 0);
            split.Controls.Add(btnEnd, 1, 0);

            form.Card = card;
            form.KeepButton = btnKeep;
            form.EndNow = false;
            btnKeep.Click += delegate { form.EndNow = false; form.Close(); };
            btnEnd.Click += delegate { form.EndNow = true; form.Close(); };

            DateTime endInstant = expiresAt;
            int totalM = total;

            // One update routine, invoked once up front and then on every
            // tick, so the first painted frame already shows the real
            // remaining time.
            Action update = delegate {
                TimeSpan left = endInstant - DateTime.Now;
                if (left.TotalSeconds < 0) left = TimeSpan.Zero;
                int mins = (int)Math.Ceiling(left.TotalMinutes);
                if (mins < 0) mins = 0;
                // The time goes first. If anything below throws, the clock
                // still shows the right time instead of going blank.
                form.Card.TimeLabel.Text = endInstant.ToString("HH:mm:ss");
                form.Card.Ring.CenterBig = mins.ToString();
                double frac = left.TotalMinutes / totalM;
                form.Card.Ring.Value = Math.Max(0.0, Math.Min(1.0, frac));
            };

            Timer timer = new Timer();
            timer.Interval = 250;
            timer.Tick += delegate { update(); };
            update();

            form.Clock = timer;
            form.AcceptButton = btnKeep;
            form.CancelButton = btnKeep;
            FitToContent(form, pad, HEADER_H, FORM_W);
            return form;
        }

        // -----------------------------------------------------------------
        // Status card (break started / protection re-armed)
        // -----------------------------------------------------------------
        public static Form NewStatusForm(string kicker, string headline, string detail,
                                         string timeLine, string footNote, Color tint,
                                         string ringBig, string buttonText)
        {
            Form form = new Form();
            ConfigureBase(form, "NightWatch", 340);

            TableLayoutPanel outer = NewGrid(1);
            outer.BackColor = Theme.Bg;
            form.Controls.Add(outer);

            AddRow(outer, "Abs", HEADER_H);
            NewHeader(outer, kicker, tint);

            TableLayoutPanel pad = NewGrid(1);
            pad.BackColor = Theme.Bg;
            pad.Padding = new Padding(22, 20, 22, 20);
            AddRow(outer, "Fill", 0);
            outer.Controls.Add(pad, 0, 1);

            // AutoSize row: a fixed row clipped the headline to 6px and the
            // text was invisible. Let the row take the label's own height.
            int r = AddRow(pad, "Auto", 0);
            Label hl = new Label();
            hl.Text = headline;
            hl.Font = (Font)Theme.UiSemibold(13.5f).Clone();
            hl.ForeColor = Theme.Text;
            hl.BackColor = Color.Transparent;
            hl.AutoSize = true;
            hl.Dock = DockStyle.Fill;
            hl.Margin = new Padding(0, 0, 0, 14);
            pad.Controls.Add(hl, 0, r);

            r = AddRow(pad, "Abs", 170);
            Card card = NewTimingCard("AUTO-OFF AT", timeLine, detail, footNote,
                tint, ringBig, "MIN", 1.0);
            pad.Controls.Add(card, 0, r);

            AddRow(pad, "Fill", 0);
            r = AddRow(pad, "Abs", BTN_H);
            NWButton btn = NewNWButton(buttonText, BtnVariant.Primary, tint, 0, false, 0, 0);
            btn.Font = (Font)Theme.UiSemibold(10f).Clone();
            btn.Click += delegate { form.Close(); };
            pad.Controls.Add(btn, 0, r);

            form.AcceptButton = btn;
            form.CancelButton = btn;
            FitToContent(form, pad, HEADER_H, FORM_W);
            return form;
        }
    }
}