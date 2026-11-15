import Foundation
import NaturalLanguage

struct MealPortionDraft {
  let reference: MealFoodEstimate
  var name: String
  var weightInput: String

  init(_ reference: MealFoodEstimate) {
    self.reference = reference
    name = reference.name
    weightInput = reference.grams.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
  }

  var estimate: MealFoodEstimate {
    let weight = try? Double(weightInput.trimmingCharacters(in: .whitespacesAndNewlines), format: .number)
    var result = reference.scaled(to: weight ?? .nan)
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return result
  }
}

extension MealFoodEstimate {
  func scaled(to weight: Double) -> Self {
    let ratio = weight / grams
    return Self(name: name, grams: weight, kcal: kcal * ratio, protein: protein * ratio,
                fat: fat * ratio, carbs: carbs * ratio, reference: reference, unit: unit)
  }

  static func estimate(description: String, photos: [Data], model: DirectModelConfiguration) async throws -> [Self] {
    let prompt = """
    此编辑器只记录一顿饭。估算这顿饭实际吃下的部分；如果文字或照片明确包含早餐、午餐、晚餐等多顿饭，返回 {"multiple_meals":true,"items":[]}，由用户分餐记录。
    结合照片中的大小参照、容器和食物，与用户提供的菜名、做法、已知克数、吃剩比例。
    已知重量优先。多张照片可以是同一餐不同角度、不同菜品或包装标签；同一份食物只计一次。区分生重、熟重、骨皮和实际可食部分。
    按菜品返回可食克数、热量、蛋白质、脂肪、碳水，营养数字是该份量的合计。
    中国家常菜使用真实中文菜名（如番茄炒蛋、青椒肉丝），不改成欧美餐馆版本。
    每项另给一个用于营养表查询的英文 search，包含主要食材及生熟或做法，例如 white rice cooked。
    不把一般热量值当成包装营养标签。无法辨认且描述不足时返回空数组。最多 20 项。
    仅返回 JSON：{"items":[{"name":"米饭","grams":150,"kcal":195,"protein":4,"fat":0.4,"carbs":42,"search":"white rice cooked"}]}。
    用户描述：\(description)
    """
    struct IdentifiedFood: Decodable {
      let estimate: MealFoodEstimate
      let search: String?

      init(from decoder: Decoder) throws {
        estimate = try MealFoodEstimate(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        search = try values.decodeIfPresent(String.self, forKey: .search)
      }
      private enum CodingKeys: String, CodingKey { case search }
    }
    struct Response: Decodable {
      let items: [IdentifiedFood]
      let multiple_meals: Bool?
    }
    let text = try await model.completeMeal(prompt: prompt, photos: photos)
    let response: Response? = decodeMealJSON(text)
    if response?.multiple_meals == true {
      throw APIClient.APIError.message("这里有多顿饭。请按餐次分别记录。")
    }
    guard let response, !response.items.isEmpty,
      response.items.count <= 20, response.items.allSatisfy({ $0.estimate.isValid }) else {
      throw APIClient.APIError.message("没能得出可用的估算。请补充菜名、份量或实际吃了多少，再试一次。")
    }
    let originals = response.items.map(\.estimate)
    let queries = response.items.map { $0.search ?? "" }
    let names = originals.map(\.name)
    let candidates = await Task.detached(priority: .userInitiated) {
      zip(names, queries).map { MealNutritionCatalog.matches(name: $0.0, query: $0.1) }
    }.value
    guard candidates.contains(where: { !$0.isEmpty }) else { return originals }

    let groups = candidates.indices.compactMap { index -> String? in
      guard !candidates[index].isEmpty else { return nil }
      let rows = candidates[index].map { entry in
        "\(entry.id) \(entry.name)（\(entry.source ?? "USDA")）[\(entry.kcal) kcal, P \(entry.protein), F \(entry.fat), C \(entry.carbs)]"
      }.joined(separator: "\n")
      return "index \(index) · \(originals[index].name) · \(queries[index])\n\(rows)"
    }.joined(separator: "\n\n")
    let selectionPrompt = """
    为每道菜选一个可信的参考条目。数值均为每100克。中国家常菜优先使用同名或同做法的「中式家常配方参考」，
    不要用欧美餐馆版替代；已知油量或配方明显不同时，不套用标准配方。
    包装食品仅在品牌、规格或口味相符时使用对应标签。用户上传的实际标签优先。
    生熟、部位、烹饪方式和配料必须相符；只匹配到主食材、油量或配方差异明显、或没有合适条目时省略该菜。
    仅返回 JSON：{"matches":[{"index":0,"id":123}]}。id 只能从该 index 下的候选列表选。不要重新计算重量。
    \(groups)
    """
    struct Selection: Decodable { let index: Int; let id: Int }
    struct Selections: Decodable { let matches: [Selection] }
    guard let selectedText = try? await model.completeMeal(prompt: selectionPrompt, photos: [], timeout: 12),
      let selected: Selections = decodeMealJSON(selectedText) else { return originals }
    var result = originals
    for match in selected.matches where candidates.indices.contains(match.index) {
      guard let entry = candidates[match.index].first(where: { $0.id == match.id }) else { continue }
      let food = originals[match.index]
      let reference = MealFoodEstimate(name: food.name, grams: 100, kcal: entry.kcal,
        protein: entry.protein, fat: entry.fat, carbs: entry.carbs,
        reference: (entry.source ?? "USDA") + " · " + entry.name)
      let estimate = reference.scaled(to: food.grams)
      if estimate.isValid { result[match.index] = estimate }
    }
    return result
  }
}

func decodeMealJSON<T: Decodable>(_ text: String) -> T? {
  guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end
  else { return nil }
  return try? JSONDecoder().decode(T.self, from: Data(text[start...end].utf8))
}

struct FoodSearchQuery {
  static let rankCount = 24

