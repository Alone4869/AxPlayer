# 导航栏复刻 AndroidLiquidGlass LiquidBottomTabs 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `HomeScreen` 的浮动导航栏完整复刻为 AndroidLiquidGlass `LiquidBottomTabs` 形态：全宽胶囊底栏 + 可横向拖拽/按压缩放/accent 着色的放大镜 Pill + 拖拽时整栏反向偏移回弹。

**Architecture:** 复用 `liquid_glass_easy` 包的 `LiquidGlassBottomNavBar` 渲染底栏玻璃、内容 Row 与点击语义（内部 Pill 保持隐藏 `mode: none, show: false`），在其上覆盖一层自研、可交互的 `LiquidGlassLens` Pill。Pill 由三个 AnimationController 驱动：`_position`（Pill 位置，SpringSimulation）、`_panelOffset`（整栏水平偏移，拖拽累计+回弹）、`_press`（按压缩放进度）。全部改动集中在 `lib/src/app.dart` 与新增 `test/liquid_nav_bar_test.dart`。

**Tech Stack:** Flutter, `liquid_glass_easy` ^3.3.0（`LiquidGlassStyle`/`LiquidGlassShape.continuousRoundedRectangle`/`LiquidGlassAppearance`/`LiquidGlassRefraction`/`LiquidGlassLens`/`LiquidGlassBottomNavBar`）, `package:flutter/physics.dart`（SpringSimulation）。

## Global Constraints

- `liquid_glass_easy` ^3.3.0 已在 `pubspec.yaml`，**不得新增依赖**。
- 视觉参数（spec 已确认，逐字取值）：
  - 底栏容器色：浅 `Color(0x66FAFAFA)`，深 `Color(0x66121212)`；饱和度 1.04；blur σ8；refraction distortion 0.06 / magnification 1.05 / chromaticAberration 0.0012；圆角 28。
  - Pill：accent 着色 `Color(0xFF0088FF)`（浅）/ `Color(0xFF0091FF)`（深）强度 ~0.3 应力在两个 shader 参数归一化范围内；refraction distortion 0.08 / distortionWidth 20 / magnification 1.15 / chromaticAberration 0.0025；圆角 28；按压缩放 1.39x。
  - Pill 宽 = `(barWidth - itemPadding*2) / items.length`；底栏高 **64**；`itemPadding` = 4。
- reduceMotion（`MediaQuery.disableAnimationsOf`）时：Pill 位置直接等于 `selectedIndex`，无弹簧/无按压缩放/无拖拽选择（仅点击切换）。
- `_SmoothLiquidNavigationBar` 重命名为公开类 `SmoothLiquidNavigationBar`（供测试），State 类 `_SmoothLiquidNavigationBarState` 保持私有。
- 每任务以 `flutter analyze` 无新告警 + `flutter test <对本任务文件>` 通过收尾。

---

### Task 1: 公开导航栏组件 + 点击切换测试

**Files:**
- Modify: `lib/src/app.dart:399-539`（类重命名，行为不变）
- Create: `test/liquid_nav_bar_test.dart`

**Interfaces:**
- Produces: 公开 widget `SmoothLiquidNavigationBar({required double width, required double height, required double bottomMargin, required double itemPadding, required int selectedIndex, required ValueChanged<int> onChanged, required bool reduceMotion, required List<LiquidGlassTabBarItem> items, required LiquidGlassNavItemStyle itemStyle, required LiquidGlassStyle barStyle, required LiquidGlassStyle pillStyle})`。后序任务沿用此签名。

- [ ] **Step 1: 写失败测试**

