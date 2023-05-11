import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoDynamicColor;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

// The over-scroll distance that moves the indicator to its maximum
// displacement, as a percentage of the scrollable's container extent.
const double _kDragContainerExtentPercentage = 0.25;

// How much the scroll's drag gesture can overshoot the RefreshIndicator's
// displacement; max displacement = _kDragSizeFactorLimit * displacement.
const double _kDragSizeFactorLimit = 1.5;

// When the scroll ends, the duration of the refresh indicator's animation
// to the RefreshIndicator's displacement.
const Duration _kIndicatorSnapDuration = Duration(milliseconds: 150);

// The duration of the ScaleTransition that starts when the refresh action
// has completed.
const Duration _kIndicatorScaleDuration = Duration(milliseconds: 200);

/// The signature for a function that's called when the user has dragged a
/// [PullToRefreshNotification] far enough to demonstrate that they want the app to
/// refresh. The returned [Future] must complete when the refresh operation is
/// finished.
///
/// Used by [PullToRefreshNotification.onRefresh].
typedef RefreshCallback = Future<bool> Function();

// The state machine moves through these modes only when the scrollable
// identified by scrollableKey has been scrolled to its min or max limit.
enum PullToRefreshIndicatorMode {
  drag, // Pointer is down.
  armed, // Dragged far enough that an up event will run the onRefresh callback.
  snap, // Animating to the indicator's final "displacement".
  refresh, // Running the refresh callback.
  done, // Animating the indicator's fade-out after refreshing.
  canceled, // Animating the indicator's fade-out after not arming.
  error, //refresh failed
}

class PullToRefreshNotification extends StatefulWidget {
  /// Creates a refresh indicator.
  ///
  /// The [onRefresh], [child], and [notificationPredicate] arguments must be
  /// non-null. The default
  /// [displacement] is 40.0 logical pixels.
  const PullToRefreshNotification({
    Key? key,
    required this.child,
    required this.onRefresh,
    this.color,
    this.pullBackOnRefresh = false,
    this.maxDragOffset,
    this.notificationPredicate = defaultNotificationPredicate,
    this.armedDragUpCancel = true,
    this.pullBackCurve = Curves.linear,
    this.reverse = false,
    this.pullBackOnError = false,
    this.pullBackDuration = const Duration(milliseconds: 400),
    this.refreshOffset,
    this.reachToRefreshOffset,
  }) : super(key: key);

  //Dragged far enough that an up event will run the onRefresh callback.
  //then user drag up,whether should cancel refresh
  final bool armedDragUpCancel;

  /// The widget below this widget in the tree.
  ///
  /// The refresh indicator will be stacked on top of this child. The indicator
  /// will appear when child's Scrollable descendant is over-scrolled.
  ///
  /// Typically a [ListView] or [CustomScrollView].
  final Widget child;

  /// A function that's called when the user has dragged the refresh indicator
  /// far enough to demonstrate that they want the app to refresh. The returned
  /// [Future] must complete when the refresh operation is finished.
  final RefreshCallback onRefresh;

  /// The progress indicator's foreground color. The current theme's
  /// /// [ThemeData.accentColor] by default. only for android
  final Color? color;

  /// Whether start pull back animation when refresh.
  final bool pullBackOnRefresh;

  /// The max drag offset
  final double? maxDragOffset;

  /// The curve to use for the pullback animation
  final Curve pullBackCurve;

  //use in case much ScrollNotification from child
  final bool Function(ScrollNotification notification) notificationPredicate;

  /// The [reverse] should be the same as the list in [PullToRefreshNotification].
  ///
  /// Whether the scroll view scrolls in the reading direction.
  ///
  /// For example, if the reading direction is left-to-right and
  /// [scrollDirection] is [Axis.horizontal], then the scroll view scrolls from
  /// left to right when [reverse] is false and from right to left when
  /// [reverse] is true.
  ///
  /// Similarly, if [scrollDirection] is [Axis.vertical], then the scroll view
  /// scrolls from top to bottom when [reverse] is false and from bottom to top
  /// when [reverse] is true.
  ///
  /// Defaults to false.
  final bool reverse;

  //The duration to use for the pullback animation
  final Duration pullBackDuration;

  /// Whether start pull back animation when refresh failed.
  final bool pullBackOnError;

  /// The offset to keep when it is refreshing
  final double? refreshOffset;

