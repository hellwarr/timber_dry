import 'dart:math';
import '../models/drying_models.dart';

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

  /// Пошук активного кроку сушіння за пройденим часом
  static (DryingStep?, int, double) getActiveStep(DryingProgram program, double elapsedHours) {
    double accumulatedHours = 0.0;
    for (int i = 0; i < program.steps.length; i++) {
      final step = program.steps[i];
      if (elapsedHours <= (accumulatedHours + step.durationHours)) {
        double stepProgress = (elapsedHours - accumulatedHours) / step.durationHours;
        return (step, i, stepProgress.clamp(0.0, 1.0));
      }
      accumulatedHours += step.durationHours;
    }
    // Якщо час перевищив тривалість програми
    return (program.steps.last, program.steps.length - 1, 1.0);
  }

  /// Перевірка відхилення фактичних показників від технологічної карти
  static AlertItem? checkDeviations({
    required KilnDevice kiln,
    required DryingProgram program,
    required double elapsedHours,
  }) {
    final (activeStep, stepIndex, _) = getActiveStep(program, elapsedHours);
    if (activeStep == null) return null;

    double currentTemp = kiln.currentTemp;
    double currentHum = kiln.currentHumidity;

    double targetT = activeStep.targetTemp;
    double targetH = activeStep.targetHumidity;
    double tolT = activeStep.tempTolerance;
    double tolH = activeStep.humidityTolerance;

    // 1. Критичне падіння вологості (небезпека розтріскування!)
    if (currentHum < (targetH - tolH * 1.5)) {
      return AlertItem(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        kilnId: kiln.id,
        kilnName: kiln.name,
        timestamp: DateTime.now(),
        severity: 'critical',
        title: '🚨 Критичне падіння вологості (Загроза розтріскування!)',
        message: 'У ${kiln.name} вологість впала до ${currentHum.toStringAsFixed(1)}% (потрібно: ${targetH.toStringAsFixed(1)}% ±$tolH%). Необхідне зволоження або закриття заслінок.',
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
        message: 'У ${kiln.name} температура досягла ${currentTemp.toStringAsFixed(1)}°C (норма етапу: ${targetT.toStringAsFixed(1)}°C ±$tolT°C).',
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
        message: 'У ${kiln.name} температура становить ${currentTemp.toStringAsFixed(1)}°C замість ${targetT.toStringAsFixed(1)}°C. Перевірте котел або подачу теплоносія.',
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
        message: 'У ${kiln.name} вологість ${currentHum.toStringAsFixed(1)}% замість ${targetH.toStringAsFixed(1)}%. Можливо, потрібна додаткова вентиляція.',
      );
    }

    return null;
  }
}