创建 `test/liquid_nav_bar_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:m3u8downloader/src/app.dart';

void main() {
  Widget harness({
    required ValueChanged<int> onChanged,
    int selectedIndex = 0,
    bool reduceMotion = false,
  }) {
    final style = LiquidGlassStyle(
      shape: LiquidGlassShape.continuousRoundedRectangle(cornerRadius: 28),
      appearance: const LiquidGlassAppearance(
        color: Color(0x66FAFAFA),
        saturation: 1.04,
        blur: LiquidGlassBlur(sigmaX: 8, sigmaY: 8),
      ),
      refraction: const LiquidGlassRefraction(
        distortion: 0.06,
        distortionWidth: 20,
        magnification: 1.05,
        chromaticAberration: 0.0012,
      ),
    );
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SmoothLiquidNavigationBar(
            width: 400,
            height: 64,
            bottomMargin: 0,
            itemPadding: 4,
            selectedIndex: selectedIndex,
            onChanged: onChanged,
            reduceMotion: reduceMotion,
            items: const [
              LiquidGlassTabBarItem(icon: Icons.home_outlined, label: 'A'),
              LiquidGlassTabBarItem(icon: Icons.download_outlined, label: 'B'),
              LiquidGlassTabBarItem(icon: Icons.dns_outlined, label: 'C'),
              LiquidGlassTabBarItem(icon: Icons.settings_outlined, label: 'D'),
            ],
            itemStyle: const LiquidGlassNavItemStyle(
              selectedColor: Color(0xFF0088FF),
              unselectedColor: Colors.black54,
              iconSize: 23,
              labelFontSize: 11,
              iconLabelGap: 3,
              selectedFontWeight: FontWeight.w700,
            ),
            barStyle: style,
            pillStyle: style,
          ),
        ),
      ),
    );
  }

  testWidgets('tapping a tab reports the new index', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(harness(onChanged: taps.add));

    await tester.tap(find.text('C'));
    await tester.pump();

    expect(taps, [2]);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 运行验证失败**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: FAIL — `Error: The name 'SmoothLiquidNavigationBar' isn't defined`.

- [ ] **Step 3: 重命名类**

在 `lib/src/app.dart` 中，将私有类 `_SmoothLiquidNavigationBar`（构造与字段，见当前 `app.dart:399-429`）改名为 `SmoothLiquidNavigationBar`，并给构造加 `super.key`：

```dart
class SmoothLiquidNavigationBar extends StatefulWidget {
  const SmoothLiquidNavigationBar({
    super.key,
    required this.width,
    required this.height,
    required this.bottomMargin,
    required this.itemPadding,
    required this.selectedIndex,
    required this.onChanged,
    required this.reduceMotion,
    required this.items,
    required this.itemStyle,
    required this.barStyle,
    required this.pillStyle,
  });

  final double width;
  final double height;
  final double bottomMargin;
  final double itemPadding;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final bool reduceMotion;
  final List<LiquidGlassTabBarItem> items;
  final LiquidGlassNavItemStyle itemStyle;
  final LiquidGlassStyle barStyle;
  final LiquidGlassStyle pillStyle;

  @override
  State<SmoothLiquidNavigationBar> createState() =>
      _SmoothLiquidNavigationBarState();
}
```

同步更新 `_HomeScreenState._buildLiquidNavigationBar` 的调用处（`app.dart:355` `_SmoothLiquidNavigationBar(` → `SmoothLiquidNavigationBar(`）。

- [ ] **Step 4: 运行验证通过**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: PASS（1 test）。`tester.takeException()` 为 null。

- [ ] **Step 5: Commit**

```bash
git add lib/src/app.dart test/liquid_nav_bar_test.dart
git commit -m "refactor: expose SmoothLiquidNavigationBar with tap test"
```

---

### Task 2: Android 全宽胶囊几何与玻璃参数

**Files:**
- Modify: `lib/src/app.dart:20`（`_bottomNavigationHeight` 68→64）
- Modify: `lib/src/app.dart:311-396`（`_buildLiquidNavigationBar` 几何与样式；`_selectDestination` 不动）
- Test: `test/liquid_nav_bar_test.dart`（新增外观渲染 smoke test）

