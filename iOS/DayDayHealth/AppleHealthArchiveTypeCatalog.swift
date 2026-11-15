import HealthKit

/// Public HealthKit identifiers from the iOS SDK. Older iOS releases omit newer types.
enum AppleHealthArchiveTypeCatalog {
  static let samples: [HKSampleType] = {
    var result: [HKSampleType] = []
    let quantityIdentifiers: [(String, Int, Int)] = [
      ("AppleSleepingWristTemperature", 16, 0),
      ("BodyFatPercentage", 8, 0),
      ("BodyMass", 8, 0),
      ("BodyMassIndex", 8, 0),
      ("ElectrodermalActivity", 8, 0),
      ("Height", 8, 0),
      ("LeanBodyMass", 8, 0),
      ("WaistCircumference", 11, 0),
      ("ActiveEnergyBurned", 8, 0),
      ("AppleExerciseTime", 9, 3),
      ("AppleMoveTime", 14, 5),
      ("AppleStandTime", 13, 0),
      ("BasalEnergyBurned", 8, 0),
      ("CrossCountrySkiingSpeed", 18, 0),
      ("CyclingCadence", 17, 0),
      ("CyclingFunctionalThresholdPower", 17, 0),
      ("CyclingPower", 17, 0),
      ("CyclingSpeed", 17, 0),
      ("DistanceCrossCountrySkiing", 18, 0),
      ("DistanceCycling", 8, 0),
      ("DistanceDownhillSnowSports", 11, 2),
      ("DistancePaddleSports", 18, 0),
      ("DistanceRowing", 18, 0),
      ("DistanceSkatingSports", 18, 0),
      ("DistanceSwimming", 10, 0),
      ("DistanceWalkingRunning", 8, 0),
      ("DistanceWheelchair", 10, 0),
      ("EstimatedWorkoutEffortScore", 18, 0),
      ("FlightsClimbed", 8, 0),
      ("NikeFuel", 8, 0),
      ("PaddleSportsSpeed", 18, 0),
      ("PhysicalEffort", 17, 0),
      ("PushCount", 10, 0),
      ("RowingSpeed", 18, 0),
      ("RunningPower", 16, 0),
      ("RunningSpeed", 16, 0),
      ("StepCount", 8, 0),
      ("SwimmingStrokeCount", 10, 0),
      ("UnderwaterDepth", 16, 0),
      ("WorkoutEffortScore", 18, 0),
      ("EnvironmentalAudioExposure", 13, 0),
      ("EnvironmentalSoundReduction", 16, 0),
      ("HeadphoneAudioExposure", 13, 0),
      ("AtrialFibrillationBurden", 16, 0),
      ("HeartRate", 8, 0),
      ("HeartRateRecoveryOneMinute", 16, 0),
      ("HeartRateVariabilityRMSSD", 27, 0),
      ("HeartRateVariabilitySDNN", 11, 0),
      ("PeripheralPerfusionIndex", 8, 0),
      ("RestingHeartRate", 11, 0),
      ("VO2Max", 11, 0),
      ("WalkingHeartRateAverage", 11, 0),
      ("AppleWalkingSteadiness", 15, 0),
      ("RunningGroundContactTime", 16, 0),
      ("RunningStrideLength", 16, 0),
      ("RunningVerticalOscillation", 16, 0),
      ("SixMinuteWalkTestDistance", 14, 0),
      ("StairAscentSpeed", 14, 0),
      ("StairDescentSpeed", 14, 0),
      ("WalkingAsymmetryPercentage", 14, 0),
      ("WalkingDoubleSupportPercentage", 14, 0),
      ("WalkingSpeed", 14, 0),
      ("WalkingStepLength", 14, 0),
      ("DietaryBiotin", 8, 0),
      ("DietaryCaffeine", 8, 0),
      ("DietaryCalcium", 8, 0),
      ("DietaryCarbohydrates", 8, 0),
      ("DietaryChloride", 8, 0),
      ("DietaryCholesterol", 8, 0),
      ("DietaryChromium", 8, 0),
      ("DietaryCopper", 8, 0),
      ("DietaryEnergyConsumed", 8, 0),
      ("DietaryFatMonounsaturated", 8, 0),
      ("DietaryFatPolyunsaturated", 8, 0),
      ("DietaryFatSaturated", 8, 0),
      ("DietaryFatTotal", 8, 0),
      ("DietaryFiber", 8, 0),
      ("DietaryFolate", 8, 0),
      ("DietaryIodine", 8, 0),
      ("DietaryIron", 8, 0),
      ("DietaryMagnesium", 8, 0),
      ("DietaryManganese", 8, 0),
      ("DietaryMolybdenum", 8, 0),
      ("DietaryNiacin", 8, 0),
      ("DietaryPantothenicAcid", 8, 0),
      ("DietaryPhosphorus", 8, 0),
      ("DietaryPotassium", 8, 0),
      ("DietaryProtein", 8, 0),
      ("DietaryRiboflavin", 8, 0),
      ("DietarySelenium", 8, 0),
      ("DietarySodium", 8, 0),
      ("DietarySugar", 8, 0),
      ("DietaryThiamin", 8, 0),
      ("DietaryVitaminA", 8, 0),
      ("DietaryVitaminB12", 8, 0),
      ("DietaryVitaminB6", 8, 0),
      ("DietaryVitaminC", 8, 0),
      ("DietaryVitaminD", 8, 0),
      ("DietaryVitaminE", 8, 0),
      ("DietaryVitaminK", 8, 0),
      ("DietaryWater", 9, 0),
      ("DietaryZinc", 8, 0),
      ("BloodAlcoholContent", 8, 0),
      ("BloodPressureDiastolic", 8, 0),
      ("BloodPressureSystolic", 8, 0),
      ("InsulinDelivery", 11, 0),
      ("NumberOfAlcoholicBeverages", 15, 0),
      ("NumberOfTimesFallen", 8, 0),
      ("TimeInDaylight", 17, 0),
      ("UVExposure", 9, 0),
      ("WaterTemperature", 16, 0),
      ("BasalBodyTemperature", 9, 0),
      ("AppleSleepingBreathingDisturbances", 18, 0),
      ("ForcedExpiratoryVolume1", 8, 0),
      ("ForcedVitalCapacity", 8, 0),
      ("InhalerUsage", 8, 0),
      ("OxygenSaturation", 8, 0),
      ("PeakExpiratoryFlowRate", 8, 0),
      ("RespiratoryRate", 8, 0),
      ("BloodGlucose", 8, 0),
      ("BodyTemperature", 8, 0),
    ]
    for (identifier, major, minor) in quantityIdentifiers
      where ProcessInfo.processInfo.isOperatingSystemAtLeast(
        .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) {
      if let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: "HKQuantityTypeIdentifier" + identifier)) {
        result.append(type)
      }
    }
    let categoryIdentifiers: [(String, Int, Int)] = [
      ("AppleStandHour", 9, 0),
      ("EnvironmentalAudioExposureEvent", 14, 0),
      ("HeadphoneAudioExposureEvent", 14, 2),
      ("HighHeartRateEvent", 12, 2),
      ("HypertensionEvent", 26, 2),
      ("IrregularHeartRhythmEvent", 12, 2),
      ("LowCardioFitnessEvent", 14, 3),
      ("LowHeartRateEvent", 12, 2),
      ("MindfulSession", 10, 0),
      ("AppleWalkingSteadinessEvent", 15, 0),
      ("HandwashingEvent", 14, 0),
      ("ToothbrushingEvent", 13, 0),
      ("BleedingAfterMenopause", 27, 0),
      ("BleedingAfterPregnancy", 18, 0),
      ("BleedingDuringPregnancy", 18, 0),
      ("CervicalMucusQuality", 9, 0),
      ("Contraceptive", 14, 3),
      ("InfrequentMenstrualCycles", 16, 0),
      ("IntermenstrualBleeding", 9, 0),
      ("IrregularMenstrualCycles", 16, 0),
      ("Lactation", 14, 3),
      ("MenopausalState", 27, 0),
      ("MenstrualFlow", 9, 0),
      ("OvulationTestResult", 9, 0),
      ("PersistentIntermenstrualBleeding", 16, 0),
      ("Pregnancy", 14, 3),
      ("PregnancyTestResult", 15, 0),
      ("ProgesteroneTestResult", 15, 0),
      ("ProlongedMenstrualPeriods", 16, 0),
      ("SexualActivity", 9, 0),
      ("SleepApneaEvent", 18, 0),
      ("SleepAnalysis", 8, 0),
      ("AbdominalCramps", 13, 6),
      ("Acne", 13, 6),
      ("AppetiteChanges", 13, 6),
      ("BladderIncontinence", 14, 0),
      ("Bloating", 13, 6),
      ("BreastPain", 13, 6),
      ("ChestTightnessOrPain", 13, 6),
      ("Chills", 13, 6),
      ("Constipation", 13, 6),
      ("Coughing", 13, 6),
      ("Diarrhea", 13, 6),
      ("Dizziness", 13, 6),
      ("DrySkin", 14, 0),
      ("Fainting", 13, 6),
      ("Fatigue", 13, 6),
      ("Fever", 13, 6),
      ("GeneralizedBodyAche", 13, 6),
      ("HairLoss", 14, 0),
      ("Headache", 13, 6),
      ("Heartburn", 13, 6),
      ("HotFlashes", 13, 6),
      ("LossOfSmell", 13, 6),
      ("LossOfTaste", 13, 6),
      ("LowerBackPain", 13, 6),
      ("MemoryLapse", 14, 0),
      ("MoodChanges", 13, 6),
      ("Nausea", 13, 6),
      ("NightSweats", 14, 0),
      ("PelvicPain", 13, 6),
      ("RapidPoundingOrFlutteringHeartbeat", 13, 6),
      ("RunnyNose", 13, 6),
      ("ShortnessOfBreath", 13, 6),
      ("SinusCongestion", 13, 6),
      ("SkippedHeartbeat", 13, 6),
      ("SleepChanges", 13, 6),
      ("SoreThroat", 13, 6),
      ("VaginalDryness", 14, 0),
      ("Vomiting", 13, 6),
      ("Wheezing", 13, 6),
    ]
    for (identifier, major, minor) in categoryIdentifiers
      where ProcessInfo.processInfo.isOperatingSystemAtLeast(
        .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) {
      if let type = HKObjectType.categoryType(forIdentifier: .init(rawValue: "HKCategoryTypeIdentifier" + identifier)) {
        result.append(type)
      }
    }
    return result
  }()

  static let clinical: [HKSampleType] = {
    var result: [HKSampleType] = []
    let clinicalIdentifiers: [(String, Int, Int)] = [
      ("AllergyRecord", 12, 0),
      ("ClinicalNoteRecord", 16, 4),
      ("ConditionRecord", 12, 0),
      ("ImmunizationRecord", 12, 0),
      ("LabResultRecord", 12, 0),
      ("MedicationRecord", 12, 0),
      ("ProcedureRecord", 12, 0),
      ("VitalSignRecord", 12, 0),
      ("CoverageRecord", 14, 0),
    ]
    for (identifier, major, minor) in clinicalIdentifiers
      where ProcessInfo.processInfo.isOperatingSystemAtLeast(
        .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) {
      if let type = HKObjectType.clinicalType(forIdentifier: .init(rawValue: "HKClinicalTypeIdentifier" + identifier)) {
        result.append(type)
      }
    }
    return result
  }()

  static let characteristics: [HKObjectType] = {
    var result: [HKObjectType] = []
    let characteristicIdentifiers: [(String, Int, Int)] = [
      ("ActivityMoveMode", 14, 0),
      ("BiologicalSex", 8, 0),
      ("BloodType", 8, 0),
      ("DateOfBirth", 8, 0),
      ("FitzpatrickSkinType", 9, 0),
      ("WheelchairUse", 10, 0),
    ]
    for (identifier, major, minor) in characteristicIdentifiers
      where ProcessInfo.processInfo.isOperatingSystemAtLeast(
        .init(majorVersion: major, minorVersion: minor, patchVersion: 0)) {
      if let type = HKObjectType.characteristicType(forIdentifier: .init(rawValue: "HKCharacteristicTypeIdentifier" + identifier)) {
        result.append(type)
      }
    }
    return result
  }()

}
