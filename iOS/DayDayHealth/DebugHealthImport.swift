#if DEBUG && targetEnvironment(simulator)
import CoreFoundation
import Foundation
import HealthKit
import SwiftUI
import UniformTypeIdentifiers

/// The source UUID is a deduplication key only. HealthKit assigns the new UUID and source.
enum DebugHealthFixture {
  struct Row {
    let id: String
    let sample: HKSample
  }

  struct Parsed {
    var rows: [Row] = []
    var repeated = 0
    var unsupported = 0
    var invalid = 0
  }

  static func parse(_ data: Data, types: [HKSampleType]) throws -> Parsed {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let queries = root["queries"] as? [[String: Any]] else {
      throw APIClient.APIError.message("文件缺少 queries 数组。")
    }
    let supported = Dictionary(uniqueKeysWithValues: types.map { ($0.identifier, $0) })
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    func date(_ input: Any?) -> Date? {
      guard let text = input as? String else { return nil }
      return precise.date(from: text) ?? standard.date(from: text)
    }

    var result = Parsed()
    var seen = Set<String>()
    for query in queries {
      guard let samples = query["samples"] as? [[String: Any]] else {
        throw APIClient.APIError.message("查询缺少有效的 samples 数组。")
      }
      for row in samples where row["recordKind"] as? String == "rawHealthKitSample" {
        guard let identifier = query["dataType"] as? String else {
          result.invalid += 1
          continue
        }
        guard let type = supported[identifier] else {
          result.unsupported += 1
          continue
        }
        guard row["dataType"] as? String == identifier,
              let rawID = row["id"] as? String, let id = UUID(uuidString: rawID)?.uuidString,
              let start = date(row["startDate"]), let end = date(row["endDate"]), end >= start,
              let number = numeric(row["value"]) else {
          result.invalid += 1
          continue
        }
        guard !seen.contains(id) else {
          result.repeated += 1
          continue
        }
        let metadata = metadata(from: row, id: id)
        let sample: HKSample
        if let quantityType = type as? HKQuantityType,
           let text = row["unit"] as? String, let unit = units[text],
           let spec = HealthMetricsSync.quantitySpec(identifier),
           HKQuantity(unit: unit, doubleValue: 0).is(compatibleWith: spec.unit) {
          // The probe uses percentage points, while HealthKit's percent unit uses a fraction.
          let value = text == "%" ? number.doubleValue / 100 : number.doubleValue
          sample = HKQuantitySample(type: quantityType,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start, end: end, metadata: metadata)
        } else if let categoryType = type as? HKCategoryType,
                  let value = Int(exactly: number.doubleValue),
                  HKCategoryValueSleepAnalysis(rawValue: value) != nil {
          sample = HKCategorySample(type: categoryType, value: value,
            start: start, end: end, metadata: metadata)
        } else {
          result.invalid += 1
          continue
        }
        seen.insert(id)
        result.rows.append(Row(id: id, sample: sample))
      }
    }
    return result
  }

  private static let rate = HKUnit.count().unitDivided(by: .minute())
  private static let units: [String: HKUnit] = [
    "kg": .gramUnit(with: .kilo), "g": .gram(), "lb": .pound(),
    "count/min": rate, "bpm": rate, "ms": .secondUnit(with: .milli),
    "s": .second(), "min": .minute(), "count": .count(), "kg/m²": .count(),
    "%": .percent(), "kcal": .kilocalorie(), "kJ": .jouleUnit(with: .kilo),
    "km": .meterUnit(with: .kilo), "m": .meter()
  ]

  private static func numeric(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return nil }
    return number
  }

  private static func metadata(from row: [String: Any], id: String) -> [String: Any] {
    let raw = row["metadata"] as? [String: Any] ?? [:]
    var result: [String: Any] = [
      HealthMetricsSync.fixtureMetadataKey: id,
      HKMetadataKeySyncIdentifier: "daydayhealth-debug-fixture:\(id)",
      HKMetadataKeySyncVersion: 1
    ]
    if let name = (raw[HKMetadataKeyFoodType] ?? row["foodName"]) as? String {
      result[HKMetadataKeyFoodType] = name
    }
    if let context = numeric(raw[HKMetadataKeyHeartRateMotionContext]),
       let value = Int(exactly: context.doubleValue),
       HKHeartRateMotionContext(rawValue: value) != nil {
      result[HKMetadataKeyHeartRateMotionContext] = value
    }
    if let version = numeric(raw[HKMetadataKeyAlgorithmVersion]) {
      result[HKMetadataKeyAlgorithmVersion] = version
    }
    if let zone = raw[HKMetadataKeyTimeZone] as? String, TimeZone(identifier: zone) != nil {
      result[HKMetadataKeyTimeZone] = zone
    }
    if let entered = raw[HKMetadataKeyWasUserEntered] as? NSNumber,
       entered == 0 || entered == 1 {
      result[HKMetadataKeyWasUserEntered] = entered
    }
    return result
  }
}

struct DebugHealthImportScreen: View {
  @ObservedObject var store: HealthStore
  @State private var picking = false
  @State private var running = false
  @State private var report: String?

  var body: some View {
    Form {
      Section {
        Button("选择并导入 HealthKit JSON") { picking = true }
          .disabled(running)
        Text("导入原始健康样本，并通过本机测试后台验证读取和上传。")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if !stagedFiles.isEmpty {
        Section("已放入模拟器 Documents 的文件") {
          ForEach(stagedFiles, id: \.self) { file in
            Button(file.lastPathComponent) { Task { await run(.success(file)) } }
              .disabled(running)
          }
        }
      }
      if running { ProgressView("正在导入…") }
      if let report { Text(report).font(.footnote).textSelection(.enabled) }
    }
    .navigationTitle("HealthKit 测试数据")
    .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
      Task { await run(result) }
    }
  }

  private var stagedFiles: [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: .documentsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )) ?? []
    return files.filter {
      $0.lastPathComponent.hasPrefix("DayDayHealthProbe-") && $0.pathExtension.lowercased() == "json"
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  @MainActor private func run(_ result: Result<URL, Error>) async {
    guard !running else { return }
    running = true
    report = nil
    defer { running = false }
    do {
      let url = try result.get()
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url)
      report = try await HealthMetricsSync.shared.importDebugFixture(data, client: try? store.client())
    } catch {
      report = "导入失败：\(error.localizedDescription)"
    }
  }
}

/// Refuse redirects so a local endpoint cannot forward fixture data or credentials.
final class DebugHealthNoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
#endif