**Interfaces:**
- Consumes: `SmoothLiquidNavigationBar`（Task 1）
- Produces: 全宽胶囊观感。`_bottomNavigationHeight` 常量 64（影响 `app.dart:23-32` 的 `_bottomNavigationClearance`、`app.dart:300-302` 预留高度、`app.dart:1248`/`1468` 各处内边距）。

- [ ] **Step 1: 写失败测试**

在 `test/liquid_nav_bar_test.dart` 的 `main()` 中新增：

```dart
  testWidgets('bar spans full width with capsule page geometry', (tester) async {
    await tester.pumpWidget(harness(onChanged: (_) {}));
    await tester.pump();

    final bar = tester.getRect(find.byType(SmoothLiquidNavigationBar));
    expect(bar.width, 400); // 等于传入 width —— 全宽胶囊而非收窄漂浮条
    expect(bar.height, 64);

    final lens = find.byType(LiquidGlassLens);
    expect(lens, findsWidgets);
    expect(tester.takeException(), isNull);
  });
```

- [ ] **Step 2: 运行基线测试**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: 该 smoke test **即刻通过**——harness 已按目标几何（400×64）构造，它验证的是测试基建本身（能 pump 全宽胶囊、透镜可渲染、无异常），作为后续任务保持的契约，而非驱动本次改动的红测试。

- [ ] **Step 3: 改 `_bottomNavigationHeight`**

`lib/src/app.dart:20`：

```dart
const double _bottomNavigationHeight = 64;
```

- [ ] **Step 4: 更新 `_buildLiquidNavigationBar` 几何与样式**

替换 `app.dart:311-396` 的 `_buildLiquidNavigationBar` 方法体（保留 `downloadLabel` 计算与 `items` 列表不变）：

```dart
  static Color _accentColor(bool dark) =>
      dark ? const Color(0xFF0091FF) : const Color(0xFF0088FF);

  Widget _buildLiquidNavigationBar(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomMargin = bottomInset < _minimumBottomNavigationMargin
        ? _minimumBottomNavigationMargin - bottomInset
        : 0.0;
    final downloadLabel = _taskCount > 0 ? '下载 $_taskCount' : '下载';
    final accent = _accentColor(dark);

    final barStyle = LiquidGlassStyle(
      shape: LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 28,
        borderWidth: 0.8,
        borderColor: Colors.white.withValues(alpha: dark ? 0.12 : 0.30),
      ),
      appearance: LiquidGlassAppearance(
        color: dark ? const Color(0x66121212) : const Color(0x66FAFAFA),
        saturation: 1.04,
        blur: const LiquidGlassBlur(sigmaX: 8, sigmaY: 8),
      ),
      refraction: const LiquidGlassRefraction(
        distortion: 0.06,
        distortionWidth: 20,
        magnification: 1.05,
        chromaticAberration: 0.0012,
      ),
    );
    final pillStyle = LiquidGlassStyle(
      shape: LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 28,
        borderWidth: 1.2,
        borderColor: Colors.white.withValues(alpha: dark ? 0.40 : 0.70),
      ),
      appearance: LiquidGlassAppearance(
        color: accent.withValues(alpha: 0.3),
        blur: const LiquidGlassBlur(sigmaX: 1.5, sigmaY: 1.5),
      ),
      refraction: const LiquidGlassRefraction(
        distortion: 0.08,
        distortionWidth: 20,
        magnification: 1.15,
        chromaticAberration: 0.0025,
      ),
    );

    return SmoothLiquidNavigationBar(
      width: MediaQuery.sizeOf(context).width,
      height: _bottomNavigationHeight,
      bottomMargin: bottomMargin,
      itemPadding: 4,
      selectedIndex: _selectedIndex,
      onChanged: _selectDestination,
      reduceMotion: reduceMotion,
      items: [
        const LiquidGlassTabBarItem(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home_rounded,
          label: '首页',
        ),
        LiquidGlassTabBarItem(
          icon: Icons.download_outlined,
          selectedIcon: Icons.download_rounded,
          label: downloadLabel,
        ),
        const LiquidGlassTabBarItem(
          icon: Icons.dns_outlined,
          selectedIcon: Icons.dns_rounded,
          label: '服务器',
        ),
        const LiquidGlassTabBarItem(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings_rounded,
          label: '设置',
        ),
      ],
      itemStyle: LiquidGlassNavItemStyle(
        selectedColor: accent,
        unselectedColor: colors.onSurfaceVariant,
        iconSize: 23,
        labelFontSize: 11,
        iconLabelGap: 3,
        selectedFontWeight: FontWeight.w700,
      ),
      barStyle: barStyle,
      pillStyle: pillStyle,
    );
  }
```

