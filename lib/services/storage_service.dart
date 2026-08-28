import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/drying_models.dart';
import 'emc_calculator.dart';
import 'app_identity_service.dart';

class StorageService {
  static const String keyKilns = 'timber_dry_kilns_pure_v5';
  static const String keyPrograms = 'timber_dry_custom_programs';
  static const String keyAlerts = 'timber_dry_alerts';
  static const String keyIsAdmin = 'timber_dry_is_admin';
  static const String keySelectedProjectId = 'timber_dry_selected_project_id';
  static const String keyMuteUntil = 'timber_dry_mute_until';
  static const String keyMutePermanent = 'timber_dry_mute_permanent';
  static const String keyFailedPinAttempts = 'timber_dry_failed_pin_attempts';
  static const String keyPinLockoutUntil = 'timber_dry_pin_lockout_until';

  static SharedPreferences? _prefs;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ================= ANTI-BRUTE-FORCE PIN SECURITY =================
  static int getFailedPinAttempts() {
    return _prefs?.getInt(keyFailedPinAttempts) ?? 0;
  }

  static DateTime? getPinLockoutUntil() {
    final String? str = _prefs?.getString(keyPinLockoutUntil);
    if (str == null) return null;
    final dt = DateTime.tryParse(str);
    if (dt != null && DateTime.now().isBefore(dt)) return dt;
    return null;
  }

  static Future<void> recordFailedPinAttempt() async {
    if (_prefs == null) return;
    int attempts = getFailedPinAttempts() + 1;
    await _prefs!.setInt(keyFailedPinAttempts, attempts);

    if (attempts >= 3) {
      final lockout = DateTime.now().add(const Duration(minutes: 15));
      await _prefs!.setString(keyPinLockoutUntil, lockout.toIso8601String());
    }
  }

  static Future<void> resetPinAttempts() async {
    await _prefs?.remove(keyFailedPinAttempts);
    await _prefs?.remove(keyPinLockoutUntil);
  }

  // ================= NOTIFICATION MUTE / SNOOZE =================
  static bool isNotificationsMuted() {
    if (_prefs == null) return false;
    final bool permanent = _prefs!.getBool(keyMutePermanent) ?? false;
    if (permanent) return true;

    final String? untilStr = _prefs!.getString(keyMuteUntil);
    if (untilStr != null) {
      final until = DateTime.tryParse(untilStr);
      if (until != null && DateTime.now().isBefore(until)) {
        return true;
      }
    }
    return false;
  }

  static String getMuteStatusText() {
    if (_prefs == null) return 'Увімкнено';
    final bool permanent = _prefs!.getBool(keyMutePermanent) ?? false;
    if (permanent) return 'Вимкнено назавжди';

    final String? untilStr = _prefs!.getString(keyMuteUntil);
    if (untilStr != null) {
      final until = DateTime.tryParse(untilStr);
      if (until != null && DateTime.now().isBefore(until)) {
        final diff = until.difference(DateTime.now());
        if (diff.inHours > 0) {
          return 'Призупинено ще на ${diff.inHours} год ${diff.inMinutes % 60} хв';
        } else {
          return 'Призупинено ще на ${diff.inMinutes} хв';
        }
      }
    }
    return 'Увімкнено';
  }

  static Future<void> setMuteOption(String option) async {
    if (_prefs == null) return;
    final now = DateTime.now();

    if (option == '1hour') {
      await _prefs!.setBool(keyMutePermanent, false);
      await _prefs!.setString(keyMuteUntil, now.add(const Duration(hours: 1)).toIso8601String());
    } else if (option == '1day') {
      await _prefs!.setBool(keyMutePermanent, false);
      await _prefs!.setString(keyMuteUntil, now.add(const Duration(days: 1)).toIso8601String());
    } else if (option == 'forever') {
      await _prefs!.setBool(keyMutePermanent, true);
      await _prefs!.remove(keyMuteUntil);
    } else {
      await _prefs!.setBool(keyMutePermanent, false);
      await _prefs!.remove(keyMuteUntil);
    }
  }

  // ================= ADMIN ROLE =================
  static bool isAdmin() {
    return _prefs?.getBool(keyIsAdmin) ?? false;
  }

  static Future<void> setAdmin(bool value) async {
    await _prefs?.setBool(keyIsAdmin, value);
  }

