import Foundation
import StockPlanShared

/// Static catalog of tracked everyday items per country. US entries map to
/// BLS average-price series (real prices); PT/EA entries map to Eurostat
/// COICOP classes (index YoY only, no price level); BR entries map to IPCA
/// subitems on SIDRA.
enum MacroItemsCatalog {
    enum SourceRef: Equatable {
        /// BLS average-price series mirrored on FRED (APU*).
        case fredSeries(String)
        /// Eurostat COICOP code on prc_hicp_manr (YoY rate, no price level).
        case eurostatCoicop(String)
        /// IBGE SIDRA c315 classification code on table 7060.
        case sidraClassification(String)
    }

    struct Item {
        let id: String
        let name: String
        let emoji: String
        let unit: String
        let sourceRef: SourceRef
        /// True when the source publishes a price level (vs an index/rate).
        var isPrice: Bool {
            if case .fredSeries = sourceRef {
                return true
            }
            return false
        }
    }

    /// US: BLS average prices (city average). Series IDs pinned from FRED.
    private static let usItems: [Item] = [
        Item(id: "eggs", name: "Eggs (Grade A, dozen)", emoji: "🥚", unit: "USD per dozen", sourceRef: .fredSeries("APU0000708111")),
        Item(id: "milk", name: "Milk (whole, gallon)", emoji: "🥛", unit: "USD per gallon", sourceRef: .fredSeries("APU0000709112")),
        Item(id: "bread", name: "Bread (white, lb)", emoji: "🍞", unit: "USD per lb", sourceRef: .fredSeries("APU0000702111")),
        Item(id: "gasoline", name: "Gasoline (regular, gallon)", emoji: "⛽", unit: "USD per gallon", sourceRef: .fredSeries("APU000074714")),
        Item(id: "chicken", name: "Chicken (whole, lb)", emoji: "🍗", unit: "USD per lb", sourceRef: .fredSeries("APU0000706111")),
        Item(id: "ground-beef", name: "Ground Beef (lb)", emoji: "🥩", unit: "USD per lb", sourceRef: .fredSeries("APU0000703112")),
        Item(id: "electricity", name: "Electricity (kWh)", emoji: "⚡", unit: "USD per kWh", sourceRef: .fredSeries("APU000072610")),
        Item(id: "coffee", name: "Coffee (ground roast, lb)", emoji: "☕", unit: "USD per lb", sourceRef: .fredSeries("APU0000717311")),
    ]

    /// PT/EA: HICP class-level YoY (index only — no shelf price published).
    private static let euroItems: [Item] = [
        Item(id: "bread", name: "Bread & Cereals", emoji: "🍞", unit: "percent", sourceRef: .eurostatCoicop("CP0111")),
        Item(id: "milk-cheese-eggs", name: "Milk, Cheese & Eggs", emoji: "🥛", unit: "percent", sourceRef: .eurostatCoicop("CP0114")),
        Item(id: "meat", name: "Meat", emoji: "🥩", unit: "percent", sourceRef: .eurostatCoicop("CP0112")),
        Item(id: "fuels", name: "Fuels & Lubricants", emoji: "⛽", unit: "percent", sourceRef: .eurostatCoicop("CP0722")),
        Item(id: "electricity", name: "Electricity", emoji: "⚡", unit: "percent", sourceRef: .eurostatCoicop("CP0451")),
        Item(id: "coffee", name: "Coffee, Tea & Cocoa", emoji: "☕", unit: "percent", sourceRef: .eurostatCoicop("CP0121")),
    ]

    /// BR: IPCA subitem/group classifications (SIDRA table 7060, c315 codes).
    /// Group-level codes pinned; finer subitems can be added once verified.
    private static let brazilItems: [Item] = [
        Item(id: "alimentos", name: "Alimentação e bebidas", emoji: "🍚", unit: "percent", sourceRef: .sidraClassification("7170")),
        Item(id: "habitacao", name: "Habitação", emoji: "🏠", unit: "percent", sourceRef: .sidraClassification("7445")),
        Item(id: "transportes", name: "Transportes", emoji: "🚌", unit: "percent", sourceRef: .sidraClassification("7625")),
        Item(id: "saude", name: "Saúde e cuidados pessoais", emoji: "💊", unit: "percent", sourceRef: .sidraClassification("7660")),
    ]

    static func items(for country: MacroCountry) -> [Item] {
        switch country {
        case .us: usItems
        case .pt, .es, .de, .fr, .it, .ea: euroItems
        case .br: brazilItems
        }
    }

    static func item(id: String, country: MacroCountry) -> Item? {
        items(for: country).first { $0.id == id }
    }
}
