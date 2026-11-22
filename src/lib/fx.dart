import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

// ============================================================ خلفية متحركة
class FxBackground extends StatefulWidget {
  const FxBackground({super.key});
  @override
  State<FxBackground> createState() => _FxBackgroundState();
}

class _FxBackgroundState extends State<FxBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 24))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
              painter: _BgPainter(_c.value), size: Size.infinite),
        ),
      );
}

class _BgPainter extends CustomPainter {
  final double t;
  _BgPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0D1E), Color(0xFF10122B), Color(0xFF090A18)],
        ).createShader(rect),
    );
    void blob(double phase, double rx, double ry, double cx, double cy,
        double r, Color c) {
      final a = (t + phase) * 2 * math.pi;
      final o = Offset(size.width * (cx + rx * math.cos(a)),
          size.height * (cy + ry * math.sin(a * 0.8)));
      final rad = size.shortestSide * r;
      canvas.drawCircle(
        o,
        rad,
        Paint()
          ..shader = RadialGradient(colors: [c, c.withOpacity(0)])
              .createShader(Rect.fromCircle(center: o, radius: rad)),
      );
    }

    blob(0.0, 0.25, 0.10, 0.25, 0.18, 0.75, const Color(0x556C5CE7));
    blob(0.4, 0.22, 0.12, 0.85, 0.55, 0.70, const Color(0x4400C2FF));
    blob(0.7, 0.20, 0.10, 0.30, 0.90, 0.65, const Color(0x44FF4FA3));
  }

  @override
  bool shouldRepaint(_BgPainter o) => o.t != t;
}

// ============================================================ كرت 3D
// يميل مع اللمس، ظل عميق، لمعة تتحرك، ودخول متدرّج بالأنميشن.
class FxCard extends StatefulWidget {
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry margin;
  const FxCard({
    super.key,
    required this.child,
    this.color,
    this.margin = const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
  });
  @override
  State<FxCard> createState() => _FxCardState();
}

