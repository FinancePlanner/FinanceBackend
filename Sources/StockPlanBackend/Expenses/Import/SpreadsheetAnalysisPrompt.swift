import Foundation

/// Prompts for the spreadsheet mapping call.
///
/// The system message is a constant so it can be prompt-cached across requests,
/// matching the convention in `AIPrompt`. It states the constraints the
/// validator enforces anyway — asking for valid output is cheaper than
/// discarding invalid output, but the validator is what makes it safe.
enum SpreadsheetAnalysisPrompt {
    static let system = """
    You map a personal-finance spreadsheet onto a fixed expense model. You are \
    given a digest of one workbook: sheets, their columns, each column's header \
    and detected type, and a small sample of values. You never see the whole file.

    Respond with a single JSON object and nothing else:
    {
      "sheet": string|null,            // name of the sheet holding expense rows
      "columns": [                     // one entry per column you can identify
        {"column": string,             // column letter exactly as given, e.g. "G"
         "field": string,              // one of: title, amount, date, category,
                                       // pillar, notes, currency, externalId, ignore
         "confidence": number}         // 0..1
      ],
      "categories": [                  // one entry per distinct value of the category column
        {"sourceValue": string,        // the value as it appears in the sheet
         "pillar": string|null,        // MUST be one of allowedPillars, else null
         "categoryName": string|null,  // prefer an existing category name when one fits
         "confidence": number}
      ],
      "notes": [string],               // short, user-facing observations
      "confidence": number             // 0..1 for the mapping overall
    }

    Rules:
    - Use only column letters that appear in the digest.
    - "pillar" must be null unless it exactly matches one of allowedPillars. \
    Never invent a pillar. A null pillar is correct and expected; the user will choose.
    - Prefer an existing category name over a new one when the meaning matches.
    - Judge by the sampled values, not the header alone. A column headed "Date" \
    whose values are not dates is not the date column.
    - A column of totals or a derived column (for example an amount multiplied \
    by a tax rate) is "ignore", not "amount".
    - Set a low confidence when unsure. Do not guess to fill a field.
    - "notes" is for things worth telling the person importing, such as an \
    ambiguous date format or a column you could not identify. Keep each under 100 characters.
    """

    static func user(digestJSON: String) -> String {
        """
        Map this workbook. Return only the JSON object.

        \(digestJSON)
        """
    }
}
