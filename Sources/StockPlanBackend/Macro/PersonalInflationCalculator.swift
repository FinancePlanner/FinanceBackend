import Foundation
import StockPlanShared

enum PersonalInflationCalculator {
    struct ExpenseInput: Equatable {
        let category: String?
        let title: String
        let amount: Double
    }

    private enum SpendingFamily {
        case foodHome
        case restaurants
        case rent
        case ownedHousing
        case electricity
        case utilityGas
        case transport
        case health
        case apparel
        case recreation
        case communications
        case education
        case household
    }

    private struct Accumulator {
        let category: String
        let macroCategory: String
        let inflationRate: Double
        var spend: Double
        var expenseCount: Int
    }

    static func calculate(
        expenses: [ExpenseInput],
        snapshot: InflationSnapshotResponse,
        country: MacroCountry,
        periodMonths: Int,
        sampleStart: Date,
        sampleEnd: Date
    ) -> PersonalInflationResponse {
        let totalSpend = expenses.reduce(0) { $0 + $1.amount }
        var mapped: [String: Accumulator] = [:]

        for expense in expenses {
            guard let family = family(for: expense),
                  let component = component(for: family, country: country, in: snapshot.components)
            else { continue }
            let category = expense.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayCategory = category.flatMap { $0.isEmpty ? nil : $0 } ?? component.category
            let key = displayCategory.lowercased() + "|" + component.category.lowercased()
            if var current = mapped[key] {
                current.spend += expense.amount
                current.expenseCount += 1
                mapped[key] = current
            } else {
                mapped[key] = Accumulator(
                    category: displayCategory,
                    macroCategory: component.category,
                    inflationRate: component.ourYoY,
                    spend: expense.amount,
                    expenseCount: 1
                )
            }
        }

        let mappedSpend = mapped.values.reduce(0) { $0 + $1.spend }
        let components = mapped.values.map { item in
            let weight = mappedSpend > 0 ? item.spend / mappedSpend * 100 : 0
            return PersonalInflationComponentDTO(
                category: item.category,
                macroCategory: item.macroCategory,
                spend: rounded(item.spend),
                weight: rounded(weight),
                inflationRate: rounded(item.inflationRate),
                contribution: rounded(weight / 100 * item.inflationRate),
                expenseCount: item.expenseCount
            )
        }.sorted { lhs, rhs in
            if lhs.spend == rhs.spend {
                return lhs.category < rhs.category
            }
            return lhs.spend > rhs.spend
        }

        let personalRate: Double? = mappedSpend > 0
            ? rounded(components.reduce(0) { $0 + $1.contribution })
            : nil
        let monthlySpend = totalSpend / Double(periodMonths)
        let formatter = dayFormatter
        return PersonalInflationResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: snapshot.asOf,
            periodMonths: periodMonths,
            sampleStart: formatter.string(from: sampleStart),
            sampleEnd: formatter.string(from: sampleEnd),
            personalRate: personalRate,
            officialRate: rounded(snapshot.headline.nowValue),
            difference: personalRate.map { rounded($0 - snapshot.headline.nowValue) },
            averageMonthlySpend: rounded(monthlySpend),
            estimatedAnnualImpact: personalRate.map { rounded(monthlySpend * 12 * $0 / 100) },
            coveragePercent: totalSpend > 0 ? rounded(mappedSpend / totalSpend * 100) : 0,
            mappedSpend: rounded(mappedSpend),
            totalSpend: rounded(totalSpend),
            expenseCount: expenses.count,
            method: "expense_weighted_cpi_v1",
            source: "User expenses + \(snapshot.source)",
            components: components
        )
    }

    private static func family(for expense: ExpenseInput) -> SpendingFamily? {
        let value = [expense.category, expense.title]
            .compactMap(\.self)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if contains(value, any: ["grocery", "groceries", "supermarket", "food shop", "mercado", "alimentacao"]) {
            return .foodHome
        }
        if contains(value, any: ["dining", "restaurant", "cafe", "coffee", "takeout", "delivery", "hotel"]) {
            return .restaurants
        }
        if contains(value, any: ["mortgage", "home loan", "hipoteca"]) {
            return .ownedHousing
        }
        if contains(value, any: ["rent", "renda", "aluguel"]) {
            return .rent
        }
        if contains(value, any: ["natural gas", "utility gas", "gas bill"]) {
            return .utilityGas
        }
        if contains(value, any: ["utility", "utilities", "electric", "power bill", "water bill", "energia", "luz", "agua"]) {
            return .electricity
        }
        if contains(value, any: ["transport", "transit", "fuel", "gasoline", "petrol", "commute", "uber", "taxi", "car", "viagem"]) {
            return .transport
        }
        if contains(value, any: ["health", "medical", "doctor", "pharmacy", "saude"]) {
            return .health
        }
        if contains(value, any: ["clothing", "clothes", "apparel", "vestuario"]) {
            return .apparel
        }
        if contains(value, any: ["entertainment", "recreation", "streaming", "subscription", "cinema", "gym", "lazer"]) {
            return .recreation
        }
        if contains(value, any: ["phone", "internet", "communication", "mobile", "telefone"]) {
            return .communications
        }
        if contains(value, any: ["education", "school", "tuition", "course", "educacao"]) {
            return .education
        }
        if contains(value, any: ["furniture", "furnishing", "household", "home goods"]) {
            return .household
        }
        return nil
    }

    private static func component(
        for family: SpendingFamily,
        country: MacroCountry,
        in components: [InflationComponentDTO]
    ) -> InflationComponentDTO? {
        // Every euro-area country shares the COICOP division labels Eurostat
        // returns, so they share one basket mapping.
        let basket: MacroCountry = country.isEuroArea ? .ea : country
        let patterns: [String] = switch (basket, family) {
        case (.us, .foodHome): ["food at home"]
        case (.us, .restaurants): ["food away"]
        case (.us, .rent): ["shelter: rent"]
        case (.us, .ownedHousing): ["shelter: owned"]
        case (.us, .electricity): ["electricity"]
        case (.us, .utilityGas): ["utility gas"]
        case (.us, .transport): ["motor fuel"]
        case (.us, .health): ["medical care"]
        case (.us, .apparel): ["apparel"]
        case (.us, .recreation): ["recreation"]
        case (.us, .communications), (.us, .education): ["education & comm"]
        case (.us, .household): []
        case (.br, .foodHome), (.br, .restaurants): ["alimentacao e bebidas"]
        case (.br, .rent), (.br, .ownedHousing), (.br, .electricity), (.br, .utilityGas): ["habitacao"]
        case (.br, .transport): ["transportes"]
        case (.br, .health): ["saude e cuidados pessoais"]
        case (.br, .apparel): ["vestuario"]
        case (.br, .recreation): ["despesas pessoais"]
        case (.br, .communications): ["comunicacao"]
        case (.br, .education): ["educacao"]
        case (.br, .household): ["artigos de residencia"]
        case (.ea, .foodHome): ["food and non-alcoholic"]
        case (.ea, .restaurants): ["restaurants and hotels"]
        case (.ea, .rent), (.ea, .ownedHousing),
             (.ea, .electricity), (.ea, .utilityGas): ["housing, water, electricity"]
        case (.ea, .transport): ["transport"]
        case (.ea, .health): ["health"]
        case (.ea, .apparel): ["clothing and footwear"]
        case (.ea, .recreation): ["recreation and culture"]
        case (.ea, .communications): ["communications"]
        case (.ea, .education): ["education"]
        case (.ea, .household): ["furnishings and household"]
        // Unreachable: `basket` folds every euro-area country into `.ea` above.
        case (.pt, _), (.es, _), (.de, _), (.fr, _), (.it, _): []
        }
        return components.first { component in
            let normalized = component.category
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            return patterns.contains { normalized.contains($0) }
        }
    }

    private static func contains(_ value: String, any candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