注意：`bottomMargin` 计算复用 `_bottomNavigationClearance` 的取整逻辑（`_minimumBottomNavigationMargin`），与 `app.dart:23-32` 一致。

- [ ] **Step 5: 运行测试**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: PASS（2 tests，含 Step 1 的 smoke test）。

- [ ] **Step 6: 静态检查**

Run: `flutter analyze`
Expected: No issues found.

- [ ] **Step 7: HomeScreen 回归**

Run: `flutter test test/server_tab_test.dart test/share_trigger_test.dart`
Expected: PASS（全宽 64 底栏下 `find.text('首页'/'服务器'/'设置')` 仍可点击切换）。

- [ ] **Step 8: Commit**

```bash
git add lib/src/app.dart test/liquid_nav_bar_test.dart
git commit -m "feat: adopt full-width AndroidLiquidGlass capsule geometry"
```

---

### Task 3: Pill 按压缩放与阴影/内光晕

**Files:**
- Modify: `lib/src/app.dart`（`_SmoothLiquidNavigationBarState`：`TickerProviderStateMixin`、`_press` 控制器、Pill 层移除 `IgnorePointer`、包 `GestureDetector` + `Transform.scale` + 阴影/内光晕）
- Test: `test/liquid_nav_bar_test.dart`

**Interfaces:**
- Consumes: `_position`（沿用现有 `AnimationController.unbounded` 与 `_spring`）、`widget.pillStyle`。
- Produces: `_press`（`AnimationController`，0..1）；Pill 层 `GestureDetector` 暴露 `onHorizontalDragStart`/`onHorizontalDragUpdate`/`onHorizontalDragEnd`/`onHorizontalDragCancel`（Task 4 填充拖动逻辑）；按压缩放 `scale = 1 + 0.39 * _press.value`。

- [ ] **Step 1: 写失败测试**

在 `test/liquid_nav_bar_test.dart` 中新增：

```dart
  testWidgets('pill scales up while pressed and returns to rest', (tester) async {
    await tester.pumpWidget(harness(onChanged: (_) {}));

    Offset pillCenter() {
      // 400 宽 / 4 格，itemPadding 4：cellWidth = (400-8)/4 = 98，
      // 底栏 Y = 600-64 = 536。第 0 格中心。
      return const Offset(4 + 49, 536 + 32);
    }

    expect(_scaledPills(tester), isEmpty);

    final gesture = await tester.startGesture(pillCenter());
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scaledPills(tester), isNotEmpty, reason: 'press should scale the pill');

    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_scaledPills(tester), isEmpty, reason: 'pill returns to rest after release');
    expect(tester.takeException(), isNull);
  });
```

并在文件顶部（`main` 外）添加辅助函数：

```dart
List<Transform> _scaledPills(WidgetTester tester) => tester
    .widgetList<Transform>(
      find.byWidgetPredicate(
        (w) => w is Transform && w.transform.getMaxScaleOnAxis() > 1.01,
      ),
    )
    .toList();
```

- [ ] **Step 2: 运行验证失败**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: FAIL — `press should scale the pill`（当前 Pill 是 `IgnorePointer` 静态层，无按压缩放）。

