import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:axplayer/src/liquid_bottom_tabs.dart';

const _barStyle = LiquidGlassStyle();
const _pillStyle = LiquidGlassStyle();

List<LiquidGlassTabBarItem> _items() => const [
  LiquidGlassTabBarItem(icon: Icons.home_outlined, label: '首页'),
  LiquidGlassTabBarItem(icon: Icons.download_outlined, label: '下载'),
  LiquidGlassTabBarItem(icon: Icons.settings_outlined, label: '设置'),
];

Widget _host({
  required int selectedIndex,
  required ValueChanged<int> onChanged,
  bool reduceMotion = false,
}) {
  return MediaQuery(
    data: const MediaQueryData(
      size: Size(400, 800),
      padding: EdgeInsets.only(bottom: 20),
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: LiquidBottomTabs(
        body: const ColoredBox(color: Color(0xFF222222)),
        width: 380,
        height: 68,
        bottomMargin: 0,
        itemPadding: 5,
        selectedIndex: selectedIndex,
        onChanged: onChanged,
        reduceMotion: reduceMotion,
        items: _items(),
        itemStyle: const LiquidGlassNavItemStyle(
          selectedColor: Colors.white,
          unselectedColor: Colors.white70,
        ),
        barStyle: _barStyle,
        pillStyle: _pillStyle,
      ),
    ),
  );
}

void main() {
  testWidgets('renders bar and pill over the body', (tester) async {
    await tester.pumpWidget(_host(selectedIndex: 0, onChanged: (_) {}));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('首页'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.byType(LiquidBottomTabs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tab reports the tapped index', (tester) async {
    final calls = <int>[];
    await tester.pumpWidget(_host(selectedIndex: 0, onChanged: calls.add));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('下载'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, [1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external index change moves the pill', (tester) async {
    await tester.pumpWidget(_host(selectedIndex: 0, onChanged: (_) {}));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(_host(selectedIndex: 2, onChanged: (_) {}));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion snaps without ticking springs', (tester) async {
    final calls = <int>[];
    await tester.pumpWidget(
      _host(selectedIndex: 0, onChanged: calls.add, reduceMotion: true),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('设置'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, [2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging the pill reports a rounded index on release', (
    tester,
  ) async {
    final calls = <int>[];
    await tester.pumpWidget(_host(selectedIndex: 0, onChanged: calls.add));
    await tester.pump(const Duration(milliseconds: 100));

    final tabWidth = (380 - 2 * 5) / 3;
    final start = tester.getCenter(find.byKey(const Key('liquid_pill')));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(Offset(tabWidth * 0.1, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    expect(calls, [1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pill center aligns with the tapped tab cell center after switching '
    'index',
    (tester) async {
      await tester.pumpWidget(_host(selectedIndex: 2, onChanged: (_) {}));
      // Let the pill spring settle onto index 2.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 800));

      final pillX = tester.getCenter(find.byKey(const Key('liquid_pill'))).dx;
      final tabX = tester.getCenter(find.text('设置')).dx;

      expect((pillX - tabX).abs(), lessThan(1.0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pill drag target follows the pill when it has moved', (
    tester,
  ) async {
    final calls = <int>[];
    await tester.pumpWidget(_host(selectedIndex: 0, onChanged: calls.add));
    await tester.pump(const Duration(milliseconds: 100));

    // Move the pill to index 1 via an external change.
    await tester.pumpWidget(_host(selectedIndex: 1, onChanged: calls.add));
    await tester.pump(const Duration(milliseconds: 800));

    // Grab the pill where it now visually sits (index 1), not at index 0.
    final start = tester.getCenter(find.byKey(const Key('liquid_pill')));
    final tabWidth = (380 - 2 * 5) / 3;
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(Offset(tabWidth * 0.1, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    // Dragging the already-selected pill one cell onward reports tab 2.
    expect(calls, [2]);
    expect(tester.takeException(), isNull);
  });
}
