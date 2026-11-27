import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

Duration collectionMotion(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

BoxDecoration collectionPanel(ColorScheme colors) => BoxDecoration(
  borderRadius: BorderRadius.circular(28),
  border: Border.all(color: colors.outlineVariant),
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      colors.surfaceContainerLowest,
      colors.primaryContainer,
      Color.lerp(colors.primaryContainer, colors.secondaryContainer, .7)!,
    ],
    stops: const [0, .62, 1],
  ),
);

class CollectionMascot extends StatefulWidget {
  const CollectionMascot({
    super.key,
    required this.size,
    required this.onTap,
    required this.onMore,
    this.reaction,
  });

  final double size;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final ({int sequence, IconData icon})? reaction;

  @override
  State<CollectionMascot> createState() => _CollectionMascotState();
}

class _CollectionMascotState extends State<CollectionMascot>
    with TickerProviderStateMixin {
  late final _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4300),
  );
  late final _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  );
  late final _motion = Listenable.merge([_float, _hop]);

  @override
  void didUpdateWidget(covariant CollectionMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reaction != null &&
        widget.reaction != oldWidget.reaction &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      _hop.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _float.stop();
      _hop.stop();
    } else if (!_float.isAnimating) {
      _float.repeat();
    }
  }

  @override
  void dispose() {
    _float.dispose();
    _hop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rim = colors.brightness == Brightness.dark
        ? colors.outlineVariant
        : colors.surfaceContainerLowest;
    final size = widget.size;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: '和鲸鱼娘聊天',
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: () {
            if (!reduced) _hop.forward(from: 0);
            widget.onTap();
          },
          onLongPress: widget.onMore,
          onSecondaryTap: widget.onMore,
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: size * .88,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: rim.withValues(alpha: .9)),
                      gradient: RadialGradient(
                        colors: [
                          colors.surfaceContainerLowest,
                          colors.surfaceContainerLowest.withValues(alpha: .25),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: size * .12,
                  right: size * .07,
                  child: _floatingBubble(reduced, 14, rim, 0),
                ),
                Positioned(
                  bottom: size * .16,
                  left: 2,
                  child: _floatingBubble(reduced, 9, rim, 2.1),
                ),
                AnimatedBuilder(
                  animation: _motion,
                  child: Image.asset(
                    'assets/images/whale_mascot.png',
                    width: size,
                    height: size,
                    fit: BoxFit.contain,
                    excludeFromSemantics: true,
                  ),
                  builder: (context, child) {
                    if (reduced) return child!;
                    final wave = math.sin(_float.value * math.pi * 2);
                    final hop = _hop.isAnimating
                        ? math.sin(_hop.value * math.pi)
                        : 0.0;
                    return Transform.translate(
                      offset: Offset(0, wave * size * .022 - hop * size * .06),
                      child: Transform.rotate(angle: wave * .023, child: child),
                    );
                  },
                ),
                if (widget.reaction case (:final icon, sequence: _))
                  Positioned(
                    top: 6,
                    right: 4,
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _hop,
                        child: Icon(
                          icon,
                          size: size * .19,
                          color: colors.primary,
                        ),
                        builder: (context, child) {
                          if (reduced || !_hop.isAnimating) {
                            return const SizedBox.shrink();
                          }
                          return Opacity(
                            opacity: math
                                .sin(_hop.value * math.pi)
                                .clamp(0.0, 1.0),
                            child: Transform.translate(
                              offset: Offset(0, -size * .16 * _hop.value),
                              child: child,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _floatingBubble(bool reduced, double size, Color rim, double phase) =>
      AnimatedBuilder(
        animation: _float,
        child: _Bubble(size, rim),
        builder: (context, child) {
          if (reduced) return child!;
          final wave = math.sin(_float.value * math.pi * 2 + phase);
          return Transform.translate(
            offset: Offset(wave * 2, wave * -4),
            child: child,
          );
        },
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.size, this.rim);

  final double size;
  final Color rim;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: rim.withValues(alpha: .4),
      border: Border.all(color: rim),
    ),
  );
}

class CollectionDock extends StatelessWidget {
  const CollectionDock({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const corners = BorderRadius.all(Radius.circular(27));
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: corners,
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: .11),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: corners,
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest.withValues(alpha: .84),
                    borderRadius: corners,
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  padding: const EdgeInsets.all(5),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AnimatedAlign(
                          alignment: selected == 0
                              ? Alignment.centerLeft
                              : Alignment.centerRight,
                          duration: collectionMotion(context, 240),
                          curve: Curves.easeInOutCubicEmphasized,
                          child: FractionallySizedBox(
                            widthFactor: .5,
                            heightFactor: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    colors.primaryContainer,
                                    colors.secondaryContainer,
                                  ],
                                ),
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(22),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Material(
                        type: MaterialType.transparency,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _destination(
                              context,
                              0,
                              '工具收藏',
                              Icons.bookmarks_outlined,
                              Icons.bookmarks_rounded,
                            ),
                            _destination(
                              context,
                              1,
                              '提示词',
                              Icons.chat_bubble_outline_rounded,
                              Icons.chat_bubble_rounded,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _destination(
    BuildContext context,
    int index,
    String label,
    IconData outline,
    IconData filled,
  ) {
    final theme = Theme.of(context);
    final active = selected == index;
    final color = active
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        selected: active,
        button: true,
        child: InkWell(
          onTap: () => onSelect(index),
          borderRadius: const BorderRadius.all(Radius.circular(22)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(active ? filled : outline, size: 20, color: color),
                  const SizedBox(width: 7),
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: collectionMotion(context, 160),
                      style: theme.textTheme.labelLarge!.copyWith(
                        color: color,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      ),
                      child: Text(label, textAlign: TextAlign.center),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
