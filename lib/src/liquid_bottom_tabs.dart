import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// Faithful port of the AndroidLiquidGlass `LiquidBottomTabs` effect (
/// Kyant0/AndroidLiquidGlass → `LiquidBottomTabs`) onto `liquid_glass_easy`.
///
/// Mirrors the reference composite:
///   1. a full-width glass **bar** capsule (vibrancy + blur + lens) with the
///      tab content and a radial interactive highlight,
///   2. an invisible accent **tint capture** layer behind the moving pill that
///      the pill's glass refracts on top of the body,
///   3. a moving glass **pill** whose refractive lens + white highlight +
///      outer shadow + inner shadow all scale with the press progress, and
///      whose `scaleX`/`scaleY` are driven by the reference
///      `DampedDragAnimation` springs, then stretched by the tracked release
///      velocity,
///   4. every tab scaled `lerp(1, 1.2, press)`.
///
/// The pill is draggable (press-and-drag to cue selection), taps on a tab
/// select it directly, and an external selection change travels the pill over
/// via the same springs.
class LiquidBottomTabs extends StatefulWidget {
  const LiquidBottomTabs({
    super.key,
    required this.body,
    required this.width,
    required this.height,
    required this.bottomMargin,
    required this.itemPadding,
    required this.selectedIndex,
    required this.onChanged,
    required this.items,
    required this.itemStyle,
    required this.barStyle,
    required this.pillStyle,
    this.reduceMotion = false,
    this.pixelRatio = 1.0,
    this.useSync = true,
    this.useImpellerBackdrop,
  });

  /// The full-screen content captured behind the glass (Android's `backdrop`).
  final Widget body;

  /// Bar width.
  final double width;

  /// Bar height (capsule).
  final double height;

  /// Gap between the bar and the bottom safe-area inset.
  final double bottomMargin;

  /// Horizontal inset between the bar edge and the tab row / pill.
  final double itemPadding;

  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final bool reduceMotion;
  final List<LiquidGlassTabBarItem> items;
  final LiquidGlassNavItemStyle itemStyle;
  final LiquidGlassStyle barStyle;
  final LiquidGlassStyle pillStyle;
  final double pixelRatio;
  final bool useSync;
  final bool? useImpellerBackdrop;

  @override
  State<LiquidBottomTabs> createState() => _LiquidBottomTabsState();
}

double _damping(double zeta, double stiffness) =>
    2 * zeta * math.sqrt(stiffness);