  struct Field {
    let text: String
    fileprivate let whole: Term
    fileprivate let words: [Term]

    init(_ value: String) {
      text = FoodSearchQuery.normalize(value)
      whole = Term(text)

      if whole.isNumber || text.isEmpty {
        words = []
      } else if whole.hasHan {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value
        tokenizer.setLanguage(.simplifiedChinese)
        var tokens: [Term] = []
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
          let token = FoodSearchQuery.normalize(String(value[range]))
          if !token.isEmpty { tokens.append(Term(token)) }
          return true
        }
        words = tokens
      } else {
        words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
          .map { Term(FoodSearchQuery.normalize(String($0))) }
      }
    }

    fileprivate func match(_ query: Term) -> TypoMatch? {
      var best = query.match(whole.characters, hasHan: whole.hasHan, isNumber: whole.isNumber)
      for (index, word) in words.enumerated() {
        best = TypoMatch.better(best, query.match(word.characters, hasHan: word.hasHan, isNumber: word.isNumber))
        guard query.hasHan, word.hasHan else { continue }
        var phrase = word.characters
        // A food name can span several words in the Chinese tokenizer.
        for next in words.dropFirst(index + 1) {
          guard next.hasHan, phrase.count + next.characters.count <= query.characters.count + query.maxEdits
          else { break }
          phrase.append(contentsOf: next.characters)
          best = TypoMatch.better(best, query.match(phrase, hasHan: true, isNumber: false))
        }
      }
      return best
    }
  }

  fileprivate struct TypoMatch: Comparable {
    let edits: Int
    let similarity: Double

    static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.edits == rhs.edits ? lhs.similarity > rhs.similarity : lhs.edits < rhs.edits
    }

