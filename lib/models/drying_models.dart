import 'dart:convert';
import 'package:flutter/foundation.dart';

enum PhaseType {
  heating,       // Початковий прогрів
  steaming,      // Пропарювання / Зняття напружень
  mainDrying,    // Основна сушка (по фазах)
  conditioning,  // Кондиціонування / Вирівнювання
  cooling,       // Охолодження
}

// ================= PROJECT MANAGEMENT (MULTI-TENANT RBAC) =================
class Project {
  final String id;
  String name;
  String description;
  List<String> deviceIds;    // Assigned ESP32 device IDs (e.g. ["B8D07CC9", "A1B2C3D4"])
  List<String> memberAppIds; // Allowed client App IDs (e.g. ["APP-8F3A-19C2-8821"])
  List<String> programIds;   // Allowed / active drying recipes for this project
  DateTime createdAt;

  Project({
    required this.id,
    required this.name,
    this.description = '',
    List<String>? deviceIds,
    List<String>? memberAppIds,
    List<String>? programIds,
    DateTime? createdAt,
  })  : deviceIds = deviceIds ?? [],
        memberAppIds = memberAppIds ?? [],
        programIds = programIds ?? [],
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'deviceIds': deviceIds,
        'memberAppIds': memberAppIds,
        'programIds': programIds,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] ?? '',
        name: json['name'] ?? 'Проєкт без назви',
        description: json['description'] ?? '',
        deviceIds: List<String>.from(json['deviceIds'] ?? []),
        memberAppIds: List<String>.from(json['memberAppIds'] ?? []),
        programIds: List<String>.from(json['programIds'] ?? []),
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt']) ?? DateTime.now()
            : DateTime.now(),
      );
}

class DryingStep {
  final int stepNumber;
  final String title;
  final double durationHours;
  final double targetTemp;     // Цільова температура (°C)
  final double targetHumidity; // Цільова відносна вологість RH (%)
  final double tempTolerance;  // Допустиме відхилення темп. (за замовчуванням ±3.0°C)
  final double humidityTolerance; // Допустиме відхилення вологості (за замовчуванням ±5.0%)
  final PhaseType phaseType;
  final String description;

  DryingStep({
    required this.stepNumber,
    required this.title,
    required this.durationHours,
    required this.targetTemp,
    required this.targetHumidity,
    this.tempTolerance = 3.0,
    this.humidityTolerance = 5.0,
    this.phaseType = PhaseType.mainDrying,
    this.description = '',
  });

  Map<String, dynamic> toJson() => {
    'stepNumber': stepNumber,
    'title': title,
    'durationHours': durationHours,
    'targetTemp': targetTemp,
    'targetHumidity': targetHumidity,
    'tempTolerance': tempTolerance,
    'humidityTolerance': humidityTolerance,
    'phaseType': phaseType.name,
    'description': description,
  };

  factory DryingStep.fromJson(Map<String, dynamic> json) => DryingStep(
    stepNumber: json['stepNumber'] ?? 1,
    title: json['title'] ?? '',
    durationHours: (json['durationHours'] ?? 24.0).toDouble(),
    targetTemp: (json['targetTemp'] ?? 50.0).toDouble(),
    targetHumidity: (json['targetHumidity'] ?? 60.0).toDouble(),
    tempTolerance: (json['tempTolerance'] ?? 3.0).toDouble(),
    humidityTolerance: (json['humidityTolerance'] ?? 5.0).toDouble(),
    phaseType: PhaseType.values.firstWhere(
      (e) => e.name == json['phaseType'],
      orElse: () => PhaseType.mainDrying,
    ),
    description: json['description'] ?? '',
  );
}

class DryingProgram {
  final String id;
  final String name;
  final String woodSpecies; // Дуб, Сосна, Ясен, Бук тощо
  final int woodThicknessMm; // 25, 30, 40, 50, 60 мм
  final List<DryingStep> steps;
  final bool isCustom;

  DryingProgram({
    required this.id,
    required this.name,
    required this.woodSpecies,
    required this.woodThicknessMm,
    required this.steps,
    this.isCustom = false,
  });

  double get totalDurationHours => steps.fold(0.0, (sum, step) => sum + step.durationHours);
  double get totalDays => totalDurationHours / 24.0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'woodSpecies': woodSpecies,
    'woodThicknessMm': woodThicknessMm,
    'isCustom': isCustom,
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  factory DryingProgram.fromJson(Map<String, dynamic> json) => DryingProgram(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    woodSpecies: json['woodSpecies'] ?? 'Дуб',
    woodThicknessMm: json['woodThicknessMm'] ?? 50,
    isCustom: json['isCustom'] ?? false,
    steps: (json['steps'] as List? ?? [])
        .map((s) => DryingStep.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  static List<DryingProgram> getBuiltInPrograms() {
    return [
      DryingProgram(
        id: 'oak_50mm_standard',
        name: 'Дуб 50мм (Меблевий щадний режим)',
        woodSpecies: 'Дуб',
        woodThicknessMm: 50,
        steps: [
          DryingStep(stepNumber: 1, title: 'Початковий прогрів', durationHours: 18, targetTemp: 38, targetHumidity: 90, phaseType: PhaseType.heating, description: 'Плавне прогрівання серцевини дошки без випаровування вологи'),
          DryingStep(stepNumber: 2, title: 'Пропарювання / Вирівнювання', durationHours: 24, targetTemp: 55, targetHumidity: 95, phaseType: PhaseType.steaming, description: 'Зняття внутрішніх напружень та запобігання розтріскуванню'),
          DryingStep(stepNumber: 3, title: 'Основна сушка: Фаза 1', durationHours: 48, targetTemp: 45, targetHumidity: 82, phaseType: PhaseType.mainDrying, description: 'Зниження вологості від свіжорозпиляної до 40%'),
          DryingStep(stepNumber: 4, title: 'Основна сушка: Фаза 2', durationHours: 48, targetTemp: 50, targetHumidity: 70, phaseType: PhaseType.mainDrying, description: 'Зниження вологості деревини 40% -> 25%'),
          DryingStep(stepNumber: 5, title: 'Основна сушка: Фаза 3', durationHours: 48, targetTemp: 56, targetHumidity: 50, phaseType: PhaseType.mainDrying, description: 'Зниження вологості деревини 25% -> 15%'),
          DryingStep(stepNumber: 6, title: 'Фінальне досушування', durationHours: 36, targetTemp: 62, targetHumidity: 32, phaseType: PhaseType.mainDrying, description: 'Доведення до меблевої вологості 8-10%'),
          DryingStep(stepNumber: 7, title: 'Кондиціонування', durationHours: 24, targetTemp: 52, targetHumidity: 58, phaseType: PhaseType.conditioning, description: 'Рівномірний розподіл залишкової вологості по товщині'),
          DryingStep(stepNumber: 8, title: 'Охолодження', durationHours: 12, targetTemp: 30, targetHumidity: 65, phaseType: PhaseType.cooling, description: 'Плавне зниження температури перед вивантаженням'),
        ],
      ),
      DryingProgram(
        id: 'pine_50mm_standard',
        name: 'Сосна / Ялина 50мм (Будівельний брус)',
        woodSpecies: 'Сосна',
        woodThicknessMm: 50,
        steps: [
          DryingStep(stepNumber: 1, title: 'Прогрів', durationHours: 12, targetTemp: 45, targetHumidity: 90, phaseType: PhaseType.heating),
          DryingStep(stepNumber: 2, title: 'Інтенсивне сушіння 1', durationHours: 36, targetTemp: 60, targetHumidity: 70, phaseType: PhaseType.mainDrying),
          DryingStep(stepNumber: 3, title: 'Інтенсивне сушіння 2', durationHours: 36, targetTemp: 70, targetHumidity: 45, phaseType: PhaseType.mainDrying),
          DryingStep(stepNumber: 4, title: 'Досушування', durationHours: 24, targetTemp: 75, targetHumidity: 30, phaseType: PhaseType.mainDrying),
          DryingStep(stepNumber: 5, title: 'Охолодження', durationHours: 12, targetTemp: 35, targetHumidity: 55, phaseType: PhaseType.cooling),
        ],
      ),
      DryingProgram(
        id: 'ash_50mm_standard',
        name: 'Ясен 50мм (Твердолистяний режим)',
        woodSpecies: 'Ясен',
        woodThicknessMm: 50,
        steps: [
          DryingStep(stepNumber: 1, title: 'Прогрів', durationHours: 16, targetTemp: 40, targetHumidity: 92, phaseType: PhaseType.heating),
          DryingStep(stepNumber: 2, title: 'Пропарювання', durationHours: 20, targetTemp: 60, targetHumidity: 95, phaseType: PhaseType.steaming),
          DryingStep(stepNumber: 3, title: 'Сушка 1', durationHours: 40, targetTemp: 48, targetHumidity: 80, phaseType: PhaseType.mainDrying),
          DryingStep(stepNumber: 4, title: 'Сушка 2', durationHours: 48, targetTemp: 54, targetHumidity: 60, phaseType: PhaseType.mainDrying),
          DryingStep(stepNumber: 5, title: 'Фініш', durationHours: 36, targetTemp: 62, targetHumidity: 35, phaseType: PhaseType.mainDrying),
          DryingStep(stepNumber: 6, title: 'Охолодження', durationHours: 12, targetTemp: 32, targetHumidity: 60, phaseType: PhaseType.cooling),
        ],
      ),
    ];
  }
}

class TelemetryPoint {
  final DateTime timestamp;
  final double temp;
  final double humidity;
  final double emc;
  final int stepIndex;
  final double targetTemp;
  final double targetHumidity;

  TelemetryPoint({
    required this.timestamp,
    required this.temp,
    required this.humidity,
    required this.emc,
    required this.stepIndex,
    required this.targetTemp,
    required this.targetHumidity,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'temp': temp,
    'humidity': humidity,
    'emc': emc,
    'stepIndex': stepIndex,
    'targetTemp': targetTemp,
    'targetHumidity': targetHumidity,
  };

  factory TelemetryPoint.fromJson(Map<String, dynamic> json) => TelemetryPoint(
    timestamp: DateTime.parse(json['timestamp']),
    temp: (json['temp'] ?? 0.0).toDouble(),
    humidity: (json['humidity'] ?? 0.0).toDouble(),
    emc: (json['emc'] ?? 0.0).toDouble(),
    stepIndex: json['stepIndex'] ?? 0,
    targetTemp: (json['targetTemp'] ?? 0.0).toDouble(),
    targetHumidity: (json['targetHumidity'] ?? 0.0).toDouble(),
  );
}

class DryingSession {
  final String id;
  final String kilnId;
  final String programId;
  final String programName;
  final String woodSpecies;
  final int woodThicknessMm;
  final double batchVolumeM3;
  final DateTime startTime;
  DateTime? endTime;
  bool isCompleted;
  bool isPaused;
  final List<TelemetryPoint> history;

  DryingSession({
    required this.id,
    required this.kilnId,
    required this.programId,
    required this.programName,
    required this.woodSpecies,
    required this.woodThicknessMm,
    required this.batchVolumeM3,
    required this.startTime,
    this.endTime,
    this.isCompleted = false,
    this.isPaused = false,
    List<TelemetryPoint>? history,
  }) : history = history ?? [];

  double get elapsedHours => DateTime.now().difference(startTime).inMinutes / 60.0;
  double get elapsedDays => elapsedHours / 24.0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kilnId': kilnId,
    'programId': programId,
    'programName': programName,
    'woodSpecies': woodSpecies,
    'woodThicknessMm': woodThicknessMm,
    'batchVolumeM3': batchVolumeM3,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'isCompleted': isCompleted,
    'isPaused': isPaused,
    'history': history.map((h) => h.toJson()).toList(),
  };

  factory DryingSession.fromJson(Map<String, dynamic> json) => DryingSession(
    id: json['id'] ?? '',
    kilnId: json['kilnId'] ?? '',
    programId: json['programId'] ?? '',
    programName: json['programName'] ?? '',
    woodSpecies: json['woodSpecies'] ?? 'Дуб',
    woodThicknessMm: json['woodThicknessMm'] ?? 50,
    batchVolumeM3: (json['batchVolumeM3'] ?? 30.0).toDouble(),
    startTime: DateTime.parse(json['startTime']),
    endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
    isCompleted: json['isCompleted'] ?? false,
    isPaused: json['isPaused'] ?? false,
    history: (json['history'] as List? ?? [])
        .map((h) => TelemetryPoint.fromJson(h as Map<String, dynamic>))
        .toList(),
  );
}

class AlertItem {
  final String id;
  final String kilnId;
  final String kilnName;
  final DateTime timestamp;
  final String severity; // "info", "warning", "critical"
  final String title;
  final String message;
  bool isAcknowledged;
  final List<String> readBy;
  final List<String> dismissedBy;

  AlertItem({
    required this.id,
    required this.kilnId,
    required this.kilnName,
    required this.timestamp,
    required this.severity,
    required this.title,
    required this.message,
    this.isAcknowledged = false,
    this.readBy = const [],
    this.dismissedBy = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'kilnId': kilnId,
    'kilnName': kilnName,
    'timestamp': timestamp.toIso8601String(),
    'severity': severity,
    'title': title,
    'message': message,
    'isAcknowledged': isAcknowledged,
    'readBy': readBy,
    'dismissedBy': dismissedBy,
  };

  factory AlertItem.fromJson(Map<String, dynamic> json) => AlertItem(
    id: json['id'] ?? '',
    kilnId: json['kilnId'] ?? '',
    kilnName: json['kilnName'] ?? '',
    timestamp: DateTime.parse(json['timestamp']),
    severity: json['severity'] ?? 'warning',
    title: json['title'] ?? '',
    message: json['message'] ?? '',
    isAcknowledged: json['isAcknowledged'] ?? false,
    readBy: List<String>.from(json['readBy'] ?? []),
    dismissedBy: List<String>.from(json['dismissedBy'] ?? []),
  );
}

class KilnDevice {
  final String id;
  final String deviceId; // 8-char hardware unique ID (e.g. B8D07CC9)
  String name;
  String location;
  String ipAddress;
  double currentTemp;
  double currentHumidity;
  double currentEmc;
  DateTime lastSeen;
  bool isOnline;
  bool sensorConnected;
  String sensorStatus; // "OK", "DISCONNECTED", "ERROR"
  int uptimeSeconds;
  int bootCount;
  int rssi;
  String firmwareVersion;
  DryingSession? activeSession;
  String? blePin;

  KilnDevice({
    required this.id,
    String? deviceId,
    required this.name,
    this.location = 'Цех №1',
    this.ipAddress = '192.168.1.150',
    this.currentTemp = 20.0,
    this.currentHumidity = 50.0,
    this.currentEmc = 9.0,
    required this.lastSeen,
    this.isOnline = true,
    this.sensorConnected = true,
    this.sensorStatus = 'OK',
    this.uptimeSeconds = 0,
    this.bootCount = 1,
    this.rssi = -60,
    this.firmwareVersion = '1.7.3',
    this.activeSession,
    this.blePin = '196711',
  }) : deviceId = deviceId ?? id;

  String get uptimeFormatted {
    if (uptimeSeconds <= 0) return 'щойно запущено';
    int days = uptimeSeconds ~/ 86400;
    int hours = (uptimeSeconds % 86400) ~/ 3600;
    int mins = (uptimeSeconds % 3600) ~/ 60;
    if (days > 0) return '$days дн $hours год';
    if (hours > 0) return '$hours год $mins хв';
    return '$mins хв';
  }

  int get wifiSignalPercent {
    if (rssi <= -100) return 0;
    if (rssi >= -50) return 100;
    return (2 * (rssi + 100)).clamp(0, 100);
  }

  String get wifiSignalQuality {
    if (rssi >= -55) return 'Відмінний';
    if (rssi >= -67) return 'Добрий';
    if (rssi >= -75) return 'Задовільний';
    if (rssi >= -85) return 'Слабкий';
    return 'Критично низький';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'deviceId': deviceId,
    'name': name,
    'location': location,
    'ipAddress': ipAddress,
    'currentTemp': currentTemp,
    'currentHumidity': currentHumidity,
    'currentEmc': currentEmc,
    'lastSeen': lastSeen.toIso8601String(),
    'isOnline': isOnline,
    'sensorConnected': sensorConnected,
    'sensorStatus': sensorStatus,
    'uptimeSeconds': uptimeSeconds,
    'bootCount': bootCount,
    'rssi': rssi,
    'firmwareVersion': firmwareVersion,
    'activeSession': activeSession?.toJson(),
    'blePin': blePin,
  };

  factory KilnDevice.fromJson(Map<String, dynamic> json) => KilnDevice(
    id: json['id'] ?? json['deviceId'] ?? '',
    deviceId: json['deviceId'] ?? json['id'] ?? '',
    name: json['name'] ?? json['label'] ?? '',
    location: json['location'] ?? 'Цех №1',
    ipAddress: json['ipAddress'] ?? '192.168.1.150',
    currentTemp: (json['currentTemp'] ?? 20.0).toDouble(),
    currentHumidity: (json['currentHumidity'] ?? 50.0).toDouble(),
    currentEmc: (json['currentEmc'] ?? 9.0).toDouble(),
    lastSeen: DateTime.parse(json['lastSeen'] ?? DateTime.now().toIso8601String()),
    isOnline: json['isOnline'] ?? true,
    sensorConnected: json['sensorConnected'] ?? true,
    sensorStatus: json['sensorStatus'] ?? 'OK',
    uptimeSeconds: json['uptimeSeconds'] ?? 0,
    bootCount: json['bootCount'] ?? 1,
    rssi: json['rssi'] ?? -60,
    firmwareVersion: json['firmwareVersion'] ?? '1.7.3',
    activeSession: json['activeSession'] != null ? DryingSession.fromJson(json['activeSession']) : null,
    blePin: json['blePin'] ?? '196711',
  );
}