- [ ] **Step 3: 实现按压缩放**

在 `_SmoothLiquidNavigationBarState` 中：

将 `with SingleTickerProviderStateMixin` 改为 `with TickerProviderStateMixin`，并在 `_position` 后新增：

```dart
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );
```

`dispose()` 增加 `_press.dispose();`。

将 Pill 层（`app.dart:497-533` 的 `AnimatedBuilder` builder 返回）替换为：

```dart
            AnimatedBuilder(
              animation: Listenable.merge([_position, _press]),
              builder: (context, _) {
                final cellWidth =
                    (widget.width - widget.itemPadding * 2) /
                    widget.items.length;
                final maxIndex = (widget.items.length - 1).toDouble();
                final press = widget.reduceMotion ? 0.0 : _press.value;
                final scale = 1 + 0.39 * press;
                final pillWidth = cellWidth;
                final pillHeight =
                    widget.height - widget.itemPadding * 2;
                final position = _position.value
                    .clamp(-0.06, maxIndex + 0.06)
                    .toDouble();
                final left = widget.itemPadding + position * cellWidth;
                final top = (widget.height - pillHeight) / 2;

                return Positioned(
                  left: left,
                  top: top,
                  width: pillWidth,
                  height: pillHeight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) {
                      if (widget.reduceMotion) return;
                      _press.animateTo(1);
                    },
                    onHorizontalDragEnd: widget.reduceMotion
                        ? null
                        : (_) => _press.animateBack(0),
                    onHorizontalDragCancel: widget.reduceMotion
                        ? null
                        : () => _press.animateBack(0),
                    child: Transform.scale(
                      scale: scale,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: 0.24 * press,
                              ),
                              blurRadius: 26,
                              offset: Offset(0, 10 * press),
                            ),
                          ],
                        ),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: LiquidGlassLens(style: widget.pillStyle),
                            ),
                            if (press > 0.01)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius:
                                          BorderRadius.circular(28),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.30 * press,
                                        ),
                                        width: 1.2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
```

代码说明：`_position.value` 为 Pill 中心所对的 Tab 序号（连续值）；`left = itemPadding + position * cellWidth` 使 Pill 恰好覆盖该单元格，符合 Android 原版 `translationX = value * tabWidth + panelOffset` 的映射。

- [ ] **Step 4: 运行验证通过**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: PASS（press 期间 `_scaledPills` 非空；release 后 `pumpAndSettle` 归零）。

- [ ] **Step 5: 静态检查**

Run: `flutter analyze`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add lib/src/app.dart test/liquid_nav_bar_test.dart
git commit -m "feat: add pressed-scale pill with shadow and inner rim"
```

---

### Task 4: 拖拽切换、整栏偏移回弹与 reduceMotion

**Files:**
- Modify: `lib/src/app.dart`（`_SmoothLiquidNavigationBarState`：`_panelOffset` 控制器、`_panelDrag` 累计、拖拽 Update/End 逻辑；`_selectSnap`；给底栏传入拖拽中的显示索引；整栏 `Transform.translate`）
- Test: `test/liquid_nav_bar_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `_press` 与 Pill GestureDetector 槽位、`_position`、`_spring`（`SpringDescription(mass:1, stiffness:240, damping:25)`）。
- Produces: `_panelOffset`（`AnimationController.unbounded`）+ 私有 `_cellWidth()`、`_dragDelta` 累计、`_endDrag()`。（无对外新接口。）

- [ ] **Step 1: 写失败测试**

在 `test/liquid_nav_bar_test.dart` 中新增：

