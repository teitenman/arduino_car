import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

const String _serviceUuid = 'FFE0';
const String _charUuid = 'FFE1';
const String _deviceName = 'LED Controller';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arduino Car Controller',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const LedControlPage(),
    );
  }
}

// ─── ページ ────────────────────────────────────────────────────────────────
class LedControlPage extends StatefulWidget {
  const LedControlPage({super.key});

  @override
  State<LedControlPage> createState() => _LedControlPageState();
}

class _LedControlPageState extends State<LedControlPage> {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _char;
  bool _connected = false;
  bool _scanning = false;
  bool _connecting = false;
  bool? _ledOn;
  String? _errorMsg;
  List<String> _foundDevices = [];

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // ── スキャン開始 ──────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      if (statuses.values.any((s) => s.isDenied || s.isPermanentlyDenied)) {
        setState(() => _errorMsg = 'Bluetooth permission denied');
        return;
      }
    }

    setState(() {
      _scanning = true;
      _errorMsg = null;
    });

    // アダプタが ON になるまで待つ（許可直後は準備中のことがある）
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

    // 前回のスキャンが残っていればクリア
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    _connecting = false;
    _foundDevices = [];
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      if (_connecting) return;
      // for (final r in results) {
      //   debugPrint('[BLE] ${r.device.platformName.isEmpty ? "(no name)" : r.device.platformName} | ${r.device.remoteId} | RSSI:${r.rssi}');
      // }
      setState(() {
        _foundDevices = results
            .map(
              (r) =>
                  '${r.device.platformName.isEmpty ? "(no name)" : r.device.platformName} [${r.device.remoteId}]',
            )
            .toList();
      });
      for (final r in results) {
        final nameMatch =
            r.device.platformName == _deviceName ||
            r.device.platformName == 'Arduino';
        final uuidMatch = r.advertisementData.serviceUuids.any(
          (u) => u.str128.toUpperCase().contains(_serviceUuid),
        );
        if (nameMatch || uuidMatch) {
          _connecting = true;
          FlutterBluePlus.stopScan();
          _connect(r.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      // iOS では startScan が即 return するため、スキャン終了まで明示的に待つ
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.isScanning
            .where((scanning) => scanning == false)
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

  // ── 接続 ─────────────────────────────────────────────────────────────────
  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _device = device;
      _scanning = false;
    });

    _connSub?.cancel();
    _connSub = device.connectionState.listen((state) async {
      if (!mounted) return;
      if (state == BluetoothConnectionState.connected) {
        await _discoverChar(device);
        setState(() => _connected = true);
      } else if (state == BluetoothConnectionState.disconnected) {
        setState(() {
          _connected = false;
          _ledOn = null;
          _char = null;
        });
      }
    });

    try {
      await device.connect();
    } catch (e) {
      setState(() => _errorMsg = '接続エラー: $e');
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

  // ── LED コマンド送信 ──────────────────────────────────────────────────────
  Future<void> _sendLed(bool on) async {
    if (_char == null) return;
    try {
      await _char!.write([on ? 1 : 0], withoutResponse: false);
      setState(() => _ledOn = on);
    } catch (e) {
      setState(() => _errorMsg = '送信エラー: $e');
    }
  }

  // ── 切断 ─────────────────────────────────────────────────────────────────
  Future<void> _disconnect() async {
    await _device?.disconnect();
    setState(() {
      _device = null;
      _connected = false;
      _ledOn = null;
      _char = null;
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Arduino Car Controller'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_connected)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              tooltip: '切断',
              onPressed: _disconnect,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: _connected ? _buildControls() : _buildScanView()),
      ),
    );
  }

  // 未接続: スキャンボタン
  Widget _buildScanView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.bluetooth_searching, size: 80, color: Colors.blue),
        const SizedBox(height: 24),
        Text(
          _scanning ? 'スキャン中...' : 'Arduino を探す',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 32),
        if (_scanning)
          const CircularProgressIndicator()
        else
          FilledButton.icon(
            onPressed: _startScan,
            icon: const Icon(Icons.search),
            label: const Text('スキャン開始'),
          ),
        if (_errorMsg != null) ...[
          const SizedBox(height: 20),
          Text(
            _errorMsg!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  // 接続済み: LED コントロール
  Widget _buildControls() {
    final ledColor = _ledOn == null
        ? Colors.grey
        : _ledOn!
        ? Colors.yellow
        : Colors.grey.shade700;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // LED インジケーター
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 140,
          height: 140,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ledColor,
            boxShadow: _ledOn == true
                ? [
                    BoxShadow(
                      color: Colors.yellow.withValues(alpha: 0.6),
                      blurRadius: 40,
                      spreadRadius: 12,
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(
              _ledOn == null ? '---' : (_ledOn! ? 'ON' : 'OFF'),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: _ledOn == true ? Colors.black87 : Colors.white54,
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),
        Text(
          '接続中: ${_device?.platformName ?? ""}',
          style: const TextStyle(color: Colors.green, fontSize: 13),
        ),

        const SizedBox(height: 40),

        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ON ボタン
            SizedBox(
              width: 130,
              height: 56,
              child: ElevatedButton(
                onPressed: (_ledOn == true || _char == null)
                    ? null
                    : () => _sendLed(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black87,
                ),
                child: const Text(
                  'ON',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 24),
            // OFF ボタン
            SizedBox(
              width: 130,
              height: 56,
              child: ElevatedButton(
                onPressed: (_ledOn == false || _char == null)
                    ? null
                    : () => _sendLed(false),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey.shade700,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'OFF',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),

        if (_errorMsg != null) ...[
          const SizedBox(height: 20),
          Text(
            _errorMsg!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
