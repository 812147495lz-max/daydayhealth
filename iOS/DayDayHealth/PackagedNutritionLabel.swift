import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PackagedNutritionLabel: Codable {
  static let storageKey = "wbPackagedNutritionLabels"

  var name: String?
  var brand: String?
  var barcode: String?
  var source: String?
  // Keep the legacy quantity key for saved labels. The optional unit defaults to grams.
  var basisGrams: Double?
  var basisUnit: MealPortionUnit?
  var energy: Double?
  var energyUnit: EnergyUnit?
  var protein: Double?
  var fat: Double?
  var carbs: Double?

  enum EnergyUnit: String, CaseIterable, Codable {
    case kcal, kJ
  }

  var displayName: String {
    let product = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let brand = (brand ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if brand.isEmpty || FoodSearchQuery.normalize(product).contains(FoodSearchQuery.normalize(brand)) {
      return product
    }
    return "\(brand) \(product)"
  }

  private var normalizedBarcode: String {
    FoodSearchQuery.normalize(barcode ?? "")
  }

  var catalogKey: String {
    if !normalizedBarcode.isEmpty { return "barcode:\(normalizedBarcode)" }
    return "name:\(FoodSearchQuery.normalize(brand ?? ""))|\(FoodSearchQuery.normalize(name ?? ""))"
  }

  var portion: MealFoodEstimate? {
    guard let name, let basisGrams, let energy, let energyUnit, let protein, let fat, let carbs
    else { return nil }
    guard !FoodSearchQuery.normalize(name).isEmpty,
      normalizedBarcode.isEmpty || ([8, 12, 13, 14].contains(normalizedBarcode.count)
        && normalizedBarcode.utf8.allSatisfy { (48...57).contains($0) }) else { return nil }
    let estimate = MealFoodEstimate(name: displayName,
      grams: basisGrams, kcal: energyUnit == .kJ ? energy / 4.184 : energy,
      protein: protein, fat: fat, carbs: carbs, reference: source ?? "包装营养标签", unit: basisUnit)
    return estimate.isValid ? estimate : nil
  }

  static func search(_ query: FoodSearchQuery, in data: Data) -> [Self] {
    let labels = (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    var keys = Set<String>()
    var ranked = [[Self]](repeating: [], count: FoodSearchQuery.rankCount)
    for label in labels where label.portion != nil && keys.insert(label.catalogKey).inserted {
      let fields = [label.displayName, label.name ?? "", label.brand ?? "", label.normalizedBarcode]
        .map(FoodSearchQuery.Field.init)
      let score = query.normalized.isEmpty ? 1 : query.score(fields)
      if score > 0 { ranked[score].append(label) }
    }
    return Array(ranked.reversed().joined())
  }

  func saved(in data: Data, replacing key: String?) throws -> Data {
    var labels = data.isEmpty ? [] : try JSONDecoder().decode([Self].self, from: data)
    labels.removeAll { $0.catalogKey == catalogKey || $0.catalogKey == key }
    labels.insert(self, at: 0)
    return try JSONEncoder().encode(labels)
  }

  static func read(photos: [Data], model: DirectModelConfiguration) async throws -> Self {
    let prompt = """
    转录同一个包装食品的营养表。照片可分别显示包装正面、营养标签和条码。不能拼接不同产品或不同列；如果有多个产品且无法确定对应关系，返回空对象。不要估算。优先每100克或每100毫升，其次每份。
    basisGrams 是所选列的份量数值：每100克或每100毫升写100；每份使用标签注明的克数或毫升数。basisUnit 对应 grams 或 milliliters，不能在两者之间换算。若每份没有标注克数或毫升数，basisGrams 写 1，basisUnit 写 servings。
    name 是具体品名（包括口味），brand 是品牌，barcode 是可见条码的完整数字字符串，保留前导零。看不清的字段写 null。
    能量照抄并注明单位 kcal 或 kJ，蛋白质、脂肪、碳水以克为单位。无法辨认的字段返回 null。
    仅返回 JSON：{"name":null,"brand":null,"barcode":null,"basisGrams":100,"basisUnit":"grams","energy":500,"energyUnit":"kJ","protein":3,"fat":4,"carbs":12}。
    """
    let answer = try await model.completeMeal(prompt: prompt, photos: photos)
    guard let label: Self = decodeMealJSON(answer),
      [label.energy, label.protein, label.fat, label.carbs].contains(where: { $0 != nil }) else {
      throw APIClient.APIError.message("未能识别营养表。请换一张清晰照片，或手动填写。")
    }
    return label
  }
}

struct PackagedNutritionEditor: View {
  let model: DirectModelConfiguration?
  let onUse: (MealFoodEstimate) -> Void
  @Environment(\.dismiss) private var dismiss
  @AppStorage(PackagedNutritionLabel.storageKey) private var storage = Data()
  @State private var draft = PackagedNutritionLabel(basisGrams: 100, energyUnit: .kcal)
  @State private var attachments = ModelPhotoSelection()
  @State private var filePhotos: [Data] = []
  @State private var showingCatalog = false
  @State private var showingSaved = false
  @State private var editingKey: String?
  @State private var importing = false
  @State private var loading = false
  @State private var analyzing = false
  @State private var message: String?

  private var saved: [PackagedNutritionLabel] {
    PackagedNutritionLabel.search(FoodSearchQuery(""), in: storage)
  }

  var body: some View {
    NavigationStack {
      Form {
        if !saved.isEmpty {
          Button("我的食品", systemImage: "magnifyingglass") { showingSaved = true }
        }
        Button("选择内置营养表", systemImage: "list.bullet.rectangle") { showingCatalog = true }
        Section {
          PhotosPicker(selection: $attachments.items, maxSelectionCount: ModelPhotoSelection.limit,
                       selectionBehavior: .ordered, matching: .images) {
            Label("从相册上传营养表", systemImage: "photo")
          }
          Button("从文件上传营养表图片", systemImage: "folder") { importing = true }
          if loading || attachments.loading { ProgressView("正在读取图片…") }
          if let error = attachments.error { Text(error).foregroundStyle(.red) }
          let photos = attachments.items.isEmpty ? filePhotos : attachments.readyPhotos
          ModelPhotoStrip(photos: photos, onRemove: { index in
            if attachments.items.isEmpty { filePhotos.remove(at: index) }
            else { attachments.remove(at: index) }
          })
          if !photos.isEmpty {
            Button(analyzing ? "正在识别…" : "AI 识别标签", systemImage: "sparkles") {
              Task { await analyze(photos) }
            }.disabled(analyzing || loading)
          }
        }
        Section("核对标签数值") {
          TextField("食品名称", text: Binding(get: { draft.name ?? "" }, set: { draft.name = $0 }))
          TextField("品牌（选填）", text: Binding(get: { draft.brand ?? "" }, set: { draft.brand = $0 }))
          TextField("条码（选填）", text: Binding(get: { draft.barcode ?? "" }, set: { draft.barcode = $0 }))
            .keyboardType(.numberPad)
          Picker("份量单位", selection: Binding(get: { draft.basisUnit ?? .grams }, set: { draft.basisUnit = $0 })) {
            ForEach(MealPortionUnit.allCases, id: \.self) { unit in
              Text(unit.label).tag(unit)
            }
          }
          number("这一列对应的份量", value: $draft.basisGrams)
          Picker("能量单位", selection: $draft.energyUnit) {
            Text("请选择").tag(nil as PackagedNutritionLabel.EnergyUnit?)
            ForEach(PackagedNutritionLabel.EnergyUnit.allCases, id: \.self) { unit in
              Text(unit.rawValue).tag(Optional(unit))
            }
          }
          number("能量", value: $draft.energy)
          number("蛋白质（克）", value: $draft.protein)
          number("脂肪（克）", value: $draft.fat)
          number("碳水（克）", value: $draft.carbs)
        }
        Button("仅存入我的食品") { save(addToMeal: false) }.disabled(draft.portion == nil)
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
      }
      .disabled(analyzing || loading)
      .navigationTitle("包装食品营养表")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(analyzing)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }.disabled(analyzing)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存并加入") { save(addToMeal: true) }
            .disabled(analyzing || loading || draft.portion == nil)
        }
      }
      .sheet(isPresented: $showingSaved) {
        SavedFoodLabelPicker(storage: storage) { label in
          draft = label
          editingKey = label.catalogKey
          message = nil
        }
      }
      .sheet(isPresented: $showingCatalog) {
        PackagedCatalogPicker { entry in
          draft = PackagedNutritionLabel(name: entry.name, barcode: entry.barcode,
            source: entry.source, basisGrams: entry.portion.grams, basisUnit: entry.unit,
            energy: entry.kcal, energyUnit: .kcal, protein: entry.protein,
            fat: entry.fat, carbs: entry.carbs)
          editingKey = nil
          message = nil
        }
      }
      .task(id: attachments.items) {
        guard attachments.loading else { return }
        let items = attachments.items
        let result = await ModelPhotoSelection.load(items, maxPixelSize: 1800)
        guard !Task.isCancelled, items == attachments.items else { return }
        attachments.finish(result, for: items)
        if !items.isEmpty { filePhotos = [] }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.image],
                    allowsMultipleSelection: true) { result in
        switch result {
        case .success(let urls): Task { await loadFiles(urls) }
        case .failure: message = "无法打开营养表图片。"
        }
      }
    }
  }

  private func save(addToMeal: Bool) {
    guard let portion = draft.portion else { return }
    do {
      storage = try draft.saved(in: storage, replacing: editingKey)
      if addToMeal { onUse(portion) }
      dismiss()
    } catch {
      message = "无法保存到我的食品。原有标签已保留。"
    }
  }

  private func number(_ title: String, value: Binding<Double?>) -> some View {
    LabeledContent(title) {
      TextField(title, value: value, format: .number)
        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
    }
  }

  private func loadFiles(_ urls: [URL]) async {
    guard !urls.isEmpty, urls.count <= ModelPhotoSelection.limit else {
      message = "一次最多上传 \(ModelPhotoSelection.limit) 张图片。"
      return
    }
    loading = true
    defer { loading = false }
    let photos = await Task.detached(priority: .userInitiated) {
      urls.compactMap { url -> Data? in
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let input = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return mealJPEG(input, maxPixelSize: 1800)
      }
    }.value
    guard photos.count == urls.count else { message = "有营养表图片无法打开。"; return }
    attachments = ModelPhotoSelection()
    filePhotos = photos
    message = nil
  }

  private func analyze(_ photos: [Data]) async {
    guard let model else { message = "请先配置支持图片的 AI 模型，或手动填写。"; return }
    analyzing = true
    defer { analyzing = false }
    do {
      draft = try await PackagedNutritionLabel.read(photos: photos, model: model)
      editingKey = nil
      message = draft.basisGrams == nil
        ? "请填写与营养成分这一列对应的份量和单位。"
        : nil
    } catch { message = error.localizedDescription }
  }
}

private struct SavedFoodLabelPicker: View {
  let storage: Data
  let onUse: (PackagedNutritionLabel) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List(PackagedNutritionLabel.search(FoodSearchQuery(query), in: storage), id: \.catalogKey) { label in
        Button(label.displayName) {
          onUse(label)
          dismiss()
        }
      }
      .searchable(text: $query, prompt: "搜索名称、品牌或条码")
      .navigationTitle("我的食品")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
      }
    }
  }
}

private struct PackagedCatalogPicker: View {
  let onUse: (MealNutritionCatalog.Entry) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        ForEach(query.isEmpty ? MealNutritionCatalog.packaged : MealNutritionCatalog.searchPackaged(query),
                id: \.id) { entry in
          Button(entry.name) {
            onUse(entry)
            dismiss()
          }
        }
      }
      .searchable(text: $query, prompt: "搜索食品")
      .navigationTitle("内置营养表")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
      }
    }
  }
}