```dart
  testWidgets('dragging the pill snaps to the nearest tab', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(harness(onChanged: taps.add));

    // 从第 0 格中心开始，横移 2 格（196px）
    final start = const Offset(4 + 49, 536 + 32);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(196, 0));
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(taps, [2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion disables drag selection but keeps taps', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      harness(onChanged: taps.add, reduceMotion: true),
    );

    final gesture = await tester.startGesture(const Offset(4 + 49, 536 + 32));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(196, 0));
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(taps, isEmpty, reason: 'drag must not select under reduceMotion');

    await tester.tap(find.text('D'));
    await tester.pump();

    expect(taps, [3]);
  });
```

- [ ] **Step 2: 运行验证失败**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: FAIL — 两个新测试均失败（无拖拽逻辑：`taps` 为空 / 拖拽不产生 `onChanged`）。

- [ ] **Step 3: 实现拖拽、栏位偏移与 reduceMotion**

在 `_SmoothLiquidNavigationBarState` 中：

新增字段（`_press` 之后）：

```dart
  late final AnimationController _panelOffset = AnimationController.unbounded(
    vsync: this,
  );
  double _panelDrag = 0;
  bool _dragging = false;
```

新增私有方法（替换 Task 3 的“占位”Update/End 槽位）：

```dart
  double _cellWidth() =>
      (widget.width - widget.itemPadding * 2) / widget.items.length;

  double _maxIndex() => (widget.items.length - 1).toDouble();

  void _onDragStart(DragStartDetails details) {
    if (widget.reduceMotion) return;
    _dragging = true;
    _press.animateTo(1);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (widget.reduceMotion || !_dragging) return;
    _position.stop();
    _position.value = (_position.value + details.delta.dx / _cellWidth())
        .clamp(-0.06, _maxIndex() + 0.06)
        .toDouble();
    _panelDrag += details.delta.dx;
    final raw = (_panelDrag / widget.width).clamp(-1.0, 1.0);
    _panelOffset.value = 4 * raw.sign * Curves.easeOut.transform(raw.abs());
  }

  void _onDragEnd(DragEndDetails details) {
    if (widget.reduceMotion || !_dragging) return;
    _dragging = false;
    _press.animateBack(0);
    final target = _position.value.round().clamp(0, widget.items.length - 1).toInt();
    _position.stop();
    _position.animateWith(
      SpringSimulation(_spring, _position.value, target.toDouble(), _position.velocity),
    );
    _panelOffset.stop();
    _panelOffset.animateWith(
      SpringSimulation(_spring, _panelOffset.value, 0, _panelOffset.velocity),
    );
    if (mounted && widget.selectedIndex != target) {
      widget.onChanged(target);
    }
    _panelDrag = 0;
  }

  void _onDragCancel() {
    if (widget.reduceMotion || !_dragging) return;
    _dragging = false;
    _press.animateBack(0);
    _panelOffset.animateWith(
      SpringSimulation(_spring, _panelOffset.value, 0, _panelOffset.velocity),
    );
    _panelDrag = 0;
  }
```

替换 Task 3 Pill 层的 GestureDetector 绑定为真实回调（`onHorizontalDragStart: _onDragStart`, `onHorizontalDragUpdate: _onDragUpdate`, `onHorizontalDragEnd: _onDragEnd`, `onHorizontalDragCancel: _onDragCancel`），并去掉 `widget.reduceMotion ? null :` 包装。

**整栏偏移：** 将 `build` 的最外层改为监听偏移的 AnimatedBuilder（包裹现有 `Padding`），并把 `Stack` 套进 `Transform.translate`：

```dart
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottomMargin),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _panelOffset,
          builder: (context, _) => Transform.translate(
            offset: Offset(_panelOffset.value, 0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: LiquidGlassBottomNavBar(
                    width: widget.width,
                    height: widget.height,
                    margin: EdgeInsets.zero,
                    itemPadding: widget.itemPadding,
                    selectedIndex: _displayIndex(),
                    onChanged: widget.onChanged,
                    items: widget.items,
                    itemStyle: widget.itemStyle,
                    pillStyle: const LiquidGlassNavPillStyle(
                      mode: LiquidGlassPillMode.none,
                      show: false,
                    ),
                    style: widget.barStyle,
                  ),
                ),
                // ...Task 3 的 Pill AnimatedBuilder 保持位置不变...
              ],
            ),
          ),
        ),
      ),
    );
  }
```