class _LiquidBottomTabsState extends State<LiquidBottomTabs>
    with TickerProviderStateMixin {
  // Dual capture pipeline (the `backdrop` + `tabsBackdrop` roles).
  // Inner captures the body + bar capsule; outer captures the inner output so
  // the moving pill can refract the bar's own glass — the reference's
  // `rememberCombinedBackdrop(backdrop, tabsBackdrop)`.
  final LiquidGlassViewController _innerController = LiquidGlassViewController();
  final LiquidGlassViewController _outerController = LiquidGlassViewController();

  // DampedDragAnimation springs, reference constants 1:1.
  late final _SpringDriver _value;
  late final _SpringDriver _velocity;
  late final _SpringDriver _pressProgress;
  late final _SpringDriver _scaleX;
  late final _SpringDriver _scaleY;

  // Offset spring the pill/bar "panel" follows while dragging, then eases
  // back (reference `offsetAnimation` → `panelOffset`).
  late final _SpringDriver _panelOffsetSpring;

  static const double _pressedScale = 78 / 56;
  static const double _tabScale = 1.2;
  static const double _panelOffsetPx = 4;
  static const double _visibilityThreshold = 0.001;

  int _currentIndex = 0;
  int _lastReportedIndex = 0;
  bool _pendingRelease = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.selectedIndex;
    _lastReportedIndex = widget.selectedIndex;
    _value = _SpringDriver.withTicker(
      this,
      zeta: 1,
      stiffness: 1000,
      threshold: _visibilityThreshold,
      initial: widget.selectedIndex.toDouble(),
    );
    _velocity = _SpringDriver.withTicker(
      this,
      zeta: 0.5,
      stiffness: 300,
      threshold: _visibilityThreshold * 10,
    );
    _pressProgress = _SpringDriver.withTicker(
      this,
      zeta: 1,
      stiffness: 1000,
      threshold: _visibilityThreshold,
    );
    _scaleX = _SpringDriver.withTicker(
      this,
      zeta: 0.6,
      stiffness: 250,
      threshold: _visibilityThreshold,
      initial: 1,
    );
    _scaleY = _SpringDriver.withTicker(
      this,
      zeta: 0.7,
      stiffness: 250,
      threshold: _visibilityThreshold,
      initial: 1,
    );
    _panelOffsetSpring = _SpringDriver.withTicker(
      this,
      zeta: 1,
      stiffness: 300,
      threshold: 0.5,
    );
    _value.ctrl.addListener(_onValueTick);
  }

  @override
  void didUpdateWidget(covariant LiquidBottomTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int index = widget.selectedIndex;
    if (index == oldWidget.selectedIndex) return;
    if (widget.reduceMotion) {
      _value.snapTo(index.toDouble());
      _velocity.snapTo(0);
      _currentIndex = index;
      _lastReportedIndex = index;
      return;
    }
    if (_currentIndex == index) return;
    _currentIndex = index;
    _animateToValue(index.toDouble());
  }

  @override
  void dispose() {
    _value.ctrl.removeListener(_onValueTick);
    _value.dispose();
    _velocity.dispose();
    _pressProgress.dispose();
    _scaleX.dispose();
    _scaleY.dispose();
    _panelOffsetSpring.dispose();
    _innerController.detach();
    _outerController.detach();
    super.dispose();
  }

  int get _count => math.max(widget.items.length, 1);
  double get _range => math.max((_count - 1).toDouble(), 1);
  double get _tabWidth => (widget.width - 2 * widget.itemPadding) / _count;

  void _onValueTick() {
    _trackVelocity();
    if (_pendingRelease && !_value.ctrl.isAnimating) {
      _pendingRelease = false;
      _release();
    }
  }

  void _trackVelocity() {
    final v = _value.ctrl.velocity;
    if (!v.isFinite || v == 0) return;
    _velocity.animateTo(v / _range);
  }

  void _press() {
    if (widget.reduceMotion) return;
    _pressProgress.animateTo(1);
    _scaleX.animateTo(_pressedScale);
    _scaleY.animateTo(_pressedScale);
  }

  void _release() {
    if (widget.reduceMotion) return;
    _pressProgress.animateTo(0);
    _scaleX.animateTo(1);
    _scaleY.animateTo(1);
  }

  void _animateToValue(double target) {
    final clamped = target.clamp(0.0, _range);
    _press();
    _value.animateTo(clamped);
    if (_velocity.value.abs() > 0.001) _velocity.animateTo(0);
    if ((_value.value - clamped).abs() < 0.025 * _range) {
      _release();
    } else {
      _pendingRelease = true;
    }
  }

  void _onDragStart() {
    _press();
  }

  void _onDragUpdate({required double dx}) {
    if (widget.reduceMotion) return;
    _value.animateTo((_value.targetValue + dx / _tabWidth).clamp(0.0, _range));
    _panelOffsetSpring.snapTo(_panelOffsetSpring.value + dx);
  }

  void _onDragEnd() {
    if (widget.reduceMotion) return;
    final targetIndex = _value.targetValue.round().clamp(0, _count - 1);
    _currentIndex = targetIndex;
    _animateToValue(targetIndex.toDouble());
    _panelOffsetSpring.animateTo(0);
    if (targetIndex != _lastReportedIndex) {
      _lastReportedIndex = targetIndex;
      widget.onChanged(targetIndex);
    }
  }

  void _onTabTap(int index) {
    widget.onChanged(index);
  }

  double get _panelOffset {
    final fraction = (_panelOffsetSpring.value / math.max(widget.width, 1))
        .clamp(-1.0, 1.0)
        .toDouble();
    return _panelOffsetPx * fraction.sign * Curves.easeOut.transform(fraction.abs());
  }

  double get _barScale {
    return 1 + (16 / math.max(widget.width, 1)) * _pressProgress.value;
  }

  (double, double) get _pillScale {
    var sx = _scaleX.value;
    var sy = _scaleY.value;
    final v = (_velocity.value / 10).toDouble();
    sx /= 1 - (v * 0.75).clamp(-0.2, 0.2);
    sy *= 1 - (v * 0.25).clamp(-0.2, 0.2);
    return (sx, sy);
  }

  double get _pillPosition {
    final base = widget.reduceMotion
        ? _currentIndex * _tabWidth
        : _value.value * _tabWidth;
    return base + _panelOffset;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final barBottom = widget.bottomMargin + bottomInset;

    return LiquidGlassView(
      controller: _outerController,
      pixelRatio: widget.pixelRatio,
      useSync: widget.useSync,
      useImpellerBackdrop: widget.useImpellerBackdrop,
      realTimeCapture: true,
      backgroundWidget: _buildInner(barBottom: barBottom),
      child: LayoutBuilder(
        builder: (context, constraints) => _buildOuterPill(
          barBottom: barBottom,
          parentWidth: constraints.maxWidth,
          parentHeight: constraints.maxHeight,
        ),
      ),
    );
  }

  // ── Inner pipeline: body + bar capsule (reference _buildInner + bar Row) ──
  Widget _buildInner({required double barBottom}) {
    return LiquidGlassView(
      controller: _innerController,
      pixelRatio: widget.pixelRatio,
      useSync: widget.useSync,
      useImpellerBackdrop: widget.useImpellerBackdrop,
      realTimeCapture: true,
      backgroundWidget: widget.body,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            _barCapsuleLayer(
              barBottom: barBottom,
              parentWidth: constraints.maxWidth,
              parentHeight: constraints.maxHeight,
            ),
            _accentTintLayer(
              barBottom: barBottom,
              parentWidth: constraints.maxWidth,
              parentHeight: constraints.maxHeight,
            ),
          ],
        ),
      ),
    );
  }

  double _barTop(double barBottom, double parentHeight) =>
      parentHeight - barBottom - widget.height;

  Widget _barCapsuleLayer({
    required double barBottom,
    required double parentWidth,
    required double parentHeight,
  }) {
    final barTop = _barTop(barBottom, parentHeight);
    return Positioned(
      left: (parentWidth - widget.width) / 2,
      top: barTop,
      width: widget.width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: Listenable.merge([_panelOffsetSpring.ctrl, _pressProgress.ctrl]),
        builder: (context, _) {
          final translate = _panelOffset;
          final scale = widget.reduceMotion ? 1.0 : _barScale;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..translateByDouble(translate, 0, 0, 1)
              ..scaleByDouble(scale, scale, 1, 1),
            child: _CapsuleBar(
              barStyle: widget.barStyle,
              itemPadding: widget.itemPadding,
              height: widget.height,
              dark: _isDark,
              tabs: _buildTabs(),
              highlightCenter: _highlightCenter(parentWidth),
              highlightProgress: _pressProgress.value,
            ),
          );
        },
      ),
    );
  }

  // The accent tint capture layer — the `tabsBackdrop` role. Rendered at the
  // pill's exact region so the outer pill lens refracts it (combined
  // backdrop), tinting the content visible through the pill. Invisible
  // outside the pill's footprint.
  Widget _accentTintLayer({
    required double barBottom,
    required double parentWidth,
    required double parentHeight,
  }) {
    final barTop = _barTop(barBottom, parentHeight);
    return Positioned(
      left: (parentWidth - widget.width) / 2 + widget.itemPadding,
      top: barTop + widget.itemPadding,
      width: _tabWidth,
      height: widget.height - 2 * widget.itemPadding,
      child: AnimatedBuilder(
        animation: _value.ctrl,
        builder: (context, _) {
          final x = _pillPosition;
          return Transform.translate(
            offset: Offset(x, 0),
            child: _AccentTintCapsule(
              accent: _accentColor,
            ),
          );
        },
      ),
    );
  }

  double _highlightCenter(double parentWidth) => widget.reduceMotion
      ? _currentIndex * _tabWidth + _tabWidth / 2
      : _value.value * _tabWidth + _tabWidth / 2;

  Color get _accentColor {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? const Color(0xFF0091FF)
        : const Color(0xFF0088FF);
  }

  bool get _isDark =>
      Theme.of(context).brightness == Brightness.dark;

  Widget _buildTabs() {
    return Row(
      children: [
        for (int i = 0; i < _count; i++)
          Expanded(
            child: AnimatedBuilder(
              animation: _pressProgress.ctrl,
              builder: (context, _) {
                final scale = widget.reduceMotion
                    ? 1.0
                    : 1 + (_tabScale - 1) * _pressProgress.value;
                return Transform.scale(
                  scale: scale,
                  child: _TabCell(
                    item: widget.items[i],
                    selected: i == _currentIndex,
                    itemStyle: widget.itemStyle,
                    onTap: () => _onTabTap(i),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  // ── Outer pipeline: the moving glass pill ─────────────────────────────
  Widget _buildOuterPill({
    required double barBottom,
    required double parentWidth,
    required double parentHeight,
  }) {
    final barTop = _barTop(barBottom, parentHeight);
    final pillHeight = widget.height - 2 * widget.itemPadding;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: (parentWidth - widget.width) / 2 + widget.itemPadding,
          top: barTop + widget.itemPadding,
          width: _tabWidth,
          height: pillHeight,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _value.ctrl,
              _velocity.ctrl,
              _pressProgress.ctrl,
              _scaleX.ctrl,
              _scaleY.ctrl,
              _panelOffsetSpring.ctrl,
            ]),
            builder: (context, _) {
              final (sx, sy) = widget.reduceMotion ? (1.0, 1.0) : _pillScale;
              return Transform.translate(
                offset: Offset(_pillPosition, 0),
                transformHitTests: true,
                child: GestureDetector(
                  key: const Key('liquid_pill'),
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (_) => _onDragStart(),
                  onHorizontalDragUpdate: (d) =>
                      _onDragUpdate(dx: d.delta.dx),
                  onHorizontalDragEnd: (_) => _onDragEnd(),
                  onHorizontalDragCancel: _onDragEnd,
                  child: Transform.scale(
                    scaleX: sx,
                    scaleY: sy,
                    alignment: Alignment.center,
                    child: _PillGlass(
                      pillStyle: widget.pillStyle,
                      width: _tabWidth,
                      height: pillHeight,
                      accent: _accentColor,
                      dark: _isDark,
                      press: _pressProgress.value,
                      reduceMotion: widget.reduceMotion,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Foundation: one spring-driven double (reference Animatable + spring) ──
class _SpringDriver {
  _SpringDriver.withTicker(
    TickerProvider vsync, {
    required double zeta,
    required double stiffness,
    required double threshold,
    double initial = 0,
  })  : _spring = SpringDescription(
          mass: 1,
          stiffness: stiffness,
          damping: _damping(zeta, stiffness),
        ),
        ctrl = AnimationController.unbounded(
          vsync: vsync,
          value: initial,
        ) {
    _tolerance = Tolerance(distance: threshold);
  }

  final SpringDescription _spring;
  final AnimationController ctrl;
  late final Tolerance _tolerance;
  double _targetValue = 0;

  double get value => ctrl.value;
  double get targetValue => _targetValue;

  void animateTo(double target) {
    _targetValue = target;
    ctrl.animateWith(SpringSimulation(
      _spring,
      ctrl.value,
      target,
      ctrl.velocity,
      tolerance: _tolerance,
    ));
  }

  void snapTo(double v) {
    _targetValue = v;
    ctrl.stop();
    ctrl.value = v;
  }

  void dispose() => ctrl.dispose();
}

// ── Bar capsule: full-width glass + tab content + interactive highlight ──
class _CapsuleBar extends StatelessWidget {
  const _CapsuleBar({
    required this.barStyle,
    required this.itemPadding,
    required this.height,
    required this.dark,
    required this.tabs,
    required this.highlightCenter,
    required this.highlightProgress,
  });

  final LiquidGlassStyle barStyle;
  final double itemPadding;
  final double height;
  final bool dark;
  final Widget tabs;
  final double highlightCenter;
  final double highlightProgress;

  @override
  Widget build(BuildContext context) {
    final containerColor = dark
        ? const Color(0xFF121212).withValues(alpha: 0.4)
        : const Color(0xFFFAFAFA).withValues(alpha: 0.4);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: itemPadding),
      child: LiquidGlassLens(
        style: barStyle,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: containerColor),
            tabs,
            if (highlightProgress > 0)
              CustomPaint(
                painter: _InteractiveHighlightPainter(
                  progress: highlightProgress,
                  centerX: highlightCenter,
                  height: height,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Accent tint capture capsule (the `tabsBackdrop` role) ───────────────
class _AccentTintCapsule extends StatelessWidget {
  const _AccentTintCapsule({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(500),
      ),
    );
  }
}

// ── Tab cell: icon + label, scaled lerp(1, 1.2, press) (LiquidBottomTab) ──
class _TabCell extends StatelessWidget {
  const _TabCell({
    required this.item,
    required this.selected,
    required this.itemStyle,
    required this.onTap,
  });

  final LiquidGlassTabBarItem item;
  final bool selected;
  final LiquidGlassNavItemStyle itemStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = itemStyle.colorFor(selected: selected);
    final fontWeight = itemStyle.fontWeightFor(selected: selected);
    final icon = (selected && item.selectedIcon != null)
        ? item.selectedIcon!
        : item.icon;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(500),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: itemStyle.iconSize,
              color: color,
            ),
            if (item.label != null)
              Padding(
                padding: EdgeInsets.only(top: itemStyle.iconLabelGap),
                child: Text(
                  item.label!,
                  style: TextStyle(
                    color: color,
                    fontSize: itemStyle.labelFontSize,
                    fontWeight: fontWeight,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Pill: refractive glass + highlight + shadow + inner shadow + surface ──
class _PillGlass extends StatelessWidget {
  const _PillGlass({
    required this.pillStyle,
    required this.width,
    required this.height,
    required this.accent,
    required this.dark,
    required this.press,
    required this.reduceMotion,
  });

  final LiquidGlassStyle pillStyle;
  final double width;
  final double height;
  final Color accent;
  final bool dark;
  final double press;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final refraction = pillStyle.refraction.copyWith(
      distortion: pillStyle.refraction.distortion * press,
      distortionWidth: pillStyle.refraction.distortionWidth * press,
      magnification:
          reduceMotion ? 1.0 : 1 + (pillStyle.refraction.magnification - 1) * press,
      chromaticAberration: pillStyle.refraction.chromaticAberration * press,
    );
    final baseColor = dark
        ? Colors.white.withValues(alpha: 0.1 * (1 - press))
        : Colors.black.withValues(alpha: 0.1 * (1 - press));
    final surfaceColor = Colors.black.withValues(alpha: 0.03 * press);
    final shadowAlpha = press;
    final highlightAlpha = press;

    return LiquidGlassLens(
      style: LiquidGlassStyle(
        shape: pillStyle.shape,
        appearance: pillStyle.appearance,
        refraction: refraction,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(500),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: baseColor),
            ColoredBox(color: surfaceColor),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(500),
                boxShadow: [
                  if (shadowAlpha > 0 && !reduceMotion)
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25 * shadowAlpha),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                ],
              ),
            ),
            CustomPaint(
              painter: _PillHighlightPainter(
                width: width,
                height: height,
                accent: accent,
                alpha: highlightAlpha,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Radial white interactive highlight (BlendMode.Plus, minDim * 1.5) ──
class _InteractiveHighlightPainter extends CustomPainter {
  _InteractiveHighlightPainter({
    required this.progress,
    required this.centerX,
    required this.height,
  });

  final double progress;
  final double centerX;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    const white = Colors.white;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = white.withValues(alpha: 0.08 * progress)
        ..blendMode = BlendMode.plus,
    );
    final radius = math.min(size.width, size.height) * 1.5;
    final paint = Paint()..blendMode = BlendMode.plus;
    final center = Offset(centerX, size.height / 2);
    final shader = RadialGradient(
      colors: [
        white.withValues(alpha: 0.15 * progress),
        white.withValues(alpha: 0.0),
      ],
    ).createShader(
      Rect.fromCircle(center: center, radius: radius),
    );
    paint.shader = shader;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_InteractiveHighlightPainter old) =>
      old.progress != progress || old.centerX != centerX || old.height != height;
}

// ── Pill inner surface sheen following the press spring ────────────────
class _PillHighlightPainter extends CustomPainter {
  _PillHighlightPainter({
    required this.width,
    required this.height,
    required this.accent,
    required this.alpha,
  });

  final double width;
  final double height;
  final Color accent;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    if (alpha <= 0) return;
    final rect = Rect.fromLTWH(0, 0, width, height);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.35 * alpha),
          Colors.white.withValues(alpha: 0.0),
          accent.withValues(alpha: 0.35 * alpha),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(height / 2)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_PillHighlightPainter old) =>
      old.alpha != alpha || old.width != width || old.height != height;
}