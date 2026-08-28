import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import 'firebase_options.dart';
import 'models/drying_models.dart';
import 'services/emc_calculator.dart';
import 'services/storage_service.dart';
import 'services/app_identity_service.dart';
import 'screens/ble_provisioning_screen.dart';
import 'services/update_service.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {
    try {
      await Firebase.initializeApp();
    } catch (_) {}
  }
  await StorageService.init();
  await StorageService.registerAppInstance();
  runApp(const TimberDryApp());
}

class TimberDryApp extends StatelessWidget {
  const TimberDryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TimberDry Desktop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0D14),
        primaryColor: const Color(0xFFFF9000),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF9000),
          secondary: Color(0xFF00E5FF),
          surface: Color(0xFF131824),
          error: Color(0xFFEF4444),
        ),
        fontFamily: GoogleFonts.inter().fontFamily,
        fontFamilyFallback: const ['Roboto', 'sans-serif'],
        textTheme: GoogleFonts.interTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

// ================= MAIN NAVIGATION =================
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  late final PageController _pageController;
  String _myAppId = '';
  List<Project> _projects = [];
  String? _selectedProjectId;
  List<KilnDevice> _kilns = [];
  List<DryingProgram> _programs = [];
  List<AlertItem> _alerts = [];
  bool _isAdmin = false;
  StreamSubscription<List<Project>>? _projectsSub;
  StreamSubscription<List<KilnDevice>>? _firestoreSubscription;
  StreamSubscription<List<AlertItem>>? _alertsSub;
  Timer? _heartbeatTimer;
  DateTime _lastAlertTime = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _lastLoggedTime = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);
    _isAdmin = StorageService.isAdmin();
    _selectedProjectId = StorageService.getSelectedProjectId();
    _initAppIdAndSubscriptions();
    _startHeartbeatWatchdog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UpdateService.checkAndShowUpdateDialog(context);
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _pageController.dispose();
    _projectsSub?.cancel();
    _firestoreSubscription?.cancel();
    _alertsSub?.cancel();
    super.dispose();
  }

  Future<void> _initAppIdAndSubscriptions() async {
    final appId = await AppIdentityService.getAppInstanceId();
    final programs = await StorageService.loadPrograms();
    if (mounted) {
      setState(() {
        _myAppId = appId;
        _programs = programs;
        _isAdmin = StorageService.isAdmin();
      });
    }
    _subscribeToProjects();
  }

  void _startHeartbeatWatchdog() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || _kilns.isEmpty) return;
      _recheckDeviceLiveness();
    });
  }

  void _recheckDeviceLiveness() {
    if (!_isAdmin && _projects.isEmpty) return;

    final nowUtc = DateTime.now().toUtc();
    bool changed = false;

    for (var kiln in _kilns) {
      final silenceSec = nowUtc.difference(kiln.lastSeen.toUtc()).inSeconds;
      final bool shouldBeOnline = silenceSec <= 40;

      if (kiln.isOnline != shouldBeOnline) {
        kiln.isOnline = shouldBeOnline;
        changed = true;
      }
    }

    if (changed && mounted) {
      setState(() {});
    }

    _evaluateDeviations(_kilns);
  }

  Future<void> _loadAllData() async {
    final programs = await StorageService.loadPrograms();
    if (mounted) {
      setState(() {
        _programs = programs;
        _isAdmin = StorageService.isAdmin();
      });
    }
  }

  void _subscribeToAlerts() {
    _alertsSub?.cancel();
    _alertsSub = StorageService.getAlertsStream(
      myAppId: _myAppId,
      isAdmin: _isAdmin,
      userProjects: _projects,
    ).listen((alerts) {
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
      });
    }, onError: (_) {});
  }

  void _subscribeToProjects() {
    _projectsSub?.cancel();
    _projectsSub = StorageService.getProjectsStream(isAdminMode: _isAdmin).listen((projects) {
      if (!mounted) return;
      setState(() {
        _projects = projects;
        if (_selectedProjectId == null && projects.isNotEmpty) {
          _selectedProjectId = _isAdmin ? 'all' : projects.first.id;
        }
      });
      _subscribeToFirestore();
      _subscribeToAlerts();
    }, onError: (_) {});
  }

  void _subscribeToFirestore() {
    _firestoreSubscription?.cancel();
    _firestoreSubscription = StorageService.getDevicesStream(
      isAdminMode: _isAdmin,
      selectedProjectId: _selectedProjectId,
      userProjects: _projects,
    ).listen((cloudDevices) {
      if (!mounted) return;
      setState(() {
        _kilns = cloudDevices;
      });
      _evaluateDeviations(cloudDevices);
    }, onError: (_) {});
  }

  void _onSelectProject(String? projId) async {
    await StorageService.setSelectedProjectId(projId);
    setState(() => _selectedProjectId = projId);
    _subscribeToFirestore();
    _subscribeToAlerts();
  }

  void _triggerAlarmSoundAndHaptics() {
    if (StorageService.isNotificationsMuted()) return;

    try {
      FlutterRingtonePlayer().playAlarm(
        volume: 1.0,
        looping: false,
        asAlarm: true,
      );
    } catch (_) {
      try {
        FlutterRingtonePlayer().playNotification();
      } catch (_) {}
    }
    HapticFeedback.heavyImpact();
  }

  void _evaluateDeviations(List<KilnDevice> devices) async {
    if (!_isAdmin && _projects.isEmpty) {
      // User is not in any project -> do not generate/receive alerts
      return;
    }

    final now = DateTime.now();

    for (var kiln in devices) {
      final session = kiln.activeSession;
      final bool isDrying = session != null && !session.isCompleted;

      // IMPORTANT: If no drying program is running on this kiln, DO NOT raise any alerts/alarms!
      if (!isDrying) {
        continue;
      }

      // 1. Offline Check during active drying program
      if (!kiln.isOnline) {
        if (now.difference(_lastAlertTime).inSeconds > 30) {
          _lastAlertTime = now;
          final alert = AlertItem(
            id: 'alert_offline_${kiln.deviceId}_${now.millisecondsSinceEpoch}',
            kilnId: kiln.deviceId,
            kilnName: kiln.name,
            timestamp: now,
            severity: 'critical',
            title: '🚨 ПЛАТА НЕ НА ЗВ\'ЯЗКУ (OFFLINE)',
            message: 'Сушарка #${kiln.deviceId} не передає дані! Перевірте живлення плати або Wi-Fi з\'єднання.',
          );
          await StorageService.saveAlert(alert);
          _triggerAlarmSoundAndHaptics();

          if (mounted && !StorageService.isNotificationsMuted()) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFFEF4444),
                duration: const Duration(seconds: 4),
                content: Row(
                  children: [
                    const Icon(Icons.wifi_off, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${alert.title}: ${alert.message}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        }
        continue;
      }

      // 2. Sensor disconnect
      if (!kiln.sensorConnected) {
        if (now.difference(_lastAlertTime).inSeconds > 30) {
          _lastAlertTime = now;
          final alert = AlertItem(
            id: 'alert_sensor_${kiln.deviceId}_${now.millisecondsSinceEpoch}',
            kilnId: kiln.deviceId,
            kilnName: kiln.name,
            timestamp: now,
            severity: 'critical',
            title: '⚠️ ОБРИВ АБО ВІДКЛЮЧЕННЯ ДАТЧИКА',
            message: 'Плата #${kiln.deviceId} втратила зв\'язок із датчиком (D15).',
          );
          await StorageService.saveAlert(alert);
          _triggerAlarmSoundAndHaptics();
        }
        continue;
      }

      // 3. Active Drying Session Logbook & Deviation Tracking
      if (session != null && !session.isCompleted) {
        final prog = _programs.firstWhere((p) => p.id == session.programId, orElse: () => _programs.first);
        final (activeStep, stepIndex, _) = EmcCalculator.getActiveStep(prog, session.elapsedHours);

        final lastLogged = _lastLoggedTime[kiln.deviceId] ?? DateTime.fromMillisecondsSinceEpoch(0);
        if (now.difference(lastLogged).inSeconds >= 60 && activeStep != null) {
          _lastLoggedTime[kiln.deviceId] = now;

          final point = TelemetryPoint(
            timestamp: now,
            temp: kiln.currentTemp,
            humidity: kiln.currentHumidity,
            emc: kiln.currentEmc,
            stepIndex: stepIndex,
            targetTemp: activeStep.targetTemp,
            targetHumidity: activeStep.targetHumidity,
          );

          await StorageService.logTelemetryPoint(kiln.deviceId, session, point);
        }

        final alert = EmcCalculator.checkDeviations(
          kiln: kiln,
          program: prog,
          elapsedHours: session.elapsedHours,
        );

        if (alert != null) {
          if (now.difference(_lastAlertTime).inSeconds > 45) {
            _lastAlertTime = now;
            await StorageService.saveAlert(alert);
            _triggerAlarmSoundAndHaptics();

            if (mounted && !StorageService.isNotificationsMuted()) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: alert.severity == 'critical' ? const Color(0xFFEF4444) : const Color(0xFFFF9000),
                  duration: const Duration(seconds: 4),
                  content: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${alert.title}: ${alert.message}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
          }
        }
      }
    }
  }

  void _showMuteOptionsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.notifications_paused, color: Color(0xFFFF9000)),
            SizedBox(width: 8),
            Text('Режим сповіщень'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_active, color: Color(0xFF10B981)),
              title: const Text('Увімкнути всі сповіщення'),
              subtitle: const Text('Звук та вібрація працюють у штатному режимі', style: TextStyle(fontSize: 11)),
              onTap: () async {
                await StorageService.setMuteOption('unmute');
                if (mounted) setState(() {});
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('🔔 Сповіщення увімкнено!')),
                );
              },
            ),
            const Divider(color: Colors.white12),
            ListTile(
              leading: const Icon(Icons.snooze, color: Color(0xFFFF9000)),
              title: const Text('Вимкнути на 1 годину'),
              subtitle: const Text('Звукові тривоги призупиняться на 60 хв', style: TextStyle(fontSize: 11)),
              onTap: () async {
                await StorageService.setMuteOption('1hour');
                if (mounted) setState(() {});
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('🔕 Сповіщення призупинено на 1 годину')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.bedtime, color: Color(0xFF00E5FF)),
              title: const Text('Вимкнути на 1 день (24 год)'),
              subtitle: const Text('Без звуку на добу', style: TextStyle(fontSize: 11)),
              onTap: () async {
                await StorageService.setMuteOption('1day');
                if (mounted) setState(() {});
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('🔕 Сповіщення призупинено на 24 години')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off, color: Color(0xFFEF4444)),
              title: const Text('Вимкнути назавжди'),
              subtitle: const Text('До ручного увімкнення', style: TextStyle(fontSize: 11)),
              onTap: () async {
                await StorageService.setMuteOption('forever');
                if (mounted) setState(() {});
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('🔇 Сповіщення вимкнено назавжди')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSecretAdminPinDialog() {
    final DateTime? lockoutUntil = StorageService.getPinLockoutUntil();
    if (lockoutUntil != null) {
      final diff = lockoutUntil.difference(DateTime.now());
      final minutesLeft = diff.inMinutes + 1;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF281216),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.lock_clock, color: Color(0xFFEF4444)),
              SizedBox(width: 8),
              Text('Вхід заблоковано', style: TextStyle(color: Color(0xFFEF4444))),
            ],
          ),
          content: Text(
            'Через перевищення кількості невірних спроб вхід адміністратора заблоковано на $minutesLeft хв.\n\nЗачекайте закінчення таймера безпеки.',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Зрозуміло')),
          ],
        ),
      );
      return;
    }

    final pinCtrl = TextEditingController();
    bool isChecking = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final int failedAttempts = StorageService.getFailedPinAttempts();
          final int remaining = (3 - failedAttempts).clamp(0, 3);

          return AlertDialog(
            backgroundColor: const Color(0xFF182030),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.shield_outlined, color: Color(0xFFFF9000)),
                SizedBox(width: 8),
                Text('Авторизація', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  enabled: !isChecking,
                  decoration: InputDecoration(
                    labelText: 'Введіть PIN-код доступу',
                    filled: true,
                    prefixIcon: const Icon(Icons.password, color: Color(0xFFFF9000)),
                    suffixIcon: isChecking ? const SizedBox(width: 20, height: 20, child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF9000)))) : null,
                  ),
                ),
                if (failedAttempts > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '⚠️ Невірний PIN. Залишилось спроб: $remaining із 3.',
                    style: const TextStyle(color: Color(0xFFEF4444), fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isChecking ? null : () => Navigator.pop(context),
                child: const Text('Скасувати'),
              ),
              ElevatedButton(
                onPressed: isChecking
                    ? null
                    : () async {
                        final entered = pinCtrl.text.trim();
                        if (entered.isEmpty) return;

                        setDialogState(() => isChecking = true);
                        await Future.delayed(const Duration(milliseconds: 900));

                        if (entered == '196711') {
                          await StorageService.resetPinAttempts();
                          await StorageService.setAdmin(true);
                          if (mounted) {
                            setState(() {
                              _isAdmin = true;
                              _selectedProjectId = 'all';
                            });
                          }
                          _subscribeToProjects();
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('👑 Режим Адміністратора активовано!')),
                          );
                        } else {
                          await StorageService.recordFailedPinAttempt();
                          final nowLockout = StorageService.getPinLockoutUntil();

                          if (nowLockout != null) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Color(0xFFEF4444),
                                content: Text('🚫 3 невірні спроби! Доступ заблоковано на 15 хвилин.'),
                              ),
                            );
                          } else {
                            setDialogState(() => isChecking = false);
                            pinCtrl.clear();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Color(0xFFEF4444),
                                content: Text('❌ Невірний PIN-код!'),
                              ),
                            );
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF9000)),
                child: const Text('Увійти', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _logoutAdmin() async {
    await StorageService.setAdmin(false);
    setState(() {
      _isAdmin = false;
      _selectedProjectId = null;
    });
    _subscribeToProjects();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('👤 Ви вийшли з режиму Адміністратора')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unacknowledgedAlerts = _alerts.where((a) => !a.isAcknowledged).length;

    List<DryingProgram> displayPrograms = _programs;
    if (!_isAdmin && _selectedProjectId != null && _selectedProjectId != 'all') {
      final currentProj = _projects.where((p) => p.id == _selectedProjectId).firstOrNull;
      if (currentProj != null && currentProj.programIds.isNotEmpty) {
        displayPrograms = _programs.where((p) => currentProj.programIds.contains(p.id)).toList();
      }
    }

    final screens = [
      KilnsDashboardScreen(
        kilns: _kilns,
        programs: _programs,
        projects: _projects,
        selectedProjectId: _selectedProjectId,
        onSelectProject: _onSelectProject,
        isAdmin: _isAdmin,
        onRefresh: _loadAllData,
      ),
      ProgramsScreen(
        programs: displayPrograms,
        isAdmin: _isAdmin,
        onProgramsChanged: _loadAllData,
      ),
      AlertsScreen(
        alerts: _alerts,
        myAppId: _myAppId,
        onAlertsChanged: _loadAllData,
        onOpenMuteDialog: _showMuteOptionsDialog,
      ),
      SettingsScreen(
        kilns: _kilns,
        projects: _projects,
        programs: _programs,
        isAdmin: _isAdmin,
        onLogoutAdmin: _logoutAdmin,
        onTriggerSecretLogin: _showSecretAdminPinDialog,
        onOpenMuteDialog: _showMuteOptionsDialog,
        onProjectsChanged: () => _subscribeToProjects(),
        onKilnsChanged: _loadAllData,
      ),
    ];

    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
        },
        children: screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F131D),
          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.08))),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            HapticFeedback.lightImpact();
            setState(() => _currentIndex = index);
            _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
            );
          },
          backgroundColor: Colors.transparent,
          indicatorColor: const Color(0xFFFF9000).withOpacity(0.2),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.heat_pump_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.heat_pump, color: Color(0xFFFF9000)),
              label: 'Сушарки',
            ),
            const NavigationDestination(
              icon: Icon(Icons.menu_book_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.menu_book, color: Color(0xFFFF9000)),
              label: 'Програми',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: unacknowledgedAlerts > 0,
                label: Text('$unacknowledgedAlerts'),
                backgroundColor: const Color(0xFFEF4444),
                child: const Icon(Icons.notifications_active_outlined, color: Colors.white70),
              ),
              selectedIcon: const Icon(Icons.notifications_active, color: Color(0xFFFF9000)),
              label: 'Тривоги',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.settings, color: Color(0xFFFF9000)),
              label: 'Налаштування',
            ),
          ],
        ),
      ),
    );
  }
}

