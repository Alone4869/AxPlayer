# 导航栏复刻 AndroidLiquidGlass LiquidBottomTabs 设计文档

日期：2026-08-16
状态：已确认

## 背景与目标

当前 App 的底部导航栏是自研的 `_SmoothLiquidNavigationBar`（`lib/src/app.dart:311`），
基于 `liquid_glass_easy` 包的 `LiquidGlassBottomNavBar` + 覆盖在上方、随速度拉伸的
`LiquidGlassLens` 胶囊 Pill。视觉风格偏向自定制的"漂浮玻璃胶囊"。

本次目标：将导航栏**完整复刻**为 Compose 库 AndroidLiquidGlass 官方示例组件
`LiquidBottomTabs` 的形态与交互——整条胶囊玻璃底栏，可横向拖拽的胶囊 Pill，
带按压缩放、放大镜折射、accent 着色与栏位偏移回弹。

实现方案已与用户确认：**方案 A——基于 `LiquidGlassBottomNavBar` 复用其底栏/内容/点击
语义，重写 Pill 覆盖层为可拖拽、可缩放的自研层**。

## 视觉设计（对齐 AndroidLiquidGlass LiquidBottomTabs）

### 布局与尺寸

- 底栏：整条胶囊，高 **64**，全宽（左右各 4 内边距），圆角 28。
- Pill：高 **56**、圆角 28，宽 = 单个 Tab 格宽（`(barWidth - 8) / 4`），
  定位 `left = itemPadding(4) + index × cellWidth`，垂直居中。
- 保留 4 个 Tab、图标 + 标签（`itemStyle` 沿用现有：icon 23、label 11、gap 3）。
- 下载 Tab 的角标（`下载 N`）不变。

### 底栏玻璃参数

| 属性 | 浅色 | 深色 |
| --- | --- | --- |
| 容器色 | `#FAFAFA` @ 0.4 | `#121212` @ 0.4 |
| 饱和度（vibrancy） | 1.04 | 1.04 |
| blur（σ） | 8 | 8 |
| 折射 distortion | 0.06 | 0.06 |
| 折射 magnification | 1.05 | 1.05 |
| 色差 | 0.0012 | 0.0012 |
| 圆角 / 边框 | 28 / 保留原细边框观感 | 同左 |

### Pill 玻璃参数（LiquidGlassLens）

- 形状：胶囊（roundedRectangle 圆角 28），弱亮边。
- appearance color：accent 着色叠加 `#0088FF`（浅）/ `#0091FF`（深）@ ~0.3。
- 折射：distortion 0.08、distortionWidth ~20、magnification 1.15、色差 0.0025。
- **按压缩放**：缩放至 ~1.39×（Android 原版 56 → 78dp 比例），
  叠加等价"阴影 / 内阴影 / 内光晕"视觉层。

### 内容着色

- 选中 Tab 内容为 accent 色（Pill 内呈现放大 + accent 着色的内容）。
- 未选中 Tab 内容为 `onSurfaceVariant`。

## 交互（完整复刻）

1. **横向拖拽 Pill**：按住 Pill 横向拖动可滑动切换 Tab，拖动期间
   内部使用阻尼位移动画（含拖拽速度对位置的影响）。
2. **栏位偏移（panelOffset）**：拖动时整个底栏往拖拽反方向偏移
   最多 ±4dp，偏移量按 `EaseOut(fraction)` 衰减；松手后弹簧回弹归零。
3. **松手吸附**：松手时 Pill 弹簧吸附到最近的 Tab 并触发切换。
4. **点击切换**：点击任意 Tab 仍可切换（沿用 `LiquidGlassBottomNavBar` 的 tap 语义）。
5. **reduceMotion**：检测到系统"减少动态效果"时禁用弹性回弹 / 拖拽缩放动画，
   位置直接跳转、Pill 无按压缩放，交互降级为纯点击。

## 代码结构

- `_buildLiquidNavigationBar` 中底栏宽度由 `MediaQuery.sizeOf(context).width - 28`
  改为**全宽** `MediaQuery.sizeOf(context).width`（去掉左右漂浮余量），
  `itemPadding` 改为 4（Android 原版 4dp 内边距）。
- 重写 `_SmoothLiquidNavigationBar`（`lib/src/app.dart:399-539`）：
  - 由 `SingleTickerProviderStateMixin` 改为 `TickerProviderStateMixin`，
    管理三个动画分量：
    - `_position`：Pill 位置（含弹簧动画），沿用现有 SpringSimulation。
    - `_panelOffset`：整个底栏的水平偏移（拖动累计，回弹归零）。
    - `_pressing`：按压缩放进度（拖拽开始 0→1 / 结束→0）。
  - 底栏层复用作 `LiquidGlassBottomNavBar`（`pillStyle.mode: none, show: false`
    保持隐藏内置 Pill），供其底栏玻璃、内容 Row 与点击语义。
  - Pill 层变为可拖拽的 `LiquidGlassLens`：
    - 移除现有 `IgnorePointer`（一直以来覆盖层不响应触摸）。
    - 包一层 `GestureDetector` 处理 `onHorizontalDragStart/Update/End`：
      - Start：记录起点位置、置 `_pressing = 1`。
      - Update：`_position += delta.dx / cellWidth`（clamp [−0.06, maxIndex+0.06]），
        `_panelOffset += delta.dx`（衰减）。
      - End：`_pressing → 0`，`_position` 弹簧吸附到最近整数 Tab，
        `_panelOffset` 弹簧归零。
    - Pill 外包 `Transform.scale(scale: _pressing.then(≈1.39))` + 阴影层；
      Pill 下方叠加等价"内光晕 / 内阴影"视觉层。
  - 拖动时整条底栏以 `Transform.translate(dx: _panelOffset)` 偏移。
- 样式参数调整集中在 `_buildLiquidNavigationBar`（`app.dart:320-353`）：
  底栏 `barStyle` 与 Pill `pillStyle` 按上表取值；accent 蓝
  `#0088FF`（浅）/ `#0091FF`（深）取代原 `colors.primary` 的选中着色。
- 改动范围集中在 `lib/src/app.dart`（`_buildLiquidNavigationBar` 与
  `_SmoothLiquidNavigationBar`／其 State）。

## 边界与降级

- 仅支持 4 个固定 Tab（不引入动态 Tab 数）。
- reduceMotion 为唯一降级路径；其余场景均完整复刻交互。
- 音频／视频播放页等全屏场景不在此设计范围内。

## 验证

- `flutter analyze` 无新增告警。
- 现有 widget 测试（`test/`，含 `_SmoothLiquidNavigationBar` 相关用例）通过。
- 模拟器／真机目测：拖拽滑动、松手吸附、按压缩放、栏位回弹、
  accent 着色与放大镜效果、深浅色外观。