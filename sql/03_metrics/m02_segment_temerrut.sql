-- =====================================================================
-- metrics.v_segment_temerrut
-- Kaynak: core.musteri
-- Grain: 1 satır = 1 boyut × 1 segment (uzun format)
-- Amaç: Dashboard'daki tüm segment kırılımları tek view'dan beslenir.
--       Dashboard'da "boyut" filtresiyle istenen kırılım seçilir.
--
-- Kolonlar:
--   musteri, musteri_payi (boyut içinde %)
--   temerrut_orani (%), genel_orandan_fark (puan),
--   lift (segment oranı / genel oran; 1,5 = genelin 1,5 katı riskli)
--   kucuk_orneklem = 1 → müşteri < 500, oran yorumlanmamalı (varsayım)
--
-- Teknik: CROSS JOIN LATERAL (VALUES ...) her müşteriyi her boyut için
--         bir kez çoğaltır (unpivot). Böylece 10 ayrı GROUP BY + UNION ALL
--         yazmak yerine tek GROUP BY yeterli olur.
-- =====================================================================

CREATE OR REPLACE VIEW metrics.v_segment_temerrut AS
WITH taban AS (
    SELECT
        target,
        amt_credit,
        name_income_type,
        name_education_type,
        name_contract_type,
        name_family_status,
        COALESCE(code_gender, 'Bilinmiyor')                         AS cinsiyet,
        COALESCE(occupation_type, 'Bilinmiyor')                     AS meslek,
        CASE
            WHEN yas < 25 THEN '1) 25 altı'
            WHEN yas < 35 THEN '2) 25-34'
            WHEN yas < 45 THEN '3) 35-44'
            WHEN yas < 55 THEN '4) 45-54'
            ELSE               '5) 55 ve üstü'
        END                                                         AS yas_grubu,
        'Q' || NTILE(5) OVER (ORDER BY amt_income_total)            AS gelir_dilimi,
        CASE
            WHEN taksit_gelir_orani < 0.10 THEN '1) %10 altı'
            WHEN taksit_gelir_orani < 0.20 THEN '2) %10-20'
            WHEN taksit_gelir_orani < 0.30 THEN '3) %20-30'
            WHEN taksit_gelir_orani IS NULL THEN '9) Bilinmiyor'
            ELSE                                '4) %30 ve üstü'
        END                                                         AS dsr_grubu,
        CASE WHEN buro_kaydi_var = 1
             THEN 'Var' ELSE 'Yok' END                              AS kredi_gecmisi,
        CASE WHEN onceki_basvuru_var = 1
             THEN 'Mevcut müşteri' ELSE 'Yeni müşteri' END          AS musteri_tipi
    FROM core.musteri
)
SELECT
    d.boyut,
    d.segment,
    COUNT(*)                                                        AS musteri,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY d.boyut), 2)
                                                                    AS musteri_payi,
    SUM(t.target)                                                   AS temerrut_sayisi,
    ROUND(100.0 * AVG(t.target), 2)                                 AS temerrut_orani,
    ROUND(100.0 * AVG(t.target)
          - 100.0 * SUM(SUM(t.target)) OVER (PARTITION BY d.boyut)
                  / SUM(COUNT(*))      OVER (PARTITION BY d.boyut), 2)
                                                                    AS genel_orandan_fark,
    ROUND(AVG(t.target)
          / (SUM(SUM(t.target)) OVER (PARTITION BY d.boyut)
             / SUM(COUNT(*))    OVER (PARTITION BY d.boyut)), 2)    AS lift,
        ROUND(SUM(t.target)
          - COUNT(*) * SUM(SUM(t.target)) OVER (PARTITION BY d.boyut)
                     / SUM(COUNT(*))      OVER (PARTITION BY d.boyut), 0)
                                                                    AS fazla_temerrut,
    SUM(t.amt_credit)                                               AS toplam_kredi_tutari,
    CASE WHEN COUNT(*) < 500 THEN 1 ELSE 0 END                      AS kucuk_orneklem
FROM taban t
CROSS JOIN LATERAL (VALUES
    ('Gelir türü',      t.name_income_type),
    ('Eğitim',          t.name_education_type),
    ('Ürün türü',       t.name_contract_type),
    ('Medeni durum',    t.name_family_status),
    ('Cinsiyet',        t.cinsiyet),
    ('Meslek',          t.meslek),
    ('Yaş grubu',       t.yas_grubu),
    ('Gelir dilimi',    t.gelir_dilimi),
    ('Taksit/gelir',    t.dsr_grubu),
    ('Kredi geçmişi',   t.kredi_gecmisi),
    ('Müşteri tipi',    t.musteri_tipi)
) AS d(boyut, segment)
GROUP BY d.boyut, d.segment;


-- =====================================================================
-- Kontrol
-- =====================================================================
-- 1) Her boyutta toplam müşteri 307.511 olmalı:
-- SELECT boyut, SUM(musteri) FROM metrics.v_segment_temerrut GROUP BY 1;
--
-- 2) Örnek kırılım:
-- SELECT * FROM metrics.v_segment_temerrut
-- WHERE boyut = 'Yaş grubu' ORDER BY segment;
--
-- 3) En riskli segmentler (yeterli örneklemle):
-- SELECT boyut, segment, musteri, temerrut_orani, lift
-- FROM metrics.v_segment_temerrut
-- WHERE kucuk_orneklem = 0
-- ORDER BY lift DESC
-- LIMIT 10;