// ================= 1. KILNS DASHBOARD =================
class KilnsDashboardScreen extends StatelessWidget {
  final List<KilnDevice> kilns;
  final List<DryingProgram> programs;
  final List<Project> projects;
  final String? selectedProjectId;
  final ValueChanged<String?> onSelectProject;
  final bool isAdmin;
  final VoidCallback onRefresh;

  const KilnsDashboardScreen({
    super.key,
    required this.kilns,
    required this.programs,
    required this.projects,
    required this.selectedProjectId,
    required this.onSelectProject,
    required this.isAdmin,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    String currentProjName = 'Усі проєкти';
    if (selectedProjectId != null && selectedProjectId != 'all') {
      final p = projects.where((x) => x.id == selectedProjectId).firstOrNull;
      if (p != null) currentProjName = p.name;
    }

    final int onlineCount = kilns.where((k) => k.isOnline).length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'TimberDry Desktop',
                  style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                if (isAdmin) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFFF9000), borderRadius: BorderRadius.circular(5)),
                    child: const Text('ADMIN', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.black)),
                  ),
                ],
              ],
            ),
            if (projects.isNotEmpty || isAdmin)
              PopupMenuButton<String>(
                onSelected: onSelectProject,
                color: const Color(0xFF182030),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.business, size: 12, color: Color(0xFF00E5FF)),
                    const SizedBox(width: 4),
                    Text(
                      currentProjName,
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: const Color(0xFF00E5FF)),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF00E5FF)),
                  ],
                ),
                itemBuilder: (context) => [
                  if (isAdmin)
                    const PopupMenuItem(
                      value: 'all',
                      child: Text('🌐 Усі проєкти (Admin View)', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ...projects.map((proj) => PopupMenuItem(
                        value: proj.id,
                        child: Text('🏢 ${proj.name}'),
                      )),
                ],
              ),
          ],
        ),
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.bluetooth_searching, color: Color(0xFF00E5FF)),
              tooltip: 'Пошук та налаштування ESP32 через Bluetooth',
              onPressed: () {
                HapticFeedback.lightImpact();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const BleProvisioningScreen()),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () {
              HapticFeedback.lightImpact();
              onRefresh();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => onRefresh(),
        color: const Color(0xFFFF9000),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF182030), Color(0xFF111520)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildHeaderStat('Підключено плат', '$onlineCount / ${kilns.length}', const Color(0xFFFF9000), Icons.heat_pump),
                  Container(height: 36, width: 1, color: Colors.white12),
                  _buildHeaderStat('Проєкт', currentProjName, const Color(0xFF00E5FF), Icons.business),
                  Container(height: 36, width: 1, color: Colors.white12),
                  _buildHeaderStat('Хмара Firestore', 'Live Sync', const Color(0xFF10B981), Icons.cloud_done),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Датчики проєкту ($currentProjName)',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$onlineCount онлайн',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: onlineCount > 0 ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (kilns.isEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 20),
                alignment: Alignment.center,
                child: Column(
                  children: [
                    const Icon(Icons.sensors_off, size: 56, color: Colors.white24),
                    const SizedBox(height: 12),
                    Text(
                      projects.isEmpty && !isAdmin
                          ? 'Ваш пристрій ще не додано до жодного проєкту'
                          : 'У цьому проєкті немає призначених датчиків',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white70),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      !isAdmin
                          ? 'Надайте ваш App ID адміністратору для включення у проєкт сушильного комплексу.'
                          : 'Перейдіть у меню «Налаштування» ➔ «Керування проєктами».',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 12, color: Colors.white38),
                    ),
                  ],
                ),
              ),
            ] else ...[
              ...kilns.map((kiln) => _buildKilnCard(context, kiln)),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderStat(String label, String value, Color color, IconData icon) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 90),
              child: Text(
                value,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            color: Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildKilnCard(BuildContext context, KilnDevice kiln) {
    final session = kiln.activeSession;
    final bool isDrying = session != null && !session.isCompleted;

    DryingProgram? program;
    DryingStep? currentStep;
    double progress = 0.0;

    if (isDrying) {
      program = programs.firstWhere((p) => p.id == session.programId, orElse: () => programs.first);
      final (step, _, _) = EmcCalculator.getActiveStep(program, session.elapsedHours);
      currentStep = step;
      progress = (session.elapsedHours / program.totalDurationHours).clamp(0.0, 1.0);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF121622),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: !kiln.isOnline || !kiln.sensorConnected
              ? const Color(0xFFEF4444)
              : isDrying
                  ? const Color(0xFFFF9000).withOpacity(0.5)
                  : Colors.white.withOpacity(0.08),
          width: !kiln.isOnline || !kiln.sensorConnected ? 1.8 : (isDrying ? 1.5 : 1.0),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            HapticFeedback.lightImpact();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => KilnDetailScreen(
                  kiln: kiln,
                  programs: programs,
                  isAdmin: isAdmin,
                  onUpdate: onRefresh,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kiln.isOnline && kiln.sensorConnected ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          kiln.name,
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5FF).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
                      ),
                      child: Text(
                        '#${kiln.deviceId}',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF00E5FF),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                if (isDrying && program != null) ...[
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9000).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFF9000).withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '🔥 Сушіння: ${program.name}',
                              style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 12, color: const Color(0xFFFF9000)),
                            ),
                            Text(
                              '${(progress * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFFFF9000)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: Colors.white12,
                            valueColor: const AlwaysStoppedAnimation(Color(0xFFFF9000)),
                            minHeight: 4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                Row(
                  children: [
                    const Icon(Icons.timer_outlined, size: 13, color: Colors.white38),
                    const SizedBox(width: 4),
                    Text(
                      'Аптайм: ${kiln.uptimeFormatted}',
                      style: GoogleFonts.inter(fontSize: 11, color: Colors.white38),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.wifi, size: 13, color: Colors.white38),
                    const SizedBox(width: 4),
                    Text(
                      'IP: ${kiln.ipAddress}',
                      style: GoogleFonts.inter(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                if (!kiln.isOnline) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF381216),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFEF4444)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_off, color: Color(0xFFEF4444), size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '🚨 ПЛАТА НЕ НА ЗВ\'ЯЗКУ (OFFLINE)!',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (!kiln.sensorConnected) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF381216),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFEF4444)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '⚠️ ОБРИВ АБО ВІДКЛЮЧЕННЯ ДАТЧИКА (D15)!',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                Row(
                  children: [
                    Expanded(
                      child: _buildSensorBox(
                        title: 'ТЕМПЕРАТУРА',
                        value: kiln.isOnline && kiln.sensorConnected ? '${kiln.currentTemp.toStringAsFixed(1)}°C' : '--',
                        subValue: currentStep != null ? 'Ціль: ${currentStep.targetTemp.toStringAsFixed(0)}°C' : (kiln.isOnline ? 'Поточна' : 'Офлайн'),
                        color: const Color(0xFFFF9000),
                        icon: Icons.thermostat,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildSensorBox(
                        title: 'ВОЛОГІСТЬ RH',
                        value: kiln.isOnline && kiln.sensorConnected ? '${kiln.currentHumidity.toStringAsFixed(1)}%' : '--',
                        subValue: currentStep != null ? 'Ціль: ${currentStep.targetHumidity.toStringAsFixed(0)}%' : (kiln.isOnline ? 'Поточна' : 'Офлайн'),
                        color: const Color(0xFF00E5FF),
                        icon: Icons.water_drop,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildSensorBox(
                        title: 'РІВНОВАГА EMC',
                        value: kiln.isOnline && kiln.sensorConnected ? '${kiln.currentEmc.toStringAsFixed(1)}%' : '--',
                        subValue: 'Вологість дер.',
                        color: const Color(0xFF10B981),
                        icon: Icons.grass,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSensorBox({
    required String title,
    required String value,
    required String subValue,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 13),
              const SizedBox(width: 4),
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: color,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subValue,
            style: GoogleFonts.inter(
              fontSize: 10,
              color: Colors.white54,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ================= 2. KILN DETAIL & CHARTS =================
class KilnDetailScreen extends StatefulWidget {
  final KilnDevice kiln;
  final List<DryingProgram> programs;
  final bool isAdmin;
  final VoidCallback onUpdate;

  const KilnDetailScreen({
    super.key,
    required this.kiln,
    required this.programs,
    required this.isAdmin,
    required this.onUpdate,
  });

  @override
  State<KilnDetailScreen> createState() => _KilnDetailScreenState();
}

class _KilnDetailScreenState extends State<KilnDetailScreen> {
  int _chartTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final session = widget.kiln.activeSession;
    final bool isDrying = session != null && !session.isCompleted;

    DryingProgram? program;
    DryingStep? currentStep;
    double progress = 0.0;

    if (isDrying) {
      program = widget.programs.firstWhere((p) => p.id == session.programId, orElse: () => widget.programs.first);
      final (step, _, _) = EmcCalculator.getActiveStep(program, session.elapsedHours);
      currentStep = step;
      progress = (session.elapsedHours / program.totalDurationHours).clamp(0.0, 1.0);
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.kiln.name,
              style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            Text(
              'Апаратний ID: #${widget.kiln.deviceId}',
              style: GoogleFonts.jetBrainsMono(fontSize: 11, color: const Color(0xFF00E5FF)),
            ),
          ],
        ),
        actions: [
          if (widget.isAdmin)
            IconButton(
              icon: const Icon(Icons.edit, color: Color(0xFFFF9000)),
              tooltip: 'Перейменувати сушарку',
              onPressed: () => _showRenameDialog(),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDrying
                    ? [const Color(0xFF1E2838), const Color(0xFF121722)]
                    : [const Color(0xFF161A24), const Color(0xFF0E1118)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: isDrying ? const Color(0xFFFF9000).withOpacity(0.3) : Colors.white12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBigDial('ТЕМПЕРАТУРА', widget.kiln.isOnline ? '${widget.kiln.currentTemp.toStringAsFixed(1)}°C' : '--', const Color(0xFFFF9000)),
                Container(height: 50, width: 1, color: Colors.white10),
                _buildBigDial('ВОЛОГІСТЬ', widget.kiln.isOnline ? '${widget.kiln.currentHumidity.toStringAsFixed(1)}%' : '--', const Color(0xFF00E5FF)),
                Container(height: 50, width: 1, color: Colors.white10),
                _buildBigDial('EMC ДЕРЕВИНИ', widget.kiln.isOnline ? '${widget.kiln.currentEmc.toStringAsFixed(1)}%' : '--', const Color(0xFF10B981)),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (!isDrying) ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2E1C0C), Color(0xFF18120C)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFF9000).withOpacity(0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.local_fire_department, color: Color(0xFFFF9000), size: 24),
                      const SizedBox(width: 8),
                      Text('Контроль та сушіння деревини', style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Оберіть рецепт (Дуб, Сосна, Ясен або власний) для автоматичного ведення графіка температури, вологості та запису журналу.',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _showStartProgramDialog(),
                      icon: const Icon(Icons.play_arrow, color: Colors.black),
                      label: Text(
                        'ЗАПУСТИТИ ПРОГРАМУ СУШІННЯ',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w800, color: Colors.black),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9000),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E2838), Color(0xFF141926)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFF9000)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '🔥 Активна програма: ${program?.name ?? ""}',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 15, color: const Color(0xFFFF9000)),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFF10B981), borderRadius: BorderRadius.circular(8)),
                        child: const Text('У ПРОЦЕСІ', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.black)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (currentStep != null) ...[
                    Text('Поточний етап: ${currentStep.title}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      'Ціль: ${currentStep.targetTemp}°C (Зараз: ${widget.kiln.currentTemp.toStringAsFixed(1)}°C) • Вологість: ${currentStep.targetHumidity}% (Зараз: ${widget.kiln.currentHumidity.toStringAsFixed(1)}%)',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF00E5FF)),
                    ),
                  ],
                  const SizedBox(height: 12),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Прогрес: ${(progress * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 11, color: Colors.white70)),
                      Text('${session.elapsedHours.toStringAsFixed(1)} / ${program?.totalDurationHours.toStringAsFixed(0)} годин', style: const TextStyle(fontSize: 11, color: Colors.white70)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFFFF9000)),
                    ),
                  ),
                  const SizedBox(height: 16),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _stopDryingSession(),
                          icon: const Icon(Icons.stop, color: Color(0xFFEF4444)),
                          label: const Text('ЗАВЕРШИТИ СУШІННЯ', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFEF4444)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            _buildDryingChartsSection(session, program!),
          ],
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF131824),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Діагностика плати ESP32', style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 14)),
                const SizedBox(height: 12),
                _buildDiagRow('Апаратний ID', '#${widget.kiln.deviceId}'),
                _buildDiagRow('Локальна IP', widget.kiln.ipAddress),
                _buildDiagRow('Час роботи (Uptime)', widget.kiln.uptimeFormatted),
                _buildDiagRow('Статус сенсора', widget.kiln.isOnline ? widget.kiln.sensorStatus : 'OFFLINE', isGood: widget.kiln.isOnline && widget.kiln.sensorConnected),
                _buildDiagRow('Останній сигнал', '${widget.kiln.lastSeen.hour.toString().padLeft(2, '0')}:${widget.kiln.lastSeen.minute.toString().padLeft(2, '0')}:${widget.kiln.lastSeen.second.toString().padLeft(2, '0')}'),
                _buildDiagRow('Версія прошивки', widget.kiln.firmwareVersion),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildDryingChartsSection(DryingSession session, DryingProgram program) {
    double totalDuration = program.totalDurationHours;
    if (totalDuration <= 0) totalDuration = 24.0;

    List<FlSpot> planTempSpots = [];
    List<FlSpot> planHumSpots = [];
    List<FlSpot> planEmcSpots = [];

    double currH = 0.0;
    for (var step in program.steps) {
      double targetEmc = EmcCalculator.calculateEmc(step.targetTemp, step.targetHumidity);
      planTempSpots.add(FlSpot(currH, step.targetTemp));
      planHumSpots.add(FlSpot(currH, step.targetHumidity));
      planEmcSpots.add(FlSpot(currH, targetEmc));

      currH += step.durationHours;

      planTempSpots.add(FlSpot(currH, step.targetTemp));
      planHumSpots.add(FlSpot(currH, step.targetHumidity));
      planEmcSpots.add(FlSpot(currH, targetEmc));
    }

    List<FlSpot> factTempSpots = [];
    List<FlSpot> factHumSpots = [];
    List<FlSpot> factEmcSpots = [];

    if (session.history.isNotEmpty) {
      for (var point in session.history) {
        double elapsed = point.timestamp.difference(session.startTime).inMinutes / 60.0;
        if (elapsed < 0) elapsed = 0;
        factTempSpots.add(FlSpot(elapsed, point.temp));
        factHumSpots.add(FlSpot(elapsed, point.humidity));
        factEmcSpots.add(FlSpot(elapsed, point.emc));
      }
    } else {
      factTempSpots.add(FlSpot(session.elapsedHours, widget.kiln.currentTemp));
      factHumSpots.add(FlSpot(session.elapsedHours, widget.kiln.currentHumidity));
      factEmcSpots.add(FlSpot(session.elapsedHours, widget.kiln.currentEmc));
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131824),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '📈 Графік технологічного процесу',
                style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${session.history.length} записів',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildChartTabChip('📊 Усі разом', 0),
                const SizedBox(width: 6),
                _buildChartTabChip('🌡️ Температура', 1),
                const SizedBox(width: 6),
                _buildChartTabChip('💧 Вологість RH', 2),
                const SizedBox(width: 6),
                _buildChartTabChip('🪵 EMC Деревини', 3),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegendItem('---- План (Норма)', Colors.white38),
              const SizedBox(width: 14),
              if (_chartTabIndex == 0 || _chartTabIndex == 1) ...[
                _buildLegendItem('— Температура', const Color(0xFFFF9000)),
                const SizedBox(width: 10),
              ],
              if (_chartTabIndex == 0 || _chartTabIndex == 2) ...[
                _buildLegendItem('— Вологість', const Color(0xFF00E5FF)),
                const SizedBox(width: 10),
              ],
              if (_chartTabIndex == 0 || _chartTabIndex == 3) ...[
                _buildLegendItem('— EMC', const Color(0xFF10B981)),
              ],
            ],
          ),
          const SizedBox(height: 14),

          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: totalDuration,
                minY: 0,
                maxY: 100,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10, strokeWidth: 1),
                  getDrawingVerticalLine: (_) => FlLine(color: Colors.white10, strokeWidth: 1),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      getTitlesWidget: (val, meta) => Text(
                        '${val.toInt()}',
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: (totalDuration / 5).clamp(12.0, 96.0),
                      getTitlesWidget: (val, meta) => Text(
                        '${val.toInt()}г',
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ),
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: Colors.white12),
                ),
                lineBarsData: [
                  if (_chartTabIndex == 0 || _chartTabIndex == 1)
                    LineChartBarData(
                      spots: planTempSpots,
                      isCurved: false,
                      color: const Color(0xFFFF9000).withOpacity(0.35),
                      barWidth: 2,
                      dashArray: [5, 5],
                      dotData: const FlDotData(show: false),
                    ),
                  if (_chartTabIndex == 0 || _chartTabIndex == 2)
                    LineChartBarData(
                      spots: planHumSpots,
                      isCurved: false,
                      color: const Color(0xFF00E5FF).withOpacity(0.35),
                      barWidth: 2,
                      dashArray: [5, 5],
                      dotData: const FlDotData(show: false),
                    ),
                  if (_chartTabIndex == 0 || _chartTabIndex == 3)
                    LineChartBarData(
                      spots: planEmcSpots,
                      isCurved: false,
                      color: const Color(0xFF10B981).withOpacity(0.35),
                      barWidth: 2,
                      dashArray: [5, 5],
                      dotData: const FlDotData(show: false),
                    ),

                  if (_chartTabIndex == 0 || _chartTabIndex == 1)
                    LineChartBarData(
                      spots: factTempSpots,
                      isCurved: true,
                      color: const Color(0xFFFF9000),
                      barWidth: 3,
                      dotData: FlDotData(
                        show: factTempSpots.length < 30,
                        getDotPainter: (spot, percent, barData, index) =>
                            FlDotCirclePainter(radius: 3, color: const Color(0xFFFF9000), strokeColor: Colors.white, strokeWidth: 1),
                      ),
                    ),
                  if (_chartTabIndex == 0 || _chartTabIndex == 2)
                    LineChartBarData(
                      spots: factHumSpots,
                      isCurved: true,
                      color: const Color(0xFF00E5FF),
                      barWidth: 3,
                      dotData: FlDotData(
                        show: factHumSpots.length < 30,
                        getDotPainter: (spot, percent, barData, index) =>
                            FlDotCirclePainter(radius: 3, color: const Color(0xFF00E5FF), strokeColor: Colors.white, strokeWidth: 1),
                      ),
                    ),
                  if (_chartTabIndex == 0 || _chartTabIndex == 3)
                    LineChartBarData(
                      spots: factEmcSpots,
                      isCurved: true,
                      color: const Color(0xFF10B981),
                      barWidth: 3,
                      dotData: FlDotData(
                        show: factEmcSpots.length < 30,
                        getDotPainter: (spot, percent, barData, index) =>
                            FlDotCirclePainter(radius: 3, color: const Color(0xFF10B981), strokeColor: Colors.white, strokeWidth: 1),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Text(
            '💡 Шкала розрахована на весь технологічний цикл (${totalDuration.toStringAsFixed(0)} год). Записи фіксуються щохвилини під час активної сушки.',
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _buildChartTabChip(String label, int index) {
    final bool isSelected = _chartTabIndex == index;
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() => _chartTabIndex = index);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFF9000) : const Color(0xFF182030),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? const Color(0xFFFF9000) : Colors.white12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isSelected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Text(
      label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
    );
  }

  void _showStartProgramDialog() {
    DryingProgram selectedProg = widget.programs.first;
    final volumeCtrl = TextEditingController(text: '30');

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121622),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Запуск програми сушіння', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<DryingProgram>(
                    value: selectedProg,
                    decoration: const InputDecoration(labelText: 'Оберіть рецепт сушіння', filled: true),
                    items: widget.programs.map((p) {
                      return DropdownMenuItem(
                        value: p,
                        child: Text('${p.name} (${p.totalDays.toStringAsFixed(1)} дн)', overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setModalState(() => selectedProg = val);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: volumeCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Об\'єм штабелю лісу (м³)', filled: true),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final session = DryingSession(
                          id: 'session_${DateTime.now().millisecondsSinceEpoch}',
                          kilnId: widget.kiln.deviceId,
                          programId: selectedProg.id,
                          programName: selectedProg.name,
                          woodSpecies: selectedProg.woodSpecies,
                          woodThicknessMm: selectedProg.woodThicknessMm,
                          batchVolumeM3: double.tryParse(volumeCtrl.text) ?? 30.0,
                          startTime: DateTime.now(),
                        );
                        await FirebaseFirestore.instance.collection('devices').doc(widget.kiln.deviceId).set({
                          'activeSession': session.toJson(),
                        }, SetOptions(merge: true));

                        setState(() => widget.kiln.activeSession = session);
                        widget.onUpdate();
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('🔥 Програму "${selectedProg.name}" успішно запущено!')),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9000),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('РОЗПОЧАТИ СУШІННЯ', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
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

  void _stopDryingSession() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182030),
        title: const Text('Завершити процес сушіння?'),
        content: const Text('Програма буде зупинена, а сушарка перейде в режим очікування без запису телеметрії.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Ні, продовжити')),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance.collection('devices').doc(widget.kiln.deviceId).update({
                'activeSession': FieldValue.delete(),
              });
              setState(() => widget.kiln.activeSession = null);
              widget.onUpdate();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Так, завершити', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog() {
    final nameCtrl = TextEditingController(text: widget.kiln.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182030),
        title: const Text('Перейменувати сушарку'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Нова назва'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
          ElevatedButton(
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              if (newName.isNotEmpty) {
                await StorageService.updateDeviceLabel(widget.kiln.deviceId, newName);
                setState(() => widget.kiln.name = newName);
                widget.onUpdate();
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF9000)),
            child: const Text('Зберегти', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagRow(String label, String val, {bool isGood = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white60)),
          Text(
            val,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isGood ? Colors.white : const Color(0xFFEF4444),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBigDial(String title, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: color,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// ================= 3. PROGRAMS & RECIPE BUILDER =================
class ProgramsScreen extends StatefulWidget {
  final List<DryingProgram> programs;
  final bool isAdmin;
  final VoidCallback onProgramsChanged;

  const ProgramsScreen({
    super.key,
    required this.programs,
    required this.isAdmin,
    required this.onProgramsChanged,
  });

  @override
  State<ProgramsScreen> createState() => _ProgramsScreenState();
}

class _ProgramsScreenState extends State<ProgramsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Text(
          'Програми сушіння',
          style: GoogleFonts.inter(fontWeight: FontWeight.w800),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _openProgramBuilder(),
            icon: const Icon(Icons.add_circle, color: Color(0xFFFF9000)),
            label: const Text('Створити', style: TextStyle(color: Color(0xFFFF9000), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openProgramBuilder(),
        backgroundColor: const Color(0xFFFF9000),
        icon: const Icon(Icons.add, color: Colors.black),
        label: Text(
          'СТВОРИТИ ПРОГРАМУ',
          style: GoogleFonts.inter(fontWeight: FontWeight.w800, color: Colors.black, fontSize: 12),
        ),
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
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.tune, color: Color(0xFF00E5FF), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Технологічні карти сушіння', style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 14)),
                      const SizedBox(height: 2),
                      const Text(
                        'Створюйте власні рецепти з покроковим налаштуванням часу, температури та вологості.',
                        style: TextStyle(fontSize: 11, color: Colors.white60),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          ...widget.programs.map((program) => _buildProgramCard(program)),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildProgramCard(DryingProgram program) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131824),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: program.isCustom ? const Color(0xFFFF9000).withOpacity(0.5) : Colors.white.withOpacity(0.08),
          width: program.isCustom ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      program.name,
                      style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    if (program.isCustom) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF9000).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFFF9000).withOpacity(0.4)),
                        ),
                        child: const Text('ВЛАСНА', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFFFF9000))),
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy, color: Color(0xFF00E5FF), size: 18),
                    tooltip: 'Створити копію для редагування',
                    onPressed: () => _openProgramBuilder(templateProgram: program),
                  ),
                  if (program.isCustom) ...[
                    IconButton(
                      icon: const Icon(Icons.edit, color: Color(0xFFFF9000), size: 18),
                      tooltip: 'Редагувати програму',
                      onPressed: () => _openProgramBuilder(existingProgram: program),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444), size: 18),
                      tooltip: 'Видалити програму',
                      onPressed: () => _confirmDeleteProgram(program),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${program.woodSpecies} ${program.woodThicknessMm}мм • ${program.totalDays.toStringAsFixed(1)} діб (${program.totalDurationHours.toStringAsFixed(0)} год) • ${program.steps.length} етапів',
            style: const TextStyle(color: Color(0xFFFF9000), fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0D14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: program.steps.map((s) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF9000).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${s.stepNumber}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFFFF9000))),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.title,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      Text(
                        '${s.durationHours.toStringAsFixed(0)} год',
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${s.targetTemp.toStringAsFixed(0)}°C',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFFF9000)),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'RH ${s.targetHumidity.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF)),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteProgram(DryingProgram program) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182030),
        title: Text('Видалити «${program.name}»?'),
        content: const Text('Цю власну програму буде видалено з хмари та списку рецептів.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
          ElevatedButton(
            onPressed: () async {
              await StorageService.deleteCustomProgram(program.id);
              widget.onProgramsChanged();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Видалити', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _openProgramBuilder({DryingProgram? existingProgram, DryingProgram? templateProgram}) {
    final isEdit = existingProgram != null;
    final source = existingProgram ?? templateProgram;

    final nameCtrl = TextEditingController(text: isEdit ? source!.name : (templateProgram != null ? '${templateProgram.name} (Копія)' : 'Нова програма сушіння'));
    final speciesCtrl = TextEditingController(text: source?.woodSpecies ?? 'Дуб');
    final thicknessCtrl = TextEditingController(text: '${source?.woodThicknessMm ?? 50}');

    List<DryingStep> steps = source != null
        ? List.from(source.steps.map((s) => DryingStep(
              stepNumber: s.stepNumber,
              title: s.title,
              durationHours: s.durationHours,
              targetTemp: s.targetTemp,
              targetHumidity: s.targetHumidity,
              tempTolerance: s.tempTolerance,
              humidityTolerance: s.humidityTolerance,
              phaseType: s.phaseType,
              description: s.description,
            )))
        : [
            DryingStep(stepNumber: 1, title: 'Початковий прогрів', durationHours: 18, targetTemp: 40, targetHumidity: 90, phaseType: PhaseType.heating),
            DryingStep(stepNumber: 2, title: 'Основна сушка', durationHours: 72, targetTemp: 52, targetHumidity: 65, phaseType: PhaseType.mainDrying),
            DryingStep(stepNumber: 3, title: 'Досушування', durationHours: 36, targetTemp: 60, targetHumidity: 35, phaseType: PhaseType.mainDrying),
            DryingStep(stepNumber: 4, title: 'Охолодження', durationHours: 12, targetTemp: 30, targetHumidity: 60, phaseType: PhaseType.cooling),
          ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121622),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            double totalHours = steps.fold(0.0, (sumVal, s) => sumVal + s.durationHours);
            double totalDays = totalHours / 24.0;

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.88,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isEdit ? 'Редагування програми' : 'Конструктор програми',
                          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                      ],
                    ),
                    const SizedBox(height: 8),

                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Назва програми (напр. Дуб 50мм експортний)', filled: true),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: speciesCtrl,
                            decoration: const InputDecoration(labelText: 'Порода деревини', filled: true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: thicknessCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Товщина (мм)', filled: true),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF9000).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFF9000).withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Загальний час циклу:', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70)),
                          Text(
                            '${totalDays.toStringAsFixed(1)} діб (${totalHours.toStringAsFixed(0)} год)',
                            style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w900, color: const Color(0xFFFF9000)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Етапи сушіння (${steps.length}):', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        ElevatedButton.icon(
                          onPressed: () {
                            _openStepEditorDialog(
                              context: context,
                              stepNumber: steps.length + 1,
                              onSave: (newStep) {
                                setModalState(() => steps.add(newStep));
                              },
                            );
                          },
                          icon: const Icon(Icons.add, size: 16, color: Colors.black),
                          label: const Text('Додати етап', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF9000)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Expanded(
                      child: ListView.builder(
                        itemCount: steps.length,
                        itemBuilder: (context, index) {
                          final step = steps[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF182030),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white.withOpacity(0.06)),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: const Color(0xFFFF9000),
                                child: Text('${index + 1}', style: const TextStyle(fontSize: 11, color: Colors.black, fontWeight: FontWeight.bold)),
                              ),
                              title: Text(step.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              subtitle: Text(
                                '⏳ ${step.durationHours.toStringAsFixed(0)} год  •  🌡️ ${step.targetTemp.toStringAsFixed(0)}°C  •  💧 ${step.targetHumidity.toStringAsFixed(0)}% RH',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF00E5FF), fontWeight: FontWeight.w600),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20, color: Color(0xFFFF9000)),
                                    tooltip: 'Редагувати параметри етапу',
                                    onPressed: () {
                                      _openStepEditorDialog(
                                        context: context,
                                        existingStep: step,
                                        stepNumber: index + 1,
                                        onSave: (updatedStep) {
                                          setModalState(() => steps[index] = updatedStep);
                                        },
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFEF4444)),
                                    onPressed: () {
                                      setModalState(() {
                                        steps.removeAt(index);
                                        for (int i = 0; i < steps.length; i++) {
                                          steps[i] = DryingStep(
                                            stepNumber: i + 1,
                                            title: steps[i].title,
                                            durationHours: steps[i].durationHours,
                                            targetTemp: steps[i].targetTemp,
                                            targetHumidity: steps[i].targetHumidity,
                                            tempTolerance: steps[i].tempTolerance,
                                            humidityTolerance: steps[i].humidityTolerance,
                                            phaseType: steps[i].phaseType,
                                            description: steps[i].description,
                                          );
                                        }
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          final name = nameCtrl.text.trim();
                          if (name.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Введіть назву програми!')));
                            return;
                          }
                          if (steps.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Додайте хоча б один етап!')));
                            return;
                          }

                          final prog = DryingProgram(
                            id: isEdit ? source!.id : 'custom_${DateTime.now().millisecondsSinceEpoch}',
                            name: name,
                            woodSpecies: speciesCtrl.text.trim(),
                            woodThicknessMm: int.tryParse(thicknessCtrl.text) ?? 50,
                            isCustom: true,
                            steps: steps,
                          );
                          await StorageService.saveCustomProgram(prog);
                          widget.onProgramsChanged();
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('✅ Програму "$name" успішно збережено!')),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF9000),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          isEdit ? 'ЗБЕРЕГТИ ЗМІНИ' : 'ЗБЕРЕГТИ ПРОГРАМУ',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w800, color: Colors.black),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openStepEditorDialog({
    required BuildContext context,
    DryingStep? existingStep,
    required int stepNumber,
    required ValueChanged<DryingStep> onSave,
  }) {
    final titleCtrl = TextEditingController(text: existingStep?.title ?? 'Етап $stepNumber');
    final durationCtrl = TextEditingController(text: '${existingStep?.durationHours.toInt() ?? 24}');
    final tempCtrl = TextEditingController(text: '${existingStep?.targetTemp.toInt() ?? 50}');
    final humCtrl = TextEditingController(text: '${existingStep?.targetHumidity.toInt() ?? 60}');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.edit_calendar, color: Color(0xFFFF9000)),
            const SizedBox(width: 8),
            Text(existingStep == null ? 'Новий етап сушіння' : 'Редагування етапу #$stepNumber', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'Назва етапу (напр. Прогрів, Сушка 1)', filled: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: durationCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Тривалість етапу (годин)',
                  prefixIcon: Icon(Icons.timer_outlined, color: Color(0xFFFF9000)),
                  filled: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tempCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Цільова температура (°C)',
                  prefixIcon: Icon(Icons.thermostat, color: Color(0xFFFF9000)),
                  filled: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: humCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Цільова вологість повітря RH (%)',
                  prefixIcon: Icon(Icons.water_drop, color: Color(0xFF00E5FF)),
                  filled: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
          ElevatedButton(
            onPressed: () {
              final title = titleCtrl.text.trim();
              final dur = double.tryParse(durationCtrl.text) ?? 24.0;
              final temp = double.tryParse(tempCtrl.text) ?? 50.0;
              final hum = double.tryParse(humCtrl.text) ?? 60.0;

              final step = DryingStep(
                stepNumber: stepNumber,
                title: title.isNotEmpty ? title : 'Етап $stepNumber',
                durationHours: dur,
                targetTemp: temp,
                targetHumidity: hum,
              );

              onSave(step);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF9000)),
            child: const Text('Зберегти етап', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

// ================= 4. ALERTS SCREEN (WITH PROJECT ISOLATION) =================
class AlertsScreen extends StatelessWidget {
  final List<AlertItem> alerts;
  final String myAppId;
  final VoidCallback onAlertsChanged;
  final VoidCallback onOpenMuteDialog;

  const AlertsScreen({
    super.key,
    required this.alerts,
    required this.myAppId,
    required this.onAlertsChanged,
    required this.onOpenMuteDialog,
  });

  @override
  Widget build(BuildContext context) {
    final bool isMuted = StorageService.isNotificationsMuted();
    final String muteStatus = StorageService.getMuteStatusText();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Text('Журнал тривог', style: GoogleFonts.inter(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: Icon(isMuted ? Icons.notifications_off : Icons.notifications_active, color: isMuted ? const Color(0xFFEF4444) : const Color(0xFF10B981)),
            tooltip: 'Налаштування режиму звукових сповіщень',
            onPressed: onOpenMuteDialog,
          ),
          if (alerts.isNotEmpty) ...[
            TextButton.icon(
              onPressed: () async {
                await StorageService.dismissAllAlertsForClient(myAppId);
                onAlertsChanged();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('🗑️ Усі тривоги приховано для вашого пристрою')),
                );
              },
              icon: const Icon(Icons.clear_all, color: Color(0xFFFF9000), size: 18),
              label: const Text('Очистити у себе', style: TextStyle(color: Color(0xFFFF9000))),
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          // Snooze / Mute Status Tile
          InkWell(
            onTap: onOpenMuteDialog,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isMuted ? const Color(0xFF381216) : const Color(0xFF131824),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isMuted ? const Color(0xFFEF4444) : Colors.white12),
              ),
              child: Row(
                children: [
                  Icon(
                    isMuted ? Icons.notifications_paused : Icons.volume_up,
                    color: isMuted ? const Color(0xFFEF4444) : const Color(0xFFFF9000),
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Звукові сповіщення: $muteStatus',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isMuted ? 'Натисніть для зміни режиму або увімкнення' : 'Натисніть, щоб вимкнути на 1 год / 1 день / назавжди',
                          style: const TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white38),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          if (alerts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_outline, size: 56, color: Color(0xFF10B981)),
                    const SizedBox(height: 12),
                    Text(
                      'Всі параметри в нормі!',
                      style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
                    ),
                    const SizedBox(height: 4),
                    const Text('Активних або непрочитаних тривог для ваших камер немає.', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            )
          else
            ...alerts.map((a) {
              final bool isCritical = a.severity == 'critical';

              return Dismissible(
                key: Key(a.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(Icons.delete_outline, color: Colors.white),
                      SizedBox(width: 6),
                      Text('Видалити у себе', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                onDismissed: (_) async {
                  await StorageService.dismissAlertForClient(a.id, myAppId);
                  onAlertsChanged();
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131824),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isCritical ? const Color(0xFFEF4444).withOpacity(0.8) : const Color(0xFFFF9000).withOpacity(0.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isCritical ? Icons.error_outline : Icons.warning_amber_rounded,
                            color: isCritical ? const Color(0xFFEF4444) : const Color(0xFFFF9000),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              a.title,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: isCritical ? const Color(0xFFEF4444) : const Color(0xFFFF9000),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 20),
                            tooltip: 'Видалити тільки у себе',
                            onPressed: () async {
                              await StorageService.dismissAlertForClient(a.id, myAppId);
                              onAlertsChanged();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('🗑️ Сповіщення приховано на вашому пристрої')),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(a.message, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Камера: ${a.kilnName}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF)),
                          ),
                          Text(
                            '${a.timestamp.day.toString().padLeft(2, '0')}.${a.timestamp.month.toString().padLeft(2, '0')} ${a.timestamp.hour.toString().padLeft(2, '0')}:${a.timestamp.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(fontSize: 11, color: Colors.white38),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ================= 5. SETTINGS SCREEN =================
class SettingsScreen extends StatefulWidget {
  final List<KilnDevice> kilns;
  final List<Project> projects;
  final List<DryingProgram> programs;
  final bool isAdmin;
  final VoidCallback onLogoutAdmin;
  final VoidCallback onTriggerSecretLogin;
  final VoidCallback onOpenMuteDialog;
  final VoidCallback onProjectsChanged;
  final VoidCallback onKilnsChanged;

  const SettingsScreen({
    super.key,
    required this.kilns,
    required this.projects,
    required this.programs,
    required this.isAdmin,
    required this.onLogoutAdmin,
    required this.onTriggerSecretLogin,
    required this.onOpenMuteDialog,
    required this.onProjectsChanged,
    required this.onKilnsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _appInstanceId = 'Завантаження...';
  int _secretTapCount = 0;
  DateTime _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadAppId();
  }

  Future<void> _loadAppId() async {
    final id = await AppIdentityService.getAppInstanceId();
    if (mounted) setState(() => _appInstanceId = id);
  }

  void _handleSecretTap() {
    if (widget.isAdmin) return;

    final now = DateTime.now();
    if (now.difference(_lastTapTime).inSeconds > 2) {
      _secretTapCount = 1;
    } else {
      _secretTapCount++;
    }
    _lastTapTime = now;

    if (_secretTapCount >= 5) {
      _secretTapCount = 0;
      HapticFeedback.heavyImpact();
      widget.onTriggerSecretLogin();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isMuted = StorageService.isNotificationsMuted();
    final String muteStatus = StorageService.getMuteStatusText();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Text(
          widget.isAdmin ? 'Налаштування та Проєкти' : 'Налаштування',
          style: GoogleFonts.inter(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (widget.isAdmin)
            TextButton.icon(
              onPressed: widget.onLogoutAdmin,
              icon: const Icon(Icons.logout, color: Color(0xFFEF4444), size: 16),
              label: const Text('Вийти з Admin', style: TextStyle(color: Color(0xFFEF4444), fontSize: 11)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Mute Notifications Selector Card
          InkWell(
            onTap: widget.onOpenMuteDialog,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isMuted ? const Color(0xFF381216) : const Color(0xFF131824),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isMuted ? const Color(0xFFEF4444) : Colors.white12),
              ),
              child: Row(
                children: [
                  Icon(
                    isMuted ? Icons.notifications_paused : Icons.notifications_active,
                    color: isMuted ? const Color(0xFFEF4444) : const Color(0xFFFF9000),
                    size: 28,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Режим звукових тривог', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800)),
                        Text(
                          'Статус: $muteStatus (1 год / 1 день / назавжди)',
                          style: const TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white38),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // App ID Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E2838), Color(0xFF121722)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.fingerprint, color: Color(0xFF00E5FF), size: 24),
                        const SizedBox(width: 8),
                        Text(
                          'Ваш ID Застосунку (App ID)',
                          style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, color: Color(0xFF00E5FF), size: 20),
                      tooltip: 'Скопіювати ID для адміністратора',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _appInstanceId));
                        HapticFeedback.lightImpact();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('📋 ID застосунку скопійовано в буфер обміну!')),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _appInstanceId,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF00E5FF),
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Надайте цей ідентифікатор адміністратору, щоб включити ваш пристрій до проєкту сушильного комплексу.',
                  style: GoogleFonts.inter(fontSize: 11, color: Colors.white60),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Admin-Only Sections (Hidden for standard users)
          if (widget.isAdmin) ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2E1C0C), Color(0xFF18120C)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFF9000).withOpacity(0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.settings_input_antenna, color: Color(0xFFFF9000), size: 24),
                      const SizedBox(width: 8),
                      Text('Налаштування плати ESP32', style: GoogleFonts.inter(fontWeight: FontWeight.w800, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Пошук нової плати через Bluetooth, зміна Wi-Fi пароля, конфігурація PIN або прив\'язка до комплексу.',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const BleProvisioningScreen()),
                        );
                      },
                      icon: const Icon(Icons.bluetooth_searching, color: Colors.black),
                      label: Text(
                        'ШУКАТИ ТА НАЛАШТУВАТИ ESP32 ПО BLE',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w800, color: Colors.black),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9000),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Керування Проєктами (${widget.projects.length})',
                  style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: const Color(0xFFFF9000)),
                ),
                ElevatedButton.icon(
                  onPressed: () => _openProjectEditorModal(),
                  icon: const Icon(Icons.add, size: 16, color: Colors.black),
                  label: const Text('Створити Проєкт', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF9000)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (widget.projects.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: const Color(0xFF131824), borderRadius: BorderRadius.circular(16)),
                child: const Text('Проєктів ще не створено. Натисніть «Створити Проєкт», щоб згрупувати датчики та користувачів.', style: TextStyle(fontSize: 12, color: Colors.white54)),
              )
            else
              ...widget.projects.map((proj) => _buildProjectCard(proj)),
            const SizedBox(height: 24),

            Text(
              'Зареєстровані датчики ESP32 (${widget.kilns.length})',
              style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            ...widget.kilns.map((k) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131824),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: ListTile(
                    leading: Icon(
                      k.isOnline && k.sensorConnected ? Icons.sensors : Icons.sensors_off,
                      color: k.isOnline && k.sensorConnected ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                    ),
                    title: Text(k.name, style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      'ID: #${k.deviceId} • IP: ${k.ipAddress} • ${k.isOnline ? "Онлайн" : "ОФЛАЙН"} • Останній сигнал: ${k.lastSeen.hour.toString().padLeft(2, '0')}:${k.lastSeen.minute.toString().padLeft(2, '0')}:${k.lastSeen.second.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 11, color: k.isOnline ? Colors.white54 : const Color(0xFFEF4444)),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444)),
                      tooltip: 'Видалити плату з хмари',
                      onPressed: () => _confirmDeleteKiln(k),
                    ),
                  ),
                )),
            const SizedBox(height: 24),
          ],

          // App Info & Secret Easter Egg Tap Trigger
          GestureDetector(
            onTap: _handleSecretTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 24),
              alignment: Alignment.center,
              child: Column(
                children: [
                  const Icon(Icons.forest_outlined, color: Colors.white24, size: 28),
                  const SizedBox(height: 6),
                  Text(
                    'TimberDry Pro v${UpdateService.currentVersion}',
                    style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white38),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Промисловий контроль сушіння деревини',
                    style: TextStyle(fontSize: 10, color: Colors.white24),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => UpdateService.checkAndShowUpdateDialog(context, isManualCheck: true),
                    icon: const Icon(Icons.sync_rounded, size: 16, color: Color(0xFF00E5FF)),
                    label: Text(
                      'Перевірити оновлення',
                      style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF00E5FF)),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0x3300E5FF)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  void _confirmDeleteKiln(KilnDevice k) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182030),
        title: Text('Видалити #${k.deviceId}?'),
        content: Text('Плата «${k.name}» буде видалена з бази даних Firestore.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance.collection('devices').doc(k.deviceId).delete();
              widget.onKilnsChanged();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Видалити', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectCard(Project proj) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131824),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  proj.name,
                  style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Color(0xFFFF9000), size: 18),
                    onPressed: () => _openProjectEditorModal(existingProject: proj),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444), size: 18),
                    onPressed: () async {
                      await StorageService.deleteProject(proj.id);
                      widget.onProjectsChanged();
                    },
                  ),
                ],
              ),
            ],
          ),
          if (proj.description.isNotEmpty) ...[
            Text(proj.description, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              _buildBadge('📡 ${proj.deviceIds.length} датчиків', const Color(0xFFFF9000)),
              const SizedBox(width: 8),
              _buildBadge('👥 ${proj.memberAppIds.length} користувачів', const Color(0xFF00E5FF)),
              const SizedBox(width: 8),
              _buildBadge('📋 ${proj.programIds.length} рецептів', const Color(0xFF10B981)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.3))),
      child: Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }

  void _openProjectEditorModal({Project? existingProject}) {
    final nameCtrl = TextEditingController(text: existingProject?.name ?? '');
    final descCtrl = TextEditingController(text: existingProject?.description ?? '');

    List<String> selectedDeviceIds = List.from(existingProject?.deviceIds ?? []);
    List<String> selectedMemberIds = List.from(existingProject?.memberAppIds ?? []);
    List<String> selectedProgramIds = List.from(existingProject?.programIds ?? []);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121622),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
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
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.85,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          existingProject == null ? 'Створення Проєкту' : 'Редагування Проєкту',
                          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Назва проєкту (напр. Сушильний комплекс №1)', filled: true),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(labelText: 'Опис або локація (напр. Пилорама Львів)', filled: true),
                    ),
                    const SizedBox(height: 14),

                    Expanded(
                      child: ListView(
                        children: [
                          Text('1. Виберіть датчики ESP32 для проєкту:', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13, color: const Color(0xFFFF9000))),
                          const SizedBox(height: 4),
                          if (widget.kilns.isEmpty)
                            const Text('Немає підключених плат', style: TextStyle(fontSize: 11, color: Colors.white38))
                          else
                            ...widget.kilns.map((k) => CheckboxListTile(
                                  dense: true,
                                  title: Text('${k.name} (#${k.deviceId})', style: const TextStyle(fontSize: 13)),
                                  value: selectedDeviceIds.contains(k.deviceId),
                                  activeColor: const Color(0xFFFF9000),
                                  onChanged: (val) {
                                    setModalState(() {
                                      if (val == true) {
                                        selectedDeviceIds.add(k.deviceId);
                                      } else {
                                        selectedDeviceIds.remove(k.deviceId);
                                      }
                                    });
                                  },
                                )),
                          const SizedBox(height: 14),

                          Text('2. Виберіть користувачів (App ID):', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13, color: const Color(0xFF00E5FF))),
                          const SizedBox(height: 4),
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: StorageService.getAppBindingsStream(),
                            builder: (context, snapshot) {
                              final users = snapshot.data ?? [];
                              if (users.isEmpty) {
                                return const Text('Немає зареєстрованих клієнтів', style: TextStyle(fontSize: 11, color: Colors.white38));
                              }
                              return Column(
                                children: users.map((u) {
                                  final appId = u['appInstanceId'] ?? u['docId'];
                                  return CheckboxListTile(
                                    dense: true,
                                    title: Text('👤 $appId', style: GoogleFonts.jetBrainsMono(fontSize: 12)),
                                    value: selectedMemberIds.contains(appId),
                                    activeColor: const Color(0xFF00E5FF),
                                    onChanged: (val) {
                                      setModalState(() {
                                        if (val == true) {
                                          selectedMemberIds.add(appId);
                                        } else {
                                          selectedMemberIds.remove(appId);
                                        }
                                      });
                                    },
                                  );
                                }).toList(),
                              );
                            },
                          ),
                          const SizedBox(height: 14),

                          Text('3. Виберіть програми сушіння для проєкту:', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13, color: const Color(0xFF10B981))),
                          const SizedBox(height: 4),
                          ...widget.programs.map((p) => CheckboxListTile(
                                dense: true,
                                title: Text(p.name, style: const TextStyle(fontSize: 13)),
                                subtitle: Text('${p.woodSpecies} ${p.woodThicknessMm}мм', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                                value: selectedProgramIds.contains(p.id),
                                activeColor: const Color(0xFF10B981),
                                onChanged: (val) {
                                  setModalState(() {
                                    if (val == true) {
                                      selectedProgramIds.add(p.id);
                                    } else {
                                      selectedProgramIds.remove(p.id);
                                    }
                                  });
                                },
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          final name = nameCtrl.text.trim();
                          if (name.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Введіть назву проєкту!')));
                            return;
                          }

                          final proj = Project(
                            id: existingProject?.id ?? 'proj_${DateTime.now().millisecondsSinceEpoch}',
                            name: name,
                            description: descCtrl.text.trim(),
                            deviceIds: selectedDeviceIds,
                            memberAppIds: selectedMemberIds,
                            programIds: selectedProgramIds,
                          );

                          await StorageService.saveProject(proj);
                          widget.onProjectsChanged();
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Проєкт успішно збережено!')));
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF9000),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          existingProject == null ? 'СТВОРИТИ ПРОЄКТ' : 'ЗБЕРЕГТИ ЗМІНИ',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w800, color: Colors.black),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