  /// The offset to be dragged far enough that an up event will run the onRefresh callback.
  final double? reachToRefreshOffset;

  @override
  PullToRefreshNotificationState createState() =>
      PullToRefreshNotificationState();
}

/// Contains the state for a [PullToRefreshNotification]. This class can be used to
/// programmatically show the refresh indicator, see the [show] method.
class PullToRefreshNotificationState extends State<PullToRefreshNotification>
    with TickerProviderStateMixin<PullToRefreshNotification> {
  final StreamController<PullToRefreshScrollNotificationInfo> _onNoticed =
      StreamController<PullToRefreshScrollNotificationInfo>.broadcast();
  Stream<PullToRefreshScrollNotificationInfo> get onNoticed =>
      _onNoticed.stream;

  late AnimationController _positionController;
  late AnimationController _scaleController;
  late Animation<double> _scaleFactor;
  late Animation<double> _value;
  Animation<Color?>? _valueColor;

  late AnimationController _pullBackController;
  Animation<double>? _pullBackFactor;

  PullToRefreshIndicatorMode? _mode;
  PullToRefreshIndicatorMode? get _refreshIndicatorMode => _mode;
  set _refreshIndicatorMode(PullToRefreshIndicatorMode? value) {
    if (_mode != value) {
      _mode = value;
      _onInnerNoticed();
    }
  }

  Future<void>? _pendingRefreshFuture;
  bool? _isIndicatorAtTop;
  double? _dragOffset;
  double? get _notificationDragOffset => _dragOffset;
  set _notificationDragOffset(double? value) {
    if (value != null) {
      value = math.max(
          0.0, math.min(value, widget.maxDragOffset ?? double.maxFinite));
    }
    if (_dragOffset != value) {
      _dragOffset = value;
      _onInnerNoticed();
    }
  }

  static final Animatable<double> _threeQuarterTween =
      Tween<double>(begin: 0.0, end: 0.75);
  static final Animatable<double> _oneToZeroTween =
      Tween<double>(begin: 1.0, end: 0.0);

  @override
  void initState() {
    super.initState();
    _positionController = AnimationController(vsync: this);

    _value = _positionController.drive(
        _threeQuarterTween); // The "value" of the circular progress indicator during a drag.

    _scaleController = AnimationController(vsync: this);
    _scaleFactor = _scaleController.drive(_oneToZeroTween);

    _pullBackController = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    final ThemeData theme = Theme.of(context);
    _valueColor = _positionController.drive(
      ColorTween(
              begin: (widget.color ?? theme.colorScheme.secondary).withOpacity(0.0),
              end: (widget.color ?? theme.colorScheme.secondary).withOpacity(1.0))
          .chain(CurveTween(
              curve: const Interval(0.0, 1.0 / _kDragSizeFactorLimit))),
    );
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    _positionController.dispose();
    _scaleController.dispose();
    _pullBackController.dispose();
    _onNoticed.close();
    super.dispose();
  }

  double maxContainerExtent = 0.0;
  bool _handleScrollNotification(ScrollNotification notification) {
    final bool reuslt = _innerhandleScrollNotification(notification);
    //_onInnerNoticed();
    return reuslt;
  }

  bool _innerhandleScrollNotification(ScrollNotification notification) {
    if (!widget.notificationPredicate(notification)) {
      return false;
    }
    if (notification.depth != 0) {
      maxContainerExtent =
          math.max(notification.metrics.viewportDimension, maxContainerExtent);
    }
    if (notification is ScrollStartNotification &&
        (widget.reverse
            ? notification.metrics.extentAfter == 0.0
            : notification.metrics.extentBefore == 0.0) &&
        _refreshIndicatorMode == null &&
        _start(notification.metrics.axisDirection)) {
      //setState(() {
      _mode = PullToRefreshIndicatorMode.drag;
      //});
      return false;
    }
    bool? indicatorAtTopNow;
    switch (notification.metrics.axisDirection) {
      case AxisDirection.down:
        indicatorAtTopNow = !widget.reverse;
        break;
      case AxisDirection.up:
        indicatorAtTopNow = widget.reverse;
        break;
      case AxisDirection.left:
      case AxisDirection.right:
        indicatorAtTopNow = null;
        break;
    }
    if (indicatorAtTopNow != _isIndicatorAtTop) {
      if (_refreshIndicatorMode == PullToRefreshIndicatorMode.drag ||
          _refreshIndicatorMode == PullToRefreshIndicatorMode.armed)
        dismiss(PullToRefreshIndicatorMode.canceled);
    } else if (notification is ScrollUpdateNotification) {
      if (_refreshIndicatorMode == PullToRefreshIndicatorMode.drag ||
          _refreshIndicatorMode == PullToRefreshIndicatorMode.armed) {
        if (!widget.reverse &&
            notification.metrics.extentBefore > 0.0 &&
            notification.metrics.pixels >= 0) {
          if (_refreshIndicatorMode == PullToRefreshIndicatorMode.armed &&
              !widget.armedDragUpCancel) {
            _show();
          } else {
            dismiss(PullToRefreshIndicatorMode.canceled);
          }
        } else {
          if (widget.reverse) {
            _notificationDragOffset =
                (_notificationDragOffset ?? 0) + notification.scrollDelta!;
          } else {
            _notificationDragOffset =
                (_notificationDragOffset ?? 0) - notification.scrollDelta!;
          }

          _checkDragOffset(maxContainerExtent);
        }
      }
      if (_refreshIndicatorMode == PullToRefreshIndicatorMode.armed &&
          notification.dragDetails == null) {
        // On iOS start the refresh when the Scrollable bounces back from the
        // overscroll (ScrollNotification indicating this don't have dragDetails
        // because the scroll activity is not directly triggered by a drag).
        _show();
      }
    } else if (notification is OverscrollNotification) {
      if (_refreshIndicatorMode == PullToRefreshIndicatorMode.drag ||
          _refreshIndicatorMode == PullToRefreshIndicatorMode.armed) {
        if (widget.reverse) {
          _notificationDragOffset =
              (_notificationDragOffset ?? 0) + notification.overscroll / 2.0;
        } else {
          _notificationDragOffset =
              (_notificationDragOffset ?? 0) - notification.overscroll / 2.0;
        }
        _checkDragOffset(maxContainerExtent);
      }
    } else if (notification is ScrollEndNotification) {
      switch (_refreshIndicatorMode) {
        case PullToRefreshIndicatorMode.armed:
          _show();
          break;
        case PullToRefreshIndicatorMode.drag:
          dismiss(PullToRefreshIndicatorMode.canceled);
          break;
        default:
          // do nothing
          break;
      }
    }
    //_onInnerNoticed();
    return false;
  }

  bool _handleGlowNotification(OverscrollIndicatorNotification notification) {
    if (notification.depth != 0 || !notification.leading) {
      return false;
    }
    if (_refreshIndicatorMode == PullToRefreshIndicatorMode.drag) {
      notification.disallowIndicator();
      return true;
    }
    return false;
  }

  bool _start(AxisDirection direction) {
    assert(_refreshIndicatorMode == null);
    assert(_isIndicatorAtTop == null);
    assert(_notificationDragOffset == null);
    switch (direction) {
      case AxisDirection.down:
        _isIndicatorAtTop = !widget.reverse;
        break;
      case AxisDirection.up:
        _isIndicatorAtTop = widget.reverse;
        break;
      case AxisDirection.left:
      case AxisDirection.right:
        _isIndicatorAtTop = null;
        // we do not support horizontal scroll views.
        return false;
    }
    _dragOffset = 0.0;
    _scaleController.value = 0.0;
    _positionController.value = 0.0;
    _pullBackFactor?.removeListener(pullBackListener);
    _pullBackController.reset();
    return true;
  }

  void _checkDragOffset(double containerExtent) {
    assert(_refreshIndicatorMode == PullToRefreshIndicatorMode.drag ||
        _refreshIndicatorMode == PullToRefreshIndicatorMode.armed);
    late double newValue;
    if (widget.reachToRefreshOffset != null) {
      newValue = _notificationDragOffset! / widget.reachToRefreshOffset!;
    } else if (widget.maxDragOffset != null) {
      newValue = _notificationDragOffset! / widget.maxDragOffset!;
    } else {
      newValue = _notificationDragOffset! /
          (containerExtent * _kDragContainerExtentPercentage);
    }
    if (_refreshIndicatorMode == PullToRefreshIndicatorMode.armed)
      newValue = math.max(newValue, 1.0 / _kDragSizeFactorLimit);
    _positionController.value =
        newValue.clamp(0.0, 1.0); // this triggers various rebuilds

    if (_refreshIndicatorMode == PullToRefreshIndicatorMode.drag &&
        _valueColor!.value!.alpha == 0xFF)
      _refreshIndicatorMode = PullToRefreshIndicatorMode.armed;
  }

  // Stop showing the refresh indicator.
  Future<void> dismiss(PullToRefreshIndicatorMode newMode) async {
    await Future<void>.value();
    // This can only be called from _show() when refreshing and
    // _handleScrollNotification in response to a ScrollEndNotification or
    // direction change.
    assert(newMode == PullToRefreshIndicatorMode.canceled ||
        newMode == PullToRefreshIndicatorMode.done);
    //setState(() {
    _refreshIndicatorMode = newMode;
    //});
    switch (_refreshIndicatorMode) {
      case PullToRefreshIndicatorMode.done:
        await _scaleController.animateTo(1.0,
            duration: _kIndicatorScaleDuration);
        break;
      case PullToRefreshIndicatorMode.canceled:
        await _positionController.animateTo(0.0,
            duration: _kIndicatorScaleDuration);
        break;
      default:
        assert(false);
    }
    if (mounted && _refreshIndicatorMode == newMode && _dragOffset == 0.0) {
      _notificationDragOffset = null;
      _isIndicatorAtTop = null;
      //setState(() {
      _refreshIndicatorMode = null;
      // });
    }
    //_onInnerNoticed();
  }

  void _show() {
    assert(_refreshIndicatorMode != PullToRefreshIndicatorMode.refresh);
    assert(_refreshIndicatorMode != PullToRefreshIndicatorMode.snap);
    final Completer<void> completer = Completer<void>();
    _pendingRefreshFuture = completer.future;
    _refreshIndicatorMode = PullToRefreshIndicatorMode.snap;
    _positionController
        .animateTo(1.0 / _kDragSizeFactorLimit,
            duration: _kIndicatorSnapDuration)
        .then<void>((void value) {
      if (mounted && _refreshIndicatorMode == PullToRefreshIndicatorMode.snap) {
        final Completer<void> pullBackCompleter = Completer<void>();
        if (widget.refreshOffset != null) {
          _pullBack(end: widget.refreshOffset!)
              .whenComplete(() => pullBackCompleter.complete());
        } else {
          pullBackCompleter.complete();
        }

        pullBackCompleter.future.whenComplete(() {
          // setState(() {
          // Show the indeterminate progress indicator.
          _refreshIndicatorMode = PullToRefreshIndicatorMode.refresh;
          //});

          final Future<bool> refreshResult = widget.onRefresh();

          refreshResult.then((bool success) {
            if (mounted &&
                _refreshIndicatorMode == PullToRefreshIndicatorMode.refresh) {
              completer.complete();
              if (success) {
                dismiss(PullToRefreshIndicatorMode.done);
              } else
                _refreshIndicatorMode = PullToRefreshIndicatorMode.error;
            }
          });
        });
      }
    });
  }

  /// Show the refresh indicator and run the refresh callback as if it had
  /// been started interactively. If this method is called while the refresh
  /// callback is running, it quietly does nothing.
  ///
  /// Creating the [PullToRefreshNotification] with a [GlobalKey<RefreshIndicatorState>]
  /// makes it possible to refer to the [PullToRefreshNotificationState].
  ///
  /// The future returned from this method completes when the
  /// [PullToRefreshNotification.onRefresh] callback's future completes.
  ///
  /// If you await the future returned by this function from a [State], you
  /// should check that the state is still [mounted] before calling [setState].
  ///
  /// When initiated in this manner, the refresh indicator is independent of any
  /// actual scroll view. It defaults to showing the indicator at the top. To
  /// show it at the bottom, set `atTop` to false.
  Future<void>? show({bool atTop = true, double? notificationDragOffset}) {
    if (_refreshIndicatorMode != PullToRefreshIndicatorMode.refresh &&
        _refreshIndicatorMode != PullToRefreshIndicatorMode.snap) {
      if (_refreshIndicatorMode == null)
        _start(atTop ? AxisDirection.down : AxisDirection.up);
      if (notificationDragOffset != null) {
        _notificationDragOffset = notificationDragOffset;
      }
      _show();
    }
    return _pendingRefreshFuture;
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasMaterialLocalizations(context));
    final Widget child = NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: _handleGlowNotification,
        child: widget.child,
      ),
    );
    return child;
  }

  void _onInnerNoticed() {
    if ((_dragOffset != null && _dragOffset! > 0.0) &&
            ((_refreshIndicatorMode == PullToRefreshIndicatorMode.done &&
                    !widget.pullBackOnRefresh) ||
                (_refreshIndicatorMode == PullToRefreshIndicatorMode.refresh &&
                    widget.pullBackOnRefresh) ||
                _refreshIndicatorMode == PullToRefreshIndicatorMode.canceled) ||
        (_refreshIndicatorMode == PullToRefreshIndicatorMode.error &&
            widget.pullBackOnError)) {
      _pullBack();
      return;
    }

    if (_pullBackController.isAnimating) {
      pullBackListener();
    } else {
      _onNoticed.add(PullToRefreshScrollNotificationInfo(_refreshIndicatorMode,
          _notificationDragOffset, _getRefreshWidget(), this));
    }
  }

  Widget? _getRefreshWidget() {
    if (_refreshIndicatorMode == null) {
      return null;
    }
    final bool showIndeterminateIndicator =
        _refreshIndicatorMode == PullToRefreshIndicatorMode.refresh ||
            _refreshIndicatorMode == PullToRefreshIndicatorMode.done;
    return ScaleTransition(
      scale: _scaleFactor,
      child: AnimatedBuilder(
        animation: _positionController,
        builder: (BuildContext context, Widget? child) {
          final bool isIOS = Theme.of(context).platform == TargetPlatform.iOS;

          if (isIOS) {
            return PullToRefreshCupertinoActivityIndicator(
              animating: showIndeterminateIndicator,
              radius: 15.0,
              activeColor: widget.color ?? Theme.of(context).colorScheme.secondary,
            );
          } else {
            return RefreshProgressIndicator(
              value: showIndeterminateIndicator ? null : _value.value,
              valueColor: _valueColor,
              strokeWidth: 2.0,
            );
          }
        },
      ),
    );
  }

  void pullBackListener() {
    //print(_pullBackFactor.value);
    if (_dragOffset != _pullBackFactor!.value) {
      _dragOffset = _pullBackFactor!.value;
      _onNoticed.add(PullToRefreshScrollNotificationInfo(
          _refreshIndicatorMode, _dragOffset, _getRefreshWidget(), this));
      if (_dragOffset == 0.0) {
        _dragOffset = null;
        _notificationDragOffset = null;
        _isIndicatorAtTop = null;
        _refreshIndicatorMode = null;
      }
    }
  }

  TickerFuture _pullBack({double? end}) {
    final Animatable<double> _pullBackTween =
        Tween<double>(begin: _notificationDragOffset ?? 0.0, end: end ?? 0.0);
    _pullBackFactor?.removeListener(pullBackListener);
    _pullBackController.reset();
    _pullBackFactor = _pullBackController.drive(_pullBackTween);
    _pullBackFactor!.addListener(pullBackListener);
    return _pullBackController.animateTo(1.0,
        duration: widget.pullBackDuration, curve: widget.pullBackCurve);
    //_DragOffset=0.0;
  }
}