  // ================= PROJECT MANAGEMENT =================
  static String? getSelectedProjectId() {
    return _prefs?.getString(keySelectedProjectId);
  }

  static Future<void> setSelectedProjectId(String? id) async {
    if (id == null) {
      await _prefs?.remove(keySelectedProjectId);
    } else {
      await _prefs?.setString(keySelectedProjectId, id);
    }
  }

  static Stream<List<Project>> getProjectsStream({required bool isAdminMode}) async* {
    final appId = await AppIdentityService.getAppInstanceId();

    yield* _firestore.collection('projects').snapshots().map((snapshot) {
      final all = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return Project.fromJson(data);
      }).toList();

      if (isAdminMode) {
        return all;
      } else {
        return all.where((p) => p.memberAppIds.contains(appId)).toList();
      }
    });
  }

  static Future<void> saveProject(Project project) async {
    await _firestore.collection('projects').doc(project.id).set(project.toJson(), SetOptions(merge: true));
  }

  static Future<void> deleteProject(String projectId) async {
    await _firestore.collection('projects').doc(projectId).delete();
  }

  // ================= FIRESTORE /devices REAL-TIME STREAM =================
  static Stream<List<KilnDevice>> getDevicesStream({
    required bool isAdminMode,
    String? selectedProjectId,
    List<Project>? userProjects,
  }) async* {
    yield* _firestore.collection('devices').snapshots().map((snapshot) {
      final filteredDocs = snapshot.docs.where((doc) {
        final id = doc.id;
        return id != 'TD8A4B2C' && id != 'TD9C3E1A' && id != 'TD4F7D8B' && id != 'kiln_01' && id != 'kiln_02';
      }).toList();

      final nowUtc = DateTime.now().toUtc();

      final allDevices = filteredDocs.map((doc) {
        final data = doc.data();
        double temp = (data['currentTemp'] ?? data['temp'] ?? 20.0).toDouble();
        double hum = (data['currentHumidity'] ?? data['humidity'] ?? 50.0).toDouble();
        double emc = (data['currentEmc'] ?? EmcCalculator.calculateEmc(temp, hum)).toDouble();
        bool sensorConnected = data['sensorConnected'] ?? true;
        String sensorStatus = data['sensorStatus'] ?? (sensorConnected ? 'OK' : 'DISCONNECTED');
        int uptimeSec = (data['uptimeSeconds'] ?? data['uptime'] ?? 0).toInt();
        int bootCnt = (data['bootCount'] ?? 1).toInt();
        int rssi = (data['rssi'] ?? -60).toInt();
        String ip = data['ipAddress'] ?? data['ip'] ?? '192.168.1.150';
        String ssid = data['wifiSsid'] ?? '';

        DateTime lastSeenUtc = nowUtc;
        if (data['lastSeen'] != null) {
          if (data['lastSeen'] is Timestamp) {
            lastSeenUtc = (data['lastSeen'] as Timestamp).toDate().toUtc();
          } else if (data['lastSeen'] is String) {
            lastSeenUtc = DateTime.tryParse(data['lastSeen'])?.toUtc() ?? nowUtc;
          }
        } else if (data['lastSeenEpoch'] != null) {
          int epoch = (data['lastSeenEpoch'] as num).toInt();
          if (epoch > 1000000) {
            lastSeenUtc = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
          }
        }

        // If ESP32 reports online flag and sent telemetry recently
        final int silenceSeconds = nowUtc.difference(lastSeenUtc).inSeconds;
        final bool rawOnline = data['isOnline'] == true;
        final bool isOnline = (silenceSeconds <= 45 && silenceSeconds >= -10) || (rawOnline && silenceSeconds <= 120);

        return KilnDevice(
          id: doc.id,
          deviceId: data['deviceId'] ?? doc.id,
          name: data['label'] ?? data['name'] ?? 'Сушарка #${doc.id}',
          location: data['location'] ?? (ssid.isNotEmpty ? 'Wi-Fi: $ssid' : 'Цех №1'),
          ipAddress: ip,
          currentTemp: temp,
          currentHumidity: hum,
          currentEmc: emc,
          lastSeen: lastSeenUtc.toLocal(),
          isOnline: isOnline,
          sensorConnected: isOnline ? sensorConnected : false,
          sensorStatus: isOnline ? sensorStatus : 'OFFLINE',
          uptimeSeconds: uptimeSec,
          bootCount: bootCnt,
          rssi: rssi,
          firmwareVersion: data['firmwareVersion'] ?? '1.7.3',
          activeSession: data['activeSession'] != null ? DryingSession.fromJson(data['activeSession']) : null,
        );
      }).toList();

      if (isAdminMode && (selectedProjectId == null || selectedProjectId == 'all')) {
        return allDevices;
      }

      if (userProjects == null || userProjects.isEmpty) {
        return <KilnDevice>[];
      }

      Set<String> allowedDeviceIds = {};
      if (selectedProjectId != null && selectedProjectId != 'all') {
        final targetProj = userProjects.firstWhere((p) => p.id == selectedProjectId, orElse: () => userProjects.first);
        allowedDeviceIds.addAll(targetProj.deviceIds);
      } else {
        for (var p in userProjects) {
          allowedDeviceIds.addAll(p.deviceIds);
        }
      }

      return allDevices.where((d) => allowedDeviceIds.contains(d.deviceId)).toList();
    });
  }

  // ================= DRYING TELEMETRY LOGGING =================
  static Future<void> logTelemetryPoint(String deviceId, DryingSession session, TelemetryPoint point) async {
    try {
      final docRef = _firestore.collection('devices').doc(deviceId);
      
      final updatedHistory = List<TelemetryPoint>.from(session.history)..add(point);
      if (updatedHistory.length > 500) {
        updatedHistory.removeRange(0, updatedHistory.length - 500);
      }

      final sessionMap = session.toJson();
      sessionMap['history'] = updatedHistory.map((h) => h.toJson()).toList();

      await docRef.set({
        'activeSession': sessionMap,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // ================= CLIENT REGISTRATION =================
  static Future<void> registerAppInstance() async {
    try {
      final appId = await AppIdentityService.getAppInstanceId();
      await _firestore.collection('device_bindings').doc(appId).set({
        'appInstanceId': appId,
        'lastActive': FieldValue.serverTimestamp(),
        'platform': 'flutter_client',
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Stream<List<Map<String, dynamic>>> getAppBindingsStream() {
    return _firestore.collection('device_bindings').snapshots().map((snapshot) {
      return snapshot.docs.map((d) {
        final data = d.data();
        data['docId'] = d.id;
        return data;
      }).toList();
    });
  }

  static Future<void> updateDeviceLabel(String deviceId, String newLabel) async {
    try {
      await _firestore.collection('devices').doc(deviceId).set({
        'label': newLabel,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // ================= PROGRAMS =================
  static Future<List<DryingProgram>> loadPrograms() async {
    final List<DryingProgram> programs = DryingProgram.getBuiltInPrograms();
    if (_prefs == null) return programs;

    try {
      final cloudProgs = await _firestore.collection('programs').get();
      for (var doc in cloudProgs.docs) {
        final p = DryingProgram.fromJson(doc.data());
        int idx = programs.indexWhere((x) => x.id == p.id);
        if (idx >= 0) {
          programs[idx] = p;
        } else {
          programs.add(p);
        }
      }
    } catch (_) {}

    final String? customRaw = _prefs!.getString(keyPrograms);
    if (customRaw != null && customRaw.isNotEmpty) {
      try {
        final List list = jsonDecode(customRaw);
        for (var item in list) {
          final p = DryingProgram.fromJson(item);
          if (!programs.any((x) => x.id == p.id)) {
            programs.add(p);
          }
        }
      } catch (_) {}
    }
    return programs;
  }

  static Future<void> saveCustomProgram(DryingProgram program) async {
    if (_prefs == null) return;
    final List<DryingProgram> all = await loadPrograms();
    final customList = all.where((p) => p.isCustom).toList();

    int existingIdx = customList.indexWhere((p) => p.id == program.id);
    if (existingIdx >= 0) {
      customList[existingIdx] = program;
    } else {
      customList.add(program);
    }

    await _prefs!.setString(keyPrograms, jsonEncode(customList.map((p) => p.toJson()).toList()));

    try {
      await _firestore.collection('programs').doc(program.id).set(program.toJson(), SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> deleteCustomProgram(String programId) async {
    if (_prefs == null) return;
    final List<DryingProgram> all = await loadPrograms();
    final customList = all.where((p) => p.isCustom && p.id != programId).toList();
    await _prefs!.setString(keyPrograms, jsonEncode(customList.map((p) => p.toJson()).toList()));

    try {
      await _firestore.collection('programs').doc(programId).delete();
    } catch (_) {}
  }

  // ================= PER-PROJECT & PER-CLIENT ALERTS STREAM =================
  static Stream<List<AlertItem>> getAlertsStream({
    required String myAppId,
    required bool isAdmin,
    required List<Project> userProjects,
  }) {
    return _firestore.collection('alerts').snapshots().map((snapshot) {
      final list = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        DateTime ts = DateTime.now();
        if (data['timestamp'] != null) {
          if (data['timestamp'] is Timestamp) {
            ts = (data['timestamp'] as Timestamp).toDate();
          } else if (data['timestamp'] is String) {
            ts = DateTime.tryParse(data['timestamp']) ?? DateTime.now();
          }
        }
        final dismissed = List<String>.from(data['dismissedBy'] ?? []);
        final read = List<String>.from(data['readBy'] ?? []);

        return AlertItem(
          id: doc.id,
          kilnId: data['kilnId'] ?? '',
          kilnName: data['kilnName'] ?? '',
          timestamp: ts,
          severity: data['severity'] ?? 'warning',
          title: data['title'] ?? '',
          message: data['message'] ?? '',
          isAcknowledged: read.contains(myAppId) || (data['isAcknowledged'] ?? false),
          readBy: read,
          dismissedBy: dismissed,
        );
      }).where((a) => !a.dismissedBy.contains(myAppId)).toList();

      // If user is not admin, only show alerts for sensors assigned to user's projects
      if (!isAdmin) {
        if (userProjects.isEmpty) {
          return <AlertItem>[];
        }
        final Set<String> allowedDevices = {};
        for (var p in userProjects) {
          allowedDevices.addAll(p.deviceIds);
        }
        list.removeWhere((a) => !allowedDevices.contains(a.kilnId));
      }

      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return list;
    });
  }

  static Future<void> saveAlert(AlertItem alert) async {
    try {
      await _firestore.collection('alerts').doc(alert.id).set({
        'id': alert.id,
        'kilnId': alert.kilnId,
        'kilnName': alert.kilnName,
        'timestamp': FieldValue.serverTimestamp(),
        'severity': alert.severity,
        'title': alert.title,
        'message': alert.message,
        'isAcknowledged': alert.isAcknowledged,
        'readBy': alert.readBy,
        'dismissedBy': alert.dismissedBy,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> dismissAlertForClient(String alertId, String myAppId) async {
    try {
      final docRef = _firestore.collection('alerts').doc(alertId);
      final snap = await docRef.get();
      if (!snap.exists) return;

      final data = snap.data() ?? {};
      final dismissed = List<String>.from(data['dismissedBy'] ?? []);
      if (!dismissed.contains(myAppId)) {
        dismissed.add(myAppId);
      }

      final usersSnap = await _firestore.collection('device_bindings').get();
      final allUserIds = usersSnap.docs.map((d) => d.id).toSet();

      if (allUserIds.isNotEmpty && allUserIds.every((uid) => dismissed.contains(uid))) {
        await docRef.delete();
      } else {
        await docRef.update({
          'dismissedBy': FieldValue.arrayUnion([myAppId]),
          'readBy': FieldValue.arrayUnion([myAppId]),
        });
      }
    } catch (_) {}
  }

  static Future<void> dismissAllAlertsForClient(String myAppId) async {
    try {
      final snaps = await _firestore.collection('alerts').get();
      final usersSnap = await _firestore.collection('device_bindings').get();
      final allUserIds = usersSnap.docs.map((d) => d.id).toSet();

      final batch = _firestore.batch();
      for (var doc in snaps.docs) {
        final dismissed = List<String>.from(doc.data()['dismissedBy'] ?? []);
        if (!dismissed.contains(myAppId)) {
          dismissed.add(myAppId);
        }

        if (allUserIds.isNotEmpty && allUserIds.every((uid) => dismissed.contains(uid))) {
          batch.delete(doc.reference);
        } else {
          batch.update(doc.reference, {
            'dismissedBy': FieldValue.arrayUnion([myAppId]),
            'readBy': FieldValue.arrayUnion([myAppId]),
          });
        }
      }
      await batch.commit();
    } catch (_) {}
  }
}
