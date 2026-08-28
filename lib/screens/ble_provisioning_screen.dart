import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

class BleProvisioningScreen extends StatefulWidget {
  const BleProvisioningScreen({super.key});

  @override
  State<BleProvisioningScreen> createState() => _BleProvisioningScreenState();
}

class _BleProvisioningScreenState extends State<BleProvisioningScreen> {
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  bool _showAllDevices = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.location,
    ].request();

    _isScanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) setState(() => _isScanning = scanning);
    });

    _startScan();
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    setState(() => _scanResults = []);

    try {
      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        List<ScanResult> filtered;
        if (_showAllDevices) {
          filtered = List.from(results);
        } else {
          filtered = results.where((r) {
            String name = r.device.platformName.toLowerCase();
            String advName = r.advertisementData.advName.toLowerCase();
            bool hasName = name.contains("timber") || name.contains("td_") || advName.contains("timber") || advName.contains("td_");
            bool hasService = r.advertisementData.serviceUuids.any(
              (u) => u.toString().toLowerCase().contains("4fafc201"),
            );
            bool hasMfg = r.advertisementData.manufacturerData.values.any((data) {
              String str = String.fromCharCodes(data);
              return str.startsWith("TD:");
            });
            return hasName || hasService || hasMfg;
          }).toList();
        }

        filtered.sort((a, b) => b.rssi.compareTo(a.rssi));
        setState(() => _scanResults = filtered);
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));
    } catch (_) {}
  }

  String _extractDeviceId(ScanResult r) {
    String name = r.device.platformName;
    if (name.contains("TimberDry_")) return name.replaceFirst("TimberDry_", "");
    if (name.contains("TD_")) return name.replaceFirst("TD_", "");

    for (var data in r.advertisementData.manufacturerData.values) {
      String str = String.fromCharCodes(data);
      if (str.startsWith("TD:")) {
        return str.substring(3);
      }
    }
    String id = r.device.remoteId.str.replaceAll(':', '').toUpperCase();
    if (id.length >= 8) return id.substring(id.length - 8);
    return id;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Пошук датчиків ESP32',
              style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            Text(
              'Bluetooth BLE Provisioning',
              style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF00E5FF)),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: _isScanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF9000)),
                  )
                : const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _startScan,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E2838), Color(0xFF121722)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFFF9000).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF9000).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.bluetooth_searching, color: Color(0xFFFF9000), size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Режим підключення ESP32',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Натисніть кнопку BOOT на платі ESP32. Світлодіод почне блимати подвійними спалахами, і плата з\'явиться нижче.',
                        style: GoogleFonts.inter(fontSize: 11, color: Colors.white60),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Знайдені плати (${_scanResults.length})',
                style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              Row(
                children: [
                  const Text('Всі: ', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  Switch(
                    value: _showAllDevices,
                    activeColor: const Color(0xFFFF9000),
                    onChanged: (val) {
                      setState(() => _showAllDevices = val);
                      _startScan();
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_scanResults.isEmpty && !_isScanning) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
              alignment: Alignment.center,
              child: Column(
                children: [
                  const Icon(Icons.sensors_off, size: 48, color: Colors.white24),
                  const SizedBox(height: 12),
                  Text(
                    'Датчиків поблизу не виявлено',
                    style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white60),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Перевірте, чи увімкнено Bluetooth на телефоні та натисніть кнопку BOOT на ESP32.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(fontSize: 12, color: Colors.white38),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _startScan,
                    icon: const Icon(Icons.refresh, color: Colors.black),
                    label: const Text('СКАНУВАТИ ЗНОВУ', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9000),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            ..._scanResults.map((res) => _buildDeviceCard(res)),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceCard(ScanResult r) {
    final deviceId = _extractDeviceId(r);
    final displayName = 'Датчик #$deviceId';
    final rssi = r.rssi;
    int quality = ((rssi + 100) * 2).clamp(0, 100);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131824),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF00E5FF).withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.memory, color: Color(0xFF00E5FF), size: 24),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                displayName,
                style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$quality%',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
              ),
            ),
          ],
        ),
        subtitle: Text(
          'ID: #$deviceId • Сигнал: $rssi dBm',
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        trailing: ElevatedButton(
          onPressed: () => _showConfigureModal(r, deviceId),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF9000),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(
            'Налаштувати Wi-Fi',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black),
          ),
        ),
      ),
    );
  }

  void _showConfigureModal(ScanResult result, String deviceId) {
    final ssidCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final pinCtrl = TextEditingController(text: '196711');
    bool isSending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121622),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Підключення Wi-Fi: #$deviceId',
                        style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  TextField(
                    controller: ssidCtrl,
                    decoration: InputDecoration(
                      labelText: 'Назва Wi-Fi мережі (SSID)',
                      prefixIcon: const Icon(Icons.wifi, color: Color(0xFFFF9000)),
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.3),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),

                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Пароль від Wi-Fi',
                      prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFFFF9000)),
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.3),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),

                  TextField(
                    controller: pinCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'PIN безпеки (196711)',
                      prefixIcon: const Icon(Icons.pin, color: Color(0xFF10B981)),
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.3),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 18),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isSending
                          ? null
                          : () async {
                              final ssid = ssidCtrl.text.trim();
                              final pass = passCtrl.text.trim();
                              final pin = pinCtrl.text.trim();

                              if (ssid.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Введіть назву Wi-Fi мережі!')),
                                );
                                return;
                              }

                              setModalState(() => isSending = true);

                              try {
                                await result.device.connect(timeout: const Duration(seconds: 10));
                                final services = await result.device.discoverServices();

                                BluetoothCharacteristic? targetChar;
                                for (var s in services) {
                                  for (var c in s.characteristics) {
                                    if (c.uuid.toString().toLowerCase().contains("beb5483e")) {
                                      targetChar = c;
                                      break;
                                    }
                                  }
                                }

                                if (targetChar != null) {
                                  // Payload format: PIN:SSID:PASS:Сушарка #ID
                                  String payload = "$pin:$ssid:$pass:Сушарка #$deviceId";
                                  await targetChar.write(utf8.encode(payload), withoutResponse: false);

                                  if (mounted) {
                                    Navigator.pop(context);
                                    showDialog(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        backgroundColor: const Color(0xFF182030),
                                        title: const Row(
                                          children: [
                                            Icon(Icons.check_circle, color: Color(0xFF10B981)),
                                            SizedBox(width: 8),
                                            Text('Успішно!'),
                                          ],
                                        ),
                                        content: Text(
                                          'Налаштування мережі передано на ESP32 (#$deviceId).\n\nПлата перезавантажується та з\'єднується з "$ssid". Світлодіод D2 засвітиться постійно після з\'єднання з хмарою.',
                                        ),
                                        actions: [
                                          ElevatedButton(
                                            onPressed: () => Navigator.pop(context),
                                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF9000)),
                                            child: const Text('ЗРОЗУМІЛО', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                } else {
                                  throw Exception("Сервіс налаштування не знайдено");
                                }
                              } catch (e) {
                                setModalState(() => isSending = false);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Помилка: $e'), backgroundColor: const Color(0xFFEF4444)),
                                  );
                                }
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9000),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: isSending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                            )
                          : Text(
                              'ЗАПИСАТИ НАЛАШТУВАННЯ',
                              style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, color: Colors.black),
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