    static func better(_ lhs: Self?, _ rhs: Self?) -> Self? {
      guard let lhs else { return rhs }
      guard let rhs else { return lhs }
      return min(lhs, rhs)
    }
  }

  fileprivate struct Term {
    let text: String
    let characters: [UInt32]
    let hasHan: Bool
    let isNumber: Bool

    // Meilisearch documents 2/4 as a supported setup for short product names.
    var maxEdits: Int {
      guard !isNumber, characters.count <= 48 else { return 0 }
      if characters.count >= 4 { return 2 }
      return characters.count >= 2 ? 1 : 0
    }

    init(_ normalized: String) {
      text = normalized
      characters = normalized.unicodeScalars.map(\.value)
      hasHan = normalized.unicodeScalars.contains { $0.properties.isIdeographic }
      isNumber = !normalized.isEmpty && normalized.allSatisfy(\.isNumber)
    }

    func match(_ candidate: [UInt32], hasHan: Bool, isNumber: Bool) -> TypoMatch? {
      let limit = maxEdits
      guard limit > 0, !isNumber, hasHan == self.hasHan,
        abs(characters.count - candidate.count) <= limit, !candidate.isEmpty else { return nil }

      // Lucene FuzzyQuery uses optimal string alignment, where a neighboring
      // transposition counts as one edit in addition to insert/delete/replace.
      var beforePrevious = Array(0...candidate.count)
      var previous = beforePrevious
      var current = beforePrevious
      for (i, character) in characters.enumerated() {
        current[0] = i + 1
        for (j, other) in candidate.enumerated() {
          let replace = previous[j] + (character == other ? 0 : 1)
          current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, replace)
          if i > 0, j > 0, character == candidate[j - 1], characters[i - 1] == other {
            current[j + 1] = min(current[j + 1], beforePrevious[j - 1] + 1)
          }
        }
        swap(&beforePrevious, &previous)
        swap(&previous, &current)
      }
      let distance = previous[candidate.count]
      let shorter = min(characters.count, candidate.count)
      guard distance <= limit, distance < shorter else { return nil }
      return TypoMatch(edits: distance, similarity: 1 - Double(distance) / Double(shorter))
    }
  }

  let normalized: String
  private let terms: [Term]

  init(_ text: String) {
    normalized = Self.normalize(text)
    terms = text.split(whereSeparator: \.isWhitespace)
      .map { Term(Self.normalize(String($0))) }.filter { !$0.text.isEmpty }
  }

  static func normalize(_ value: String) -> String {
    if value.utf8.allSatisfy({ $0 < 128 }) {
      return value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
    return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
      .filter { $0.isLetter || $0.isNumber }
  }

  func score(_ fields: [Field]) -> Int {
    guard !normalized.isEmpty else { return 0 }
    if fields.contains(where: { $0.text == normalized }) { return 23 }
    if normalized.allSatisfy(\.isNumber) { return 0 }

    let names = fields.filter { !$0.whole.isNumber }
    if names.contains(where: { $0.text.hasPrefix(normalized) }) { return 22 }

    var edits = 0
    var similarity = 1.0
    for term in terms {
      if names.contains(where: { $0.text.contains(term.text) })
        || (term.isNumber && fields.contains(where: { $0.text == term.text })) { continue }
      guard let match = names.lazy.compactMap({ $0.match(term) }).min() else { return 0 }
      edits += match.edits
      if edits > 2 { return 0 }
      similarity = min(similarity, match.similarity)
    }
    if edits == 0 { return 21 }
    return (edits == 1 ? 11 : 1) + Int(9 * similarity)
  }
}

enum MealNutritionCatalog {
  struct Entry: Decodable, Sendable {
    let id: Int
    let name: String
    let kcal: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    let aliases: [String]?
    let source: String?
    let unit: MealPortionUnit?
    let barcode: String?
    let quantity: String?
    let sourceURL: URL?

    var portion: MealFoodEstimate {
      MealFoodEstimate(name: name, grams: unit == .servings ? 1 : 100, kcal: kcal,
        protein: protein, fat: fat, carbs: carbs, reference: source ?? "USDA", unit: unit)
    }
  }

  private static func load(_ resource: String) -> [Entry] {
    guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
    return entries
  }