新增 `_displayIndex`（拖拽中图标随 Pill 位置着色）：

```dart
  int _displayIndex() {
    if (widget.reduceMotion) return widget.selectedIndex;
    return _position.value.round().clamp(0, widget.items.length - 1).toInt();
  }
```

更新 `didUpdateWidget`（`app.dart:444-462`）以在 reduceMotion 切换时归零偏移与按压：

```dart
  @override
  void didUpdateWidget(covariant SmoothLiquidNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduceMotionNow = widget.reduceMotion;
    if (reduceMotionNow && !oldWidget.reduceMotion) {
      _position
        ..stop()
        ..value = widget.selectedIndex.toDouble();
      _panelOffset
        ..stop()
        ..value = 0;
      _panelDrag = 0;
      _dragging = false;
      _press.value = 0;
      return;
    }
    if (widget.selectedIndex == oldWidget.selectedIndex) return;
    final target = widget.selectedIndex.toDouble();
    if (reduceMotionNow) {
      _position.value = target;
      return;
    }
    _position.animateWith(
      SpringSimulation(_spring, _position.value, target, _position.velocity),
    );
  }
```

`dispose()` 追加 `_panelOffset.dispose();`。

- [ ] **Step 4: 运行验证通过**

Run: `flutter test test/liquid_nav_bar_test.dart`
Expected: PASS（drag→[2]、reduceMotion 不看拖拽但 tap→[3]、plus Task1-3 原有用例）。

- [ ] **Step 5: 静态检查**

Run: `flutter analyze`
Expected: No issues found.

- [ ] **Step 6: HomeScreen 回归 + 全量轻量测试**

Run: `flutter test test/server_tab_test.dart test/share_trigger_test.dart`
Expected: PASS。
（如时间充裕再跑 `flutter test` 全量；至少保证上述回归通过。）

- [ ] **Step 7: 手动观感检查（模拟器）**

在模拟器/真机运行 App（浅色+深色各一次），核对：
- 整条全宽胶囊、Pill 位于选中 Tab、内呈放大 + accent 着色
- 按住拖拽：Pill 跟随手指、整栏反向位移、松手弹簧吸附相邻 Tab
- 点击任意 Tab 仍可切换；下载角标显示（`下载 N`）
- 系统开启“减少动态效果”后：仅点击切换、无拖拽/缩放/回弹
将发现的问题回写本计划或直接作为后续 commit 修正（记录在 Git message 中）。

- [ ] **Step 8: Commit**

```bash
git add lib/src/app.dart test/liquid_nav_bar_test.dart
git commit -m "feat: add draggable pill, bar offset rebound, reduceMotion gating"
```

---

## Self-Review 记录

- **Spec 覆盖**：布局/尺寸=Task 2；底栏玻璃参数=Task 2；Pill 参数=Task 2；按压缩放+阴影/内光晕=Task 3；拖拽+panelOffset 回弹=Task 4；点击切换=Task 1；reduceMotion=Task 4；accent 蓝=Task 2；`_bottomNavigationHeight` 常量传导=Task 2 Step 3。（spec 的“内容着色”由 `itemStyle.selectedColor`=accent + Pill appearance tint 实现，Task 2。）
- **No Placeholders**：所有 Step 均含完整代码/命令；Task 3 中“占位”为去除说明，最终实现无残留占位代码。
- **类型一致性**：`SmoothLiquidNavigationBar` 构造参数在 Task 1 定型并被 Task 2 harness、Task 3/4 State 沿用；`_displayIndex`、`_onDragStart/Update/End/Cancel`、`_cellWidth`、`_maxIndex` 在 Task 4 首次定义并被调用，命名单一。