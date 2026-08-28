import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import '../models/drying_models.dart';

class DynamicTarget {
  final double temp;
  final double humidity;
  final double emc;
  final double tempTolerance;
  final double humidityTolerance;
  final int stepIndex;
  final DryingStep step;
  final bool isRamping;
  final String transitionPhase;
  final double progressInStep;

  DynamicTarget({
    required this.temp,
    required this.humidity,
    required this.emc,
    required this.tempTolerance,
    required this.humidityTolerance,
    required this.stepIndex,
    required this.step,
    required this.isRamping,
    required this.transitionPhase,
    required this.progressInStep,
  });
}

class EmcCalculator {
  /// Розрахунок рівноважної вологості деревини (EMC - Equilibrium Moisture Content, %)
  /// за формулою Нельсона / USDA Forest Products Laboratory
  static double calculateEmc(double tempC, double humidityPercent) {
    if (tempC <= 0 || humidityPercent <= 0) return 0.0;
    if (humidityPercent > 99.0) humidityPercent = 99.0;

    double T = tempC;
    double h = humidityPercent / 100.0;

    // Коефіцієнти моделі
    double W = 330.0 + 0.452 * T + 0.00415 * T * T;
    double K = 0.791 + 0.000463 * T - 0.000000844 * T * T;
    double K1 = 6.34 + 0.000775 * T - 0.0000935 * T * T;
    double K2 = 1.09 + 0.0284 * T - 0.0000904 * T * T;

    double num1 = (K * h) / (1.0 - K * h);
    double num2 = (K1 * K * h + 2.0 * K1 * K2 * K * K * h * h) /
                  (1.0 + K1 * K * h + K1 * K2 * K * K * h * h);

    double emc = (1800.0 / W) * (num1 + num2);
    if (emc.isNaN || emc.isInfinite || emc < 0) return 0.0;
    return double.parse(emc.toStringAsFixed(1));
  }

  /// Розрахунок точки роси (°C)
  static double calculateDewPoint(double tempC, double humidityPercent) {
    if (humidityPercent <= 0) return 0.0;
    double a = 17.27;
    double b = 237.7;
    double alpha = ((a * tempC) / (b + tempC)) + log(humidityPercent / 100.0);
    double dp = (b * alpha) / (a - alpha);
    return double.parse(dp.toStringAsFixed(1));
  }

  /// Розрахунок динамічної цілі з урахуванням плавного переходу (Ramp-up / Cool-down)
  static DynamicTarget getDynamicTarget(DryingProgram program, double elapsedHours) {
    if (program.steps.isEmpty) {
      final defaultStep = DryingStep(
        stepNumber: 1,
        title: 'Очікування',
        durationHours: 24,
        targetTemp: 20,
        targetHumidity: 50,
      );
      return DynamicTarget(
        temp: 20.0,
        humidity: 50.0,
        emc: calculateEmc(20.0, 50.0),
        tempTolerance: 3.0,
        humidityTolerance: 5.0,
        stepIndex: 0,
        step: defaultStep,
        isRamping: false,
        transitionPhase: 'Витримка',
        progressInStep: 0.0,
      );
    }

    double accumulatedHours = 0.0;
    for (int i = 0; i < program.steps.length; i++) {
      final step = program.steps[i];
      final double stepDuration = step.durationHours;
      final double stepEnd = accumulatedHours + stepDuration;

      if (elapsedHours <= stepEnd || i == program.steps.length - 1) {
        final double timeInStep = (elapsedHours - accumulatedHours).clamp(0.0, stepDuration);
        final double progressInStep = stepDuration > 0 ? (timeInStep / stepDuration).clamp(0.0, 1.0) : 1.0;

        // Попереднє планове значення (для першого кроку — початкова температура завантаження ~22°C / 65%)
        final double prevTemp = i > 0 ? program.steps[i - 1].targetTemp : 22.0;
        final double prevHum = i > 0 ? program.steps[i - 1].targetHumidity : 65.0;

        // Розрахунок тривалості плавного переходу (Ramp duration)
        final double tempDelta = (step.targetTemp - prevTemp).abs();
        final double humDelta = (step.targetHumidity - prevHum).abs();
        
        double rampDuration = 0.0;
        if (tempDelta > 0.5 || humDelta > 1.0) {
          final double maxRampRatio = step.phaseType == PhaseType.cooling ? 0.85 : 0.45;
          final double neededHours = max(tempDelta / 1.5, humDelta / 3.0);
          rampDuration = neededHours.clamp(1.0, max(1.0, stepDuration * maxRampRatio));
          if (rampDuration > stepDuration) rampDuration = stepDuration;
        }

        double currentTargetT;
        double currentTargetH;
        bool isRamping = false;
        String phaseLabel = 'Витримка';

        if (timeInStep < rampDuration && rampDuration > 0) {
          isRamping = true;
          // Плавна косинусна S-крива (термодинамічна інерція нагріву/охолодження)
          final double ratio = timeInStep / rampDuration;
          final double smoothRatio = 0.5 * (1.0 - cos(pi * ratio));
          currentTargetT = prevTemp + (step.targetTemp - prevTemp) * smoothRatio;
          currentTargetH = prevHum + (step.targetHumidity - prevHum) * smoothRatio;

          if (i == 0) {
            phaseLabel = 'Початковий прогрів';
          } else if (step.targetTemp > prevTemp) {
            phaseLabel = 'Набір температури ↗';
          } else if (step.targetTemp < prevTemp) {
            phaseLabel = 'Охолодження ↘';
          } else {
            phaseLabel = 'Зміна режиму вологості';
          }
        } else {
          currentTargetT = step.targetTemp;
          currentTargetH = step.targetHumidity;
        }

        final double dynamicEmc = calculateEmc(currentTargetT, currentTargetH);

        return DynamicTarget(
          temp: double.parse(currentTargetT.toStringAsFixed(1)),
          humidity: double.parse(currentTargetH.toStringAsFixed(1)),
          emc: dynamicEmc,
          tempTolerance: isRamping ? step.tempTolerance * 1.3 : step.tempTolerance,
          humidityTolerance: isRamping ? step.humidityTolerance * 1.3 : step.humidityTolerance,
          stepIndex: i,
          step: step,
          isRamping: isRamping,
          transitionPhase: phaseLabel,
          progressInStep: progressInStep,
        );
      }

      accumulatedHours = stepEnd;
    }

    final lastStep = program.steps.last;
    return DynamicTarget(
      temp: lastStep.targetTemp,
      humidity: lastStep.targetHumidity,
      emc: calculateEmc(lastStep.targetTemp, lastStep.targetHumidity),
      tempTolerance: lastStep.tempTolerance,
      humidityTolerance: lastStep.humidityTolerance,
      stepIndex: program.steps.length - 1,
      step: lastStep,
      isRamping: false,
      transitionPhase: 'Завершення програми',
      progressInStep: 1.0,
    );
  }

  /// Сумісність для отримання активного кроку
  static (DryingStep?, int, double) getActiveStep(DryingProgram program, double elapsedHours) {
    final target = getDynamicTarget(program, elapsedHours);
    return (target.step, target.stepIndex, target.progressInStep);
  }

  /// Генерація плавних точок графіка для візуалізації плану (Ramp & Hold)
  static (List<FlSpot>, List<FlSpot>, List<FlSpot>) generateSmoothPlanSpots(
    DryingProgram program, {
    double sampleStepHours = 0.5,
  }) {
    List<FlSpot> tempSpots = [];
    List<FlSpot> humSpots = [];
    List<FlSpot> emcSpots = [];

    double totalHours = program.totalDurationHours;
    if (totalHours <= 0) totalHours = 24.0;

    double t = 0.0;
    while (t <= totalHours) {
      final target = getDynamicTarget(program, t);
      tempSpots.add(FlSpot(t, target.temp));
      humSpots.add(FlSpot(t, target.humidity));
      emcSpots.add(FlSpot(t, target.emc));
      t += sampleStepHours;
    }

    if (t - sampleStepHours < totalHours) {
      final target = getDynamicTarget(program, totalHours);
      tempSpots.add(FlSpot(totalHours, target.temp));
      humSpots.add(FlSpot(totalHours, target.humidity));
      emcSpots.add(FlSpot(totalHours, target.emc));
    }

    return (tempSpots, humSpots, emcSpots);
  }

  /// Перевірка відхилення фактичних показників від динамічної технологічної карти
  static AlertItem? checkDeviations({
    required KilnDevice kiln,
    required DryingProgram program,
    required double elapsedHours,
  }) {
    final dynamicTarget = getDynamicTarget(program, elapsedHours);

    double currentTemp = kiln.currentTemp;
    double currentHum = kiln.currentHumidity;

    double targetT = dynamicTarget.temp;
    double targetH = dynamicTarget.humidity;
    double tolT = dynamicTarget.tempTolerance;
    double tolH = dynamicTarget.humidityTolerance;

    // 1. Критичне падіння вологості (небезпека розтріскування!)
    if (currentHum < (targetH - tolH * 1.5)) {
      return AlertItem(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        kilnId: kiln.id,
        kilnName: kiln.name,
        timestamp: DateTime.now(),
        severity: 'critical',
        title: '🚨 Критичне падіння вологості (Загроза розтріскування!)',
        message: 'У ${kiln.name} вологість впала до ${currentHum.toStringAsFixed(1)}% (потрібно: ${targetT > 0 ? targetH.toStringAsFixed(1) : "норма"}% ±$tolH%). Необхідне зволоження або закриття заслінок.',
      );
    }

    // 2. Перегрів камери
    if (currentTemp > (targetT + tolT * 1.5)) {
      return AlertItem(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        kilnId: kiln.id,
        kilnName: kiln.name,
        timestamp: DateTime.now(),
        severity: 'critical',
        title: '🔥 Перегрів камери сушіння',
        message: 'У ${kiln.name} температура досягла ${currentTemp.toStringAsFixed(1)}°C (план: ${targetT.toStringAsFixed(1)}°C ±$tolT°C).',
      );
    }

    // 3. Недостатній нагрів
    if (currentTemp < (targetT - tolT)) {
      return AlertItem(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        kilnId: kiln.id,
        kilnName: kiln.name,
        timestamp: DateTime.now(),
        severity: 'warning',
        title: '⚠️ Температура нижче норми графіка',
        message: 'У ${kiln.name} температура становить ${currentTemp.toStringAsFixed(1)}°C (планова траєкторія: ${targetT.toStringAsFixed(1)}°C). Перевірте котел або подачу теплоносія.',
      );
    }

    // 4. Зависока вологість
    if (currentHum > (targetH + tolH)) {
      return AlertItem(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        kilnId: kiln.id,
        kilnName: kiln.name,
        timestamp: DateTime.now(),
        severity: 'warning',
        title: '⚠️ Вологість вище норми графіка',
        message: 'У ${kiln.name} вологість ${currentHum.toStringAsFixed(1)}% (план: ${targetH.toStringAsFixed(1)}%). Можливо, потрібна додаткова вентиляція.',
      );
    }

    return null;
  }
}
