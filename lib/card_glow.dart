import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CardGlowScope extends StatefulWidget {
  const CardGlowScope({super.key, required this.child});

  final Widget child;

  @override
  State<CardGlowScope> createState() => _CardGlowScopeState();
}

class _CardGlowScopeState extends State<CardGlowScope>
    with WidgetsBindingObserver {
  static const _channel = EventChannel('app.toolcollection/gravity');
  final _tilt = ValueNotifier(Offset.zero);
  StreamSubscription<Object?>? _subscription;
  bool _allowed = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed =
        !MediaQuery.disableAnimationsOf(context) &&
        !kIsWeb &&
        Platform.isAndroid;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    if (_allowed && _foreground) {
      _subscription ??= _channel.receiveBroadcastStream().listen((event) {
        if (event is! List<double> || event.length != 2) return;
        final target = Offset(
          (-event[0] / 6).clamp(-1.0, 1.0),
          (event[1] / 9.8).clamp(-1.0, 1.0),
        );
        final next = Offset.lerp(_tilt.value, target, .16)!;
        if ((next - _tilt.value).distance >= .008) _tilt.value = next;
      }, onError: (Object _) {});
    } else {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _tilt.value = Offset.zero;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _tilt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _CardLight(tilt: _tilt, child: widget.child);
}

class _CardLight extends InheritedWidget {
  const _CardLight({required this.tilt, required super.child});

  final ValueListenable<Offset> tilt;

  @override
  bool updateShouldNotify(_CardLight oldWidget) => tilt != oldWidget.tilt;
}

class CardGlow extends StatefulWidget {
  const CardGlow({super.key, required this.child});

  final Widget child;

  @override
  State<CardGlow> createState() => _CardGlowState();
}

class _CardGlowState extends State<CardGlow>
    with SingleTickerProviderStateMixin {
  final _touch = ValueNotifier(Offset.zero);
  late final _shine = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 130),
    reverseDuration: const Duration(milliseconds: 240),
  );

  @override
  void dispose() {
    _shine.dispose();
    _touch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tilt = context.dependOnInheritedWidgetOfExactType<_CardLight>()?.tilt;
    final motion = !MediaQuery.disableAnimationsOf(context);
    final colors = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: motion
          ? (event) {
              _touch.value = event.localPosition;
              _shine.forward();
            }
          : null,
      onPointerMove: motion
          ? (event) => _touch.value = event.localPosition
          : null,
      onPointerUp: motion ? (_) => _shine.reverse() : null,
      onPointerCancel: motion ? (_) => _shine.reverse() : null,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _GlowPainter(
                    colors,
                    motion ? tilt : null,
                    _touch,
                    motion ? _shine : null,
                  ),
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.colors, this.tilt, this.touch, this.shine)
    : super(repaint: Listenable.merge([tilt, touch, shine]));

  final ColorScheme colors;
  final ValueListenable<Offset>? tilt;
  final ValueListenable<Offset> touch;
  final Animation<double>? shine;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final direction = tilt?.value ?? Offset.zero;
    final center = Offset(
      size.width * (.72 + direction.dx * .44),
      size.height * (.09 + direction.dy * .46),
    );
    final restingOpacity = colors.brightness == Brightness.dark ? .24 : .12;
    _drawGlow(canvas, size, center, restingOpacity);
    final touchOpacity = (shine?.value ?? 0) * .14;
    if (touchOpacity > 0) _drawGlow(canvas, size, touch.value, touchOpacity);
  }

  void _drawGlow(Canvas canvas, Size size, Offset center, double opacity) {
    final tint = colors.primary;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          math.max(size.width * .59, size.height * .75),
          [
            tint.withValues(alpha: opacity),
            tint.withValues(alpha: opacity * .42),
            tint.withValues(alpha: 0),
          ],
          const [0, .48, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      colors != oldDelegate.colors ||
      tilt != oldDelegate.tilt ||
      touch != oldDelegate.touch ||
      shine != oldDelegate.shine;
}
