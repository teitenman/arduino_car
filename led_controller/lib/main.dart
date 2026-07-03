import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

const String _serviceUuid = 'FFE0';
const String _charUuid = 'FFE1';
const String _deviceName = 'LED Controller';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arduino Car Controller',
      theme: ThemeData(useMaterial3: true),
      home: const CarControlPage(),
    );
  }
}

// ─── Page ─────────────────────────────────────────────────────────────────────

class CarControlPage extends StatefulWidget {
  const CarControlPage({super.key});

  @override
  State<CarControlPage> createState() => _CarControlPageState();
}

class _CarControlPageState extends State<CarControlPage>
    with SingleTickerProviderStateMixin {
  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _char;
  bool _connected = false;
  bool _scanning = false;
  bool _connecting = false;
  String? _errorMsg;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // Car control
  bool _accelerating = false;
  bool _braking = false;
  double _steeringAngle = 0.0; // -1.0 (full left) to 1.0 (full right)
  String _lastCommand = 'S';
  bool _cmdBusy = false;

  // Steering return animation
  late AnimationController _returnCtrl;
  Animation<double>? _returnAnim;

  @override
  void initState() {
    super.initState();
    _returnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  // ─── Steering ────────────────────────────────────────────────────────────

  // Compute the combined command from current pedal + steering state
  String _computeCommand() {
    final speed = _accelerating ? 'F' : _braking ? 'B' : '';
    final dir = _steeringAngle < -0.25 ? 'L' : _steeringAngle > 0.25 ? 'R' : '';
    final cmd = speed + dir;
    return cmd.isEmpty ? 'S' : cmd;
  }

  void _onSteerUpdate(DragUpdateDetails d, double height) {
    _returnCtrl.stop();
    _returnAnim?.removeListener(_onReturnTick);
    // Up (dy < 0) → left, Down (dy > 0) → right
    final delta = d.delta.dy / (height * 0.4);
    setState(() => _steeringAngle = (_steeringAngle + delta).clamp(-1.0, 1.0));
    _sendCommand(_computeCommand());
  }

  void _onSteerEnd(DragEndDetails _) {
    _returnAnim?.removeListener(_onReturnTick);
    _returnAnim = Tween<double>(begin: _steeringAngle, end: 0.0).animate(
      CurvedAnimation(parent: _returnCtrl, curve: Curves.elasticOut),
    )..addListener(_onReturnTick);
    _returnCtrl.forward(from: 0);
  }

  void _onReturnTick() {
    if (!mounted) return;
    setState(() => _steeringAngle = _returnAnim!.value);
    _sendCommand(_computeCommand());
  }

  // ─── Pedals ──────────────────────────────────────────────────────────────

  void _onAccPress() {
    _returnCtrl.stop();
    _returnAnim?.removeListener(_onReturnTick);
    setState(() => _accelerating = true);
    _sendCommand(_computeCommand());
  }

  void _onAccRelease() {
    setState(() => _accelerating = false);
    _sendCommand(_computeCommand());
  }

  void _onBrakePress() {
    _returnCtrl.stop();
    _returnAnim?.removeListener(_onReturnTick);
    setState(() => _braking = true);
    _sendCommand(_computeCommand());
  }

  void _onBrakeRelease() {
    setState(() => _braking = false);
    _sendCommand(_computeCommand());
  }

  // ─── BLE ─────────────────────────────────────────────────────────────────

  Future<void> _startScan() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
      if (statuses.values.any((s) => s.isDenied || s.isPermanentlyDenied)) {
        setState(() => _errorMsg = 'Bluetooth 許可が必要です');
        return;
      }
    }

    setState(() {
      _scanning = true;
      _errorMsg = null;
    });

    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _errorMsg = 'Bluetooth がオフです。設定から有効にしてください';
        });
      }
      return;
    }

    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    _connecting = false;
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      if (_connecting) return;
      for (final r in results) {
        final nameMatch =
            r.device.platformName == _deviceName ||
            r.device.platformName == 'Arduino';
        final uuidMatch = r.advertisementData.serviceUuids.any(
          (u) => u.str128.toUpperCase().contains(_serviceUuid),
        );
        if (nameMatch || uuidMatch) {
          FlutterBluePlus.stopScan();
          _connect(r.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.isScanning
            .where((s) => s == false)
            .first
            .timeout(const Duration(seconds: 11));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _errorMsg = 'スキャンエラー: $e';
        });
      }
      return;
    }

    if (mounted && !_connecting) {
      setState(() {
        _scanning = false;
        _errorMsg = '"$_deviceName" が見つかりませんでした';
      });
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _device = device;
      _scanning = false;
      _connecting = true;
    });

    _connSub?.cancel();
    _connSub = device.connectionState.listen((state) async {
      if (!mounted) return;
      if (state == BluetoothConnectionState.connected) {
        await _discoverChar(device);
        if (mounted) setState(() => _connected = true);
      } else if (state == BluetoothConnectionState.disconnected) {
        if (mounted)
          setState(() {
            _connected = false;
            _char = null;
          });
      }
    });

    try {
      await device.connect();
    } catch (e) {
      if (mounted) setState(() => _errorMsg = '接続エラー: $e');
    }
  }

  Future<void> _discoverChar(BluetoothDevice device) async {
    final services = await device.discoverServices();
    for (final s in services) {
      if (s.uuid.str128.toUpperCase().contains(_serviceUuid)) {
        for (final c in s.characteristics) {
          if (c.uuid.str128.toUpperCase().contains(_charUuid)) {
            _char = c;
            return;
          }
        }
      }
    }
  }

  Future<void> _sendCommand(String cmd) async {
    if (_char == null || cmd == _lastCommand || _cmdBusy) return;
    _cmdBusy = true;
    try {
      await _char!.write(cmd.codeUnits, withoutResponse: true);
      if (mounted) setState(() { _lastCommand = cmd; _errorMsg = null; });
    } catch (e) {
      if (mounted) setState(() => _errorMsg = '送信エラー: $e');
    } finally {
      _cmdBusy = false;
    }
  }

  Future<void> _disconnect() async {
    await _device?.disconnect();
    if (mounted) {
      setState(() {
        _device = null;
        _connected = false;
        _char = null;
        _lastCommand = 'S';
        _accelerating = false;
        _braking = false;
        _steeringAngle = 0.0;
      });
    }
  }

  @override
  void dispose() {
    _returnAnim?.removeListener(_onReturnTick);
    _returnCtrl.dispose();
    _scanSub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Arduino Car Controller'),
        foregroundColor: null,
        actions: [
          if (_connected)
            IconButton(
              icon: const Icon(
                Icons.bluetooth_disabled,
                color: Colors.redAccent,
              ),
              tooltip: '切断',
              onPressed: _disconnect,
            ),
        ],
      ),
      body: _connected ? _buildController() : _buildScanView(),
      // body: _buildController(),
    );
  }

  Widget _buildScanView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.bluetooth_searching,
            size: 80,
            color: Colors.blueAccent,
          ),
          const SizedBox(height: 24),
          Text(
            _scanning
                ? 'スキャン中...'
                : _connecting
                ? '接続中...'
                : 'Arduino を探す',
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 32),
          if (_scanning || _connecting)
            const CircularProgressIndicator()
          else
            ElevatedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.search),
              label: const Text('スキャン開始'),
            ),
          if (_errorMsg != null) ...[
            const SizedBox(height: 20),
            Text(
              _errorMsg!,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildController() {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return Column(
          children: [
            // Status strip
            _StatusStrip(
              deviceName: _device?.platformName ?? '',
              command: _lastCommand,
            ),

            // Pedals
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 6,
                      child: PedalWidget(
                        label: 'BRAKE',
                        isPressed: _braking,
                        activeColor: const Color(0xFFB71C1C),
                        onPress: _onBrakePress,
                        onRelease: _onBrakeRelease,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 5,
                      child: PedalWidget(
                        label: 'ACC',
                        isPressed: _accelerating,
                        activeColor: const Color(0xFF1565C0),
                        onPress: _onAccPress,
                        onRelease: _onAccRelease,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Steering wheel
            Expanded(
              flex: 7,
              child: GestureDetector(
                onPanUpdate: (d) => _onSteerUpdate(d, constraints.maxHeight),
                onPanEnd: _onSteerEnd,
                child: Center(
                  child: SteeringWheelWidget(angle: _steeringAngle),
                ),
              ),
            ),

            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

// ─── Status Strip ─────────────────────────────────────────────────────────────

class _StatusStrip extends StatelessWidget {
  final String deviceName;
  final String command;

  const _StatusStrip({required this.deviceName, required this.command});

  Color get _cmdColor {
    if (command.startsWith('F')) return Colors.green;
    if (command.startsWith('B')) return Colors.orangeAccent;
    if (command == 'L' || command == 'R') return Colors.blueAccent;
    return Colors.grey;
  }

  String get _cmdLabel {
    switch (command) {
      case 'F':  return '▲ FORWARD';
      case 'B':  return '▼ BRAKE';
      case 'L':  return '◀ LEFT';
      case 'R':  return 'RIGHT ▶';
      case 'FL': return '↖ FWD-L';
      case 'FR': return '↗ FWD-R';
      case 'BL': return '↙ BRK-L';
      case 'BR': return '↘ BRK-R';
      default:   return '■ STOP';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(
                Icons.bluetooth_connected,
                color: Colors.green,
                size: 14,
              ),
              const SizedBox(width: 6),
              Text(
                deviceName,
                style: const TextStyle(color: Colors.green, fontSize: 12),
              ),
            ],
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: _cmdColor.withValues(alpha: 0.15),
              border: Border.all(color: _cmdColor, width: 1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _cmdLabel,
              style: TextStyle(
                color: _cmdColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Pedal Widget ─────────────────────────────────────────────────────────────

class PedalWidget extends StatelessWidget {
  final String label;
  final bool isPressed;
  final Color activeColor;
  final VoidCallback onPress;
  final VoidCallback onRelease;

  const PedalWidget({
    super.key,
    required this.label,
    required this.isPressed,
    required this.activeColor,
    required this.onPress,
    required this.onRelease,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => onPress(),
      onTapUp: (_) => onRelease(),
      onTapCancel: onRelease,
      onPanStart: (_) => onPress(),
      onPanEnd: (_) => onRelease(),
      onPanCancel: onRelease,
      child: AnimatedScale(
        scale: isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            CustomPaint(
              painter: _PedalPainter(
                activeColor: activeColor,
                isPressed: isPressed,
              ),
              size: Size.infinite,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                label,
                style: TextStyle(
                  color: isPressed ? Colors.white : Colors.black45,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PedalPainter extends CustomPainter {
  final Color activeColor;
  final bool isPressed;

  static const _baseColor = Color(0xFF3A3A3A);
  static const _bracketColor = Color(0xFF1A1A1A);

  const _PedalPainter({required this.activeColor, required this.isPressed});

  @override
  void paint(Canvas canvas, Size size) {
    final bodyColor = isPressed ? activeColor : _baseColor;
    final paint = Paint()..style = PaintingStyle.fill;

    // Mounting arm (right side bracket)
    paint.color = _bracketColor;
    final armRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.6,
        size.height * 0.1,
        size.width * 0.4,
        size.height * 0.14,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(armRect, paint);

    // Pedal body shadow
    if (!isPressed) {
      paint.color = Colors.black.withValues(alpha: 0.5);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            4,
            size.height * 0.06 + 4,
            size.width * 0.72,
            size.height * 0.84,
          ),
          const Radius.circular(14),
        ),
        paint,
      );
    }

    // Pedal body
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        0,
        size.height * 0.06,
        size.width * 0.72,
        size.height * 0.84,
      ),
      const Radius.circular(14),
    );
    paint.color = bodyColor;
    canvas.drawRRect(bodyRect, paint);

    // Top-edge highlight
    if (!isPressed) {
      paint
        ..color = Colors.white.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            1.5,
            size.height * 0.06 + 1.5,
            size.width * 0.72 - 3,
            size.height * 0.84 - 3,
          ),
          const Radius.circular(13),
        ),
        paint,
      );
      paint.style = PaintingStyle.fill;
    }

    // Horizontal ribs
    final ribPaint = Paint()
      ..color = Colors.black.withValues(alpha: isPressed ? 0.35 : 0.45)
      ..style = PaintingStyle.fill;

    const ribCount = 5;
    final ribH = size.height * 0.055;
    final totalRibArea = size.height * 0.65;
    final spacing = totalRibArea / ribCount;
    final startY = size.height * 0.14;

    for (int i = 0; i < ribCount; i++) {
      final y = startY + i * spacing;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.08, y, size.width * 0.56, ribH),
          const Radius.circular(3),
        ),
        ribPaint,
      );
    }

    // Pressed darkening overlay
    if (isPressed) {
      paint.color = Colors.black.withValues(alpha: 0.18);
      canvas.drawRRect(bodyRect, paint);
    }
  }

  @override
  bool shouldRepaint(_PedalPainter old) =>
      old.isPressed != isPressed || old.activeColor != activeColor;
}

// ─── Steering Wheel Widget ────────────────────────────────────────────────────

class SteeringWheelWidget extends StatelessWidget {
  final double angle; // -1.0 to 1.0

  const SteeringWheelWidget({super.key, required this.angle});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle * (math.pi / 3), // ±60°
      child: CustomPaint(
        size: const Size(270, 270),
        painter: const _SteeringWheelPainter(),
      ),
    );
  }
}

class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);

    final outerR = size.width / 2;
    final ringMid = outerR * 0.82;
    final ringThickness = outerR * 0.22;
    final innerR = ringMid - ringThickness / 2;
    final hubR = outerR * 0.19;

    // Drop shadow
    canvas.drawCircle(
      center + const Offset(3, 6),
      outerR * 0.97,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );

    // Outer ring fill
    canvas.drawCircle(center, outerR, Paint()..color = const Color(0xFF1C1C1C));

    // Ring (thick stroke)
    canvas.drawCircle(
      center,
      ringMid,
      Paint()
        ..color = const Color(0xFF2A2A2A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringThickness,
    );

    // Ring top-left highlight
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: ringMid),
      -math.pi * 1.1,
      math.pi * 0.55,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringThickness * 0.4,
    );

    // Grip sections (darker)
    final gripPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringThickness * 0.65
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF181818);

    final gripDefs = [
      (-math.pi / 2 - math.pi * 0.38, math.pi * 0.23),
      (-math.pi / 2 + math.pi * 0.15, math.pi * 0.23),
      (math.pi / 2 - math.pi * 0.11, math.pi * 0.22),
    ];
    for (final g in gripDefs) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringMid),
        g.$1,
        g.$2,
        false,
        gripPaint,
      );
    }

    // Spokes (3, at 90°, 210°, 330°)
    final spokePaint = Paint()
      ..color = const Color(0xFF303030)
      ..style = PaintingStyle.stroke
      ..strokeWidth = outerR * 0.10
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 3; i++) {
      final a = -math.pi / 2 + i * (2 * math.pi / 3);
      canvas.drawLine(
        center + Offset(math.cos(a) * hubR * 1.15, math.sin(a) * hubR * 1.15),
        center +
            Offset(math.cos(a) * innerR * 0.92, math.sin(a) * innerR * 0.92),
        spokePaint,
      );
    }

    // Spoke highlight
    final spokeHL = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = outerR * 0.035
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      final a = -math.pi / 2 + i * (2 * math.pi / 3);
      canvas.drawLine(
        center + Offset(math.cos(a) * hubR * 1.2, math.sin(a) * hubR * 1.2),
        center + Offset(math.cos(a) * innerR * 0.9, math.sin(a) * innerR * 0.9),
        spokeHL,
      );
    }

    // Hub background
    canvas.drawCircle(center, hubR, Paint()..color = const Color(0xFF1A1A1A));

    // Hub ring detail
    canvas.drawCircle(
      center,
      hubR * 0.72,
      Paint()
        ..color = const Color(0xFF3A3A3A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hubR * 0.12,
    );

    // Hub center
    canvas.drawCircle(
      center,
      hubR * 0.28,
      Paint()..color = const Color(0xFF484848),
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