//return true so that we can handle inner scroll notification
bool defaultNotificationPredicate(ScrollNotification notification) {
  return true;
  //return notification.depth == 0;
}

class PullToRefreshScrollNotificationInfo {
  PullToRefreshScrollNotificationInfo(this.mode, this.dragOffset,
      this.refreshWidget, this.pullToRefreshNotificationState);
  final PullToRefreshIndicatorMode? mode;
  final double? dragOffset;
  final Widget? refreshWidget;
  final PullToRefreshNotificationState pullToRefreshNotificationState;
}

class PullToRefreshContainer extends StatefulWidget {
  const PullToRefreshContainer(this.builder);
  final PullToRefreshContainerBuilder builder;
  @override
  _PullToRefreshContainerState createState() => _PullToRefreshContainerState();
}

class _PullToRefreshContainerState extends State<PullToRefreshContainer> {
  @override
  Widget build(BuildContext context) {
    final PullToRefreshNotificationState? ss =
        context.findAncestorStateOfType<PullToRefreshNotificationState>();
    return StreamBuilder<PullToRefreshScrollNotificationInfo>(
      builder: (BuildContext c,
          AsyncSnapshot<PullToRefreshScrollNotificationInfo> s) {
        return widget.builder(s.data);
      },
      stream: ss?.onNoticed,
    );
  }
}

typedef PullToRefreshContainerBuilder = Widget Function(
    PullToRefreshScrollNotificationInfo? info);

// Extracted from iOS 13.2 Beta.
const Color _kActiveTickColor = CupertinoDynamicColor.withBrightness(
  color: Color(0xFF3C3C44),
  darkColor: Color(0xFFEBEBF5),
);

/// An iOS-style activity indicator that spins clockwise.
///
/// See also:
///
///  * <https://developer.apple.com/ios/human-interface-guidelines/controls/progress-indicators/#activity-indicators>
class PullToRefreshCupertinoActivityIndicator extends StatefulWidget {
  /// Creates an iOS-style activity indicator that spins clockwise.
  const PullToRefreshCupertinoActivityIndicator({
    Key? key,
    this.animating = true,
    this.radius =
        PullToRefreshCupertinoActivityIndicator.defaultIndicatorRadius,
    this.activeColor,
  })  : assert(radius > 0),
        super(key: key);

  /// DefaultIndicatorRadius
  static const double defaultIndicatorRadius = 10.0;

  /// Whether the activity indicator is running its animation.
  ///
  /// Defaults to true.
  final bool animating;

  /// Radius of the spinner widget.
  ///
  /// Defaults to 10px. Must be positive and cannot be null.
  final double radius;

  final Color? activeColor;

  @override
  _PullToRefreshCupertinoActivityIndicatorState createState() =>
      _PullToRefreshCupertinoActivityIndicatorState();
}

class _PullToRefreshCupertinoActivityIndicatorState
    extends State<PullToRefreshCupertinoActivityIndicator>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );

    if (widget.animating) {
      _controller!.repeat();
    }
  }

  @override
  void didUpdateWidget(PullToRefreshCupertinoActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animating != oldWidget.animating) {
      if (widget.animating)
        _controller!.repeat();
      else
        _controller!.stop();
    }
  }

  @override
  void dispose() {
    _controller!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.radius * 2,
      width: widget.radius * 2,
      child: CustomPaint(
        painter: _CupertinoActivityIndicatorPainter(
          position: _controller,
          activeColor: widget.activeColor ??
              CupertinoDynamicColor.resolve(_kActiveTickColor, context),
          radius: widget.radius,
        ),
      ),
    );
  }
}

const double _kTwoPI = math.pi * 2.0;
const int _kTickCount = 12;

// Alpha values extracted from the native component (for both dark and light mode).
// The list has a length of 12.
const List<int> _alphaValues = <int>[
  147,
  131,
  114,
  97,
  81,
  64,
  47,
  47,
  47,
  47,
  47,
  47
];

class _CupertinoActivityIndicatorPainter extends CustomPainter {
  _CupertinoActivityIndicatorPainter({
    required this.position,
    required this.activeColor,
    required double radius,
  })  : tickFundamentalRRect = RRect.fromLTRBXY(
          -radius,
          radius /
              PullToRefreshCupertinoActivityIndicator.defaultIndicatorRadius,
          -radius / 2.0,
          -radius /
              PullToRefreshCupertinoActivityIndicator.defaultIndicatorRadius,
          radius /
              PullToRefreshCupertinoActivityIndicator.defaultIndicatorRadius,
          radius /
              PullToRefreshCupertinoActivityIndicator.defaultIndicatorRadius,
        ),
        super(repaint: position);

  final Animation<double>? position;
  final RRect tickFundamentalRRect;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint();

    canvas.save();
    canvas.translate(size.width / 2.0, size.height / 2.0);

    final int activeTick = (_kTickCount * position!.value).floor();

    for (int i = 0; i < _kTickCount; ++i) {
      final int t = (i + activeTick) % _kTickCount;
      paint.color = activeColor.withAlpha(_alphaValues[t]);
      canvas.drawRRect(tickFundamentalRRect, paint);
      canvas.rotate(-_kTwoPI / _kTickCount);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_CupertinoActivityIndicatorPainter oldPainter) {
    return oldPainter.position != position ||
        oldPainter.activeColor != activeColor;
  }
}
