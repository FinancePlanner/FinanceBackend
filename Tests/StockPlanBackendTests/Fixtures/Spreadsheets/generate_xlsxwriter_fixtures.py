"""Second fixture set, written with XlsxWriter so we get the things openpyxl
never produces: a real sharedStrings.xml, cached formula values, and a
1904-date-system workbook."""
import datetime as dt
import os

import xlsxwriter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
os.makedirs(OUT, exist_ok=True)


def excel_like(path, date_1904=False):
    wb = xlsxwriter.Workbook(path, {"default_date_format": "dd/mm/yyyy"})
    if date_1904:
        wb.set_properties({})
        wb.date_1904 = True

    bold = wb.add_format({"bold": True})
    date_fmt = wb.add_format({"num_format": "dd/mm/yyyy"})
    eur = wb.add_format({"num_format": '#,##0.00 "€"'})

    ws = wb.add_worksheet("Despesas")
    # header on row 4 (0-indexed 3), data starting at column D (index 3)
    for i, h in enumerate(["Data", "Descricao", "Categoria", "Valor"]):
        ws.write(3, 3 + i, h, bold)

    rows = [
        (dt.date(2026, 1, 3), "Continente", "Supermercado", 84.20),
        (dt.date(2026, 1, 5), "Netflix", "Lazer", 13.99),
        (dt.date(2026, 1, 11), "Renda", "Casa", 750.00),
        (dt.date(2026, 2, 2), "Galp", "Transportes", 61.40),
        (dt.date(2026, 2, 14), "Jantar fora", "Lazer", 45.00),
    ]
    r = 4
    for d, desc, cat, val in rows:
        ws.write_datetime(r, 3, d, date_fmt)
        ws.write_string(r, 4, desc)
        ws.write_string(r, 5, cat)
        ws.write_number(r, 6, val, eur)
        r += 1

    # total row WITH a cached value -- this is what real Excel writes
    ws.write_string(r, 5, "TOTAL", bold)
    ws.write_formula(r, 6, f"=SUM(G5:G{r})", eur, 954.59)
    wb.close()


excel_like(os.path.join(OUT, "excel-like.xlsx"))
excel_like(os.path.join(OUT, "excel-like-1904.xlsx"), date_1904=True)
print("wrote:", sorted(os.listdir(OUT)))
