import time
from pathlib import Path
import psycopg2

DATA_DIR = Path("data/raw")

# Postgres'e bağlan (kendi bilgisayarında olduğu için şifre gerekmiyor)
conn = psycopg2.connect(dbname="homecredit")
conn.autocommit = True
cur = conn.cursor()

for csv_path in sorted(DATA_DIR.glob("*.csv")):
    table = csv_path.stem.lower()          # "application_train.csv" -> "application_train"
    if table == "sample_submission":
        continue                           # bu dosyayı yüklemiyoruz

    # 1) Sadece ilk satırı (başlık) oku
    with open(csv_path, encoding="latin-1") as f:
        header = f.readline().strip().split(",")

    # 2) Sütun adlarını temizle: tırnakları at, küçük harfe çevir
    columns = []
    for i, name in enumerate(header):
        name = name.strip().strip('"').lower()
        columns.append(name if name else f"col_{i}")   # boş başlık varsa isim ver

    # 3) CREATE TABLE komutunu üret: her sütun TEXT
    cols_sql = ", ".join(f'"{c}" TEXT' for c in columns)
    cur.execute(f"DROP TABLE IF EXISTS raw.{table}")
    cur.execute(f"CREATE TABLE raw.{table} ({cols_sql})")

    # 4) Veriyi COPY ile yükle
    start = time.time()
    with open(csv_path, encoding="latin-1") as f:
        cur.copy_expert(
            f"COPY raw.{table} FROM STDIN WITH (FORMAT csv, HEADER true)", f
        )

    # 5) Kontrol: kaç satır yüklendi?
    cur.execute(f"SELECT COUNT(*) FROM raw.{table}")
    count = cur.fetchone()[0]
    print(f"{table}: {count:,} satır, {time.time() - start:.1f} sn")

conn.close()