#!/usr/bin/env bash
# =====================================================================
# Tableau için metrik view'larını CSV olarak dışa aktarır.
# Kullanım (proje klasöründe):  bash scripts/export_tableau.sh
#
# Çıktı: data/tableau/*.csv  (data/ klasörü .gitignore'da, Git'e gitmez)
# Not: \copy istemci tarafında çalışır; dosya senin bilgisayarına yazılır.
# =====================================================================

set -euo pipefail

DB="homecredit"
OUT="data/tableau"
mkdir -p "$OUT"

export_view () {
    local view="$1"
    local file="$2"
    echo "-> $view  →  $OUT/$file"
    psql "$DB" -q -c "\copy (SELECT * FROM $view) TO '$OUT/$file' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')"
}

export_view metrics.v_dashboard_musteri   musteri.csv
export_view metrics.v_portfoy_kpi         portfoy_kpi.csv
export_view metrics.v_segment_temerrut    segment_temerrut.csv
export_view metrics.v_basvuru_hunisi      basvuru_hunisi.csv
export_view metrics.v_red_nedenleri       red_nedenleri.csv
export_view metrics.mv_dpd_dagilimi       dpd_dagilimi.csv
export_view metrics.mv_roll_rate          roll_rate.csv
export_view metrics.mv_veri_kalitesi      veri_kalitesi.csv

echo
echo "Tamamlandı. Dosyalar ve satır sayıları (başlık satırı dahil):"
wc -l "$OUT"/*.csv