class _FxCardState extends State<FxCard> with SingleTickerProviderStateMixin {
  static int _seq = 0;
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 650));
  Timer? _timer;
  double _rx = 0, _ry = 0; // ميلان
  double _lx = 0, _ly = 0; // موضع اللمعة (-1..1)
  bool _down = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    if (now.difference(_last).inMilliseconds > 400) _seq = 0;
    _last = now;
    final delay = math.min(_seq++, 8) * 70;
    _timer = Timer(Duration(milliseconds: delay), () {
      if (mounted) _in.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _in.dispose();
    super.dispose();
  }

  void _track(PointerEvent e) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final s = box.size;
    final dx = (e.localPosition.dx / s.width).clamp(0.0, 1.0) * 2 - 1;
    final dy = (e.localPosition.dy / s.height).clamp(0.0, 1.0) * 2 - 1;
    setState(() {
      _down = true;
      _ry = dx * 0.10;
      _rx = -dy * 0.10;
      _lx = dx;
      _ly = dy;
    });
  }

  void _release() => setState(() {
        _down = false;
        _rx = 0;
        _ry = 0;
        _lx = 0;
        _ly = 0;
      });

  @override
  Widget build(BuildContext context) {
    final tint = widget.color;
    final base = tint ?? const Color(0xFF8E8CFF);
    return AnimatedBuilder(
      animation: _in,
      builder: (_, child) {
        final v = Curves.easeOutCubic.transform(_in.value);
        return Opacity(
          opacity: v,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015)
              ..translate(0.0, 36 * (1 - v), -60 * (1 - v))
              ..rotateX(0.45 * (1 - v)),
            child: child,
          ),
        );
      },
      child: Listener(
        onPointerDown: _track,
        onPointerMove: _track,
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: Padding(
          padding: widget.margin,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            transformAlignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0016)
              ..rotateX(_rx)
              ..rotateY(_ry)
              ..scale(_down ? 0.985 : 1.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(_down ? 0.35 : 0.55),
                    blurRadius: _down ? 14 : 28,
                    offset: Offset(-_ry * 60, _down ? 6 : 16 + _rx * -40)),
                BoxShadow(
                    color: base.withOpacity(0.16),
                    blurRadius: 30,
                    spreadRadius: -6,
                    offset: const Offset(0, 8)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Stack(children: [
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF23264A),
                        const Color(0xFF14162E),
                      ],
                    ),
                    border: Border.all(
                        color: Colors.white.withOpacity(0.10), width: 1),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  foregroundDecoration: tint == null
                      ? null
                      : BoxDecoration(
                          color: tint, borderRadius: BorderRadius.circular(22)),
                  child: Material(
                      type: MaterialType.transparency, child: widget.child),
                ),
                // لمعة تتحرك مع الميلان
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(-1 + _lx * 0.9, -1 + _ly * 0.9),
                          end: Alignment(1 + _lx * 0.9, 1 + _ly * 0.9),
                          colors: [
                            Colors.white.withOpacity(_down ? 0.16 : 0.07),
                            Colors.white.withOpacity(0.0),
                            Colors.white.withOpacity(0.02),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================ نقطة حالة تنبض
class FxDot extends StatefulWidget {
  final Color color;
  final double size;
  const FxDot({super.key, required this.color, this.size = 12});
  @override
  State<FxDot> createState() => _FxDotState();
}

class _FxDotState extends State<FxDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));

  bool get _live => widget.color != Colors.grey;

  @override
  void initState() {
    super.initState();
    if (_live) _c.repeat();
  }

  @override
  void didUpdateWidget(FxDot old) {
    super.didUpdateWidget(old);
    if (_live && !_c.isAnimating) _c.repeat();
    if (!_live && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2.4,
      height: s * 2.4,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final v = _live ? _c.value : 0.0;
          return Stack(alignment: Alignment.center, children: [
            if (_live)
              Container(
                width: s * (1 + 1.3 * v),
                height: s * (1 + 1.3 * v),
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withOpacity(0.35 * (1 - v))),
              ),
            Container(
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.3),
                    colors: [Colors.white.withOpacity(0.9), widget.color]),
                boxShadow: _live
                    ? [BoxShadow(color: widget.color.withOpacity(0.8), blurRadius: 8)]
                    : null,
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ============================================================ شريط تبويب فخم
class FxTabBar extends StatelessWidget implements PreferredSizeWidget {
  final TabController controller;
  final List<Widget> tabs;
  const FxTabBar({super.key, required this.controller, required this.tabs});

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: TabBar(
          controller: controller,
          tabs: tabs,
          dividerColor: Colors.transparent,
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: const EdgeInsets.all(4),
          splashBorderRadius: BorderRadius.circular(20),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          unselectedLabelColor: Colors.white60,
          labelColor: Colors.white,
          indicator: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
                colors: [Color(0xFF6C5CE7), Color(0xFF00B7FF)]),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF6C5CE7).withOpacity(0.55),
                  blurRadius: 14,
                  offset: const Offset(0, 4)),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================ نص بتدرّج لوني
class FxGradText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextDirection? textDirection;
  const FxGradText(this.text, {super.key, this.style, this.textDirection});
  @override
  Widget build(BuildContext context) => ShaderMask(
        shaderCallback: (r) => const LinearGradient(
                colors: [Colors.white, Color(0xFF9FE7FF)])
            .createShader(r),
        blendMode: BlendMode.srcIn,
        child: Text(text,
            textDirection: textDirection,
            style: (style ?? const TextStyle()).copyWith(color: Colors.white)),
      );
}

// ============================================================ زر الفخم (FAB)
Widget fxFabSwitch(int key, Widget? child) => AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (c, a) => ScaleTransition(
          scale: a, child: FadeTransition(opacity: a, child: c)),
      child: KeyedSubtree(
          key: ValueKey(key), child: child ?? const SizedBox.shrink()),
    );

// ============================================================ انتقال الصفحات 3D
class FxTransitions extends PageTransitionsBuilder {
  const FxTransitions();
  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child) {
    final inA = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(CurvedAnimation(
          parent: secondaryAnimation, curve: Curves.easeIn)),
      child: AnimatedBuilder(
        animation: inA,
        builder: (_, ch) {
          final v = inA.value;
          return Opacity(
            opacity: v.clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.centerRight,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..translate(60.0 * (1 - v), 0.0, -120.0 * (1 - v))
                ..rotateY(-0.35 * (1 - v)),
              child: ch,
            ),
          );
        },
        child: child,
      ),
    );
  }
}