  private static let home = load("ChineseHomeNutritionCatalog")
  private static let chinese = load("ChineseFoodNutritionCatalog")
  static let chinaPackagedURL = Bundle.main.url(forResource: "ChinaPackagedFoodCatalog", withExtension: "json")
  static let packaged: [Entry] = {
    let official = load("ManufacturerPackagedFoodCatalog")
    let officialCodes = Set(official.compactMap(\.barcode))
    let community = load("ChinaPackagedFoodCatalog").filter { entry in
      guard let code = entry.barcode else { return true }
      return !officialCodes.contains(code)
    }
    return community + official + home.filter { $0.source?.hasPrefix("包装标签") == true }
  }()
  private static let packagedIndex = packaged.map { entry in
    (entry: entry, fields: ([entry.name] + (entry.aliases ?? []) + [entry.barcode ?? ""])
      .map(FoodSearchQuery.Field.init))
  }
  private static let index = load("FoodNutritionCatalog").map { (entry: $0, tokens: tokens($0.name)) }
  private static let chineseIndex = (chinese + home).map { entry in
    (entry: entry, names: ([entry.name] + (entry.aliases ?? [])).map(FoodSearchQuery.normalize))
  }
  private static let searchable = (chinese + home.filter { $0.source?.hasPrefix("包装标签") != true }
                                   + index.map(\.entry)).map { entry in
    (entry: entry, fields: ([entry.name] + (entry.aliases ?? [])).map(FoodSearchQuery.Field.init))
  }

  private static func tokens(_ name: String) -> Set<String> {
    Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init).filter { $0.count > 1 && !["of", "the", "and", "with"].contains($0) })
  }

  static func search(_ query: String) -> [Entry] {
    ranked(FoodSearchQuery(query), in: searchable)
  }

  static func searchPackaged(_ query: String) -> [Entry] {
    let query = FoodSearchQuery(query)
    guard ["减肥", "减肥食品", "减脂", "减脂食品", "轻食"].contains(query.normalized) else {
      return ranked(query, in: packagedIndex)
    }
    let focus = Set(["代餐", "蛋白棒", "魔芋", "即食鸡胸肉", "希腊酸奶"])
    let featured = packagedIndex.filter { !focus.isDisjoint(with: $0.fields.lazy.map(\.text)) }
    let other = packagedIndex.filter { focus.isDisjoint(with: $0.fields.lazy.map(\.text)) }
    return ranked(query, in: featured + other, limit: 60)
  }

  private static func ranked(_ query: FoodSearchQuery, in candidates: [(entry: Entry, fields: [FoodSearchQuery.Field])],
                             limit: Int = 30) -> [Entry] {
    guard !query.normalized.isEmpty else { return [] }
    var ranked = [[Entry]](repeating: [], count: FoodSearchQuery.rankCount)
    for candidate in candidates {
      let score = query.score(candidate.fields)
      if score > 0 && ranked[score].count < limit {
        ranked[score].append(candidate.entry)
      }
    }
    return Array(ranked.reversed().joined().prefix(limit))
  }

  static func matches(name: String, query: String) -> [Entry] {
    let normalized = FoodSearchQuery.normalize(name)
    let homeMatches = chineseIndex.compactMap { candidate -> (Entry, Int)? in
      guard candidate.entry.portion.portionUnit == .grams else { return nil }
      if candidate.names.contains(normalized) { return (candidate.entry, 2) }
      if candidate.names.contains(where: { $0.count >= 3 && normalized.contains($0) }) {
        return (candidate.entry, 1)
      }
      return nil
    }
    .sorted { $0.1 == $1.1 ? $0.0.id > $1.0.id : $0.1 > $1.1 }
    .prefix(4).map(\.0)
    let words = tokens(String(query.prefix(140)))
    guard !words.isEmpty else { return homeMatches }
    let international = index.compactMap { candidate -> (Entry, Double)? in
      let overlap = words.intersection(candidate.tokens).count
      guard overlap >= min(2, words.count) else { return nil }
      let score = Double(overlap) * 2 / Double(words.count + candidate.tokens.count)
      return (candidate.entry, score)
    }
    .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
    .prefix(8 - homeMatches.count).map(\.0)
    return homeMatches + international
  }
}
