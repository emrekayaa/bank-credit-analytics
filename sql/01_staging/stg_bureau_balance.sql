-- =====================================================================
-- staging.bureau_balance
-- Kaynak: raw.bureau_balance
-- Grain: 1 satır = 1 büro kredisinin 1 ayı (sk_id_bureau + months_balance)
--
-- Profil bulguları (27.299.925 satır):
--   status dağılımı: C %49,99 | X %21,28 | 0 %27,47 | 1 %0,89 | 2 %0,09
--                    3 %0,03 | 4 %0,02 | 5 %0,23
--     C = kapalı, X = bilinmiyor, 0 = gecikmesiz,
--     1 = 1-30 | 2 = 31-60 | 3 = 61-90 | 4 = 91-120 | 5 = 120+ / satılmış / zarar
--   Referans bütünlüğü:
--     - Aylık geçmişi olan kredi: 817.395
--     - Yetim kredi (bureau'da kaydı yok): 43.041 (%5,3) → müşteriye
--       bağlanamaz, join'de düşer. Silinmiyor, belgeleniyor.
--     - Büro kredilerinin yalnızca 774.354'ünün (%45) aylık geçmişi var.
--       → DPD analizi büro kredilerinin yarısından azını kapsar.
--         Geçmişi olmayan "gecikmesiz" sayılmamalı, "bilinmiyor" olmalı.
-- =====================================================================

DROP TABLE IF EXISTS staging.bureau_balance;

CREATE TABLE staging.bureau_balance AS
SELECT
    sk_id_bureau::numeric::int                       AS sk_id_bureau,
    months_balance::numeric::int                     AS months_balance,
    status,

    -- ===== Türetilmiş sütunlar =====
    -- Aktif ay: kredi açık ve durumu biliniyor (paydalarda bu kullanılır)
    CASE WHEN status IN ('0', '1', '2', '3', '4', '5')
         THEN 1 ELSE 0 END                           AS aktif_ay,
    -- O ay herhangi bir gecikme var mı?
    CASE WHEN status IN ('1', '2', '3', '4', '5') THEN 1
         WHEN status = '0'                        THEN 0
         ELSE NULL END                               AS gecikmede,
    -- 90+ gün gecikme (NPL karşılığı)
    CASE WHEN status IN ('4', '5')                THEN 1
         WHEN status IN ('0', '1', '2', '3')      THEN 0
         ELSE NULL END                               AS gecikme_90_arti,
    -- Okunabilir DPD kovası
    CASE status
        WHEN '0' THEN '0 - Gecikmesiz'
        WHEN '1' THEN '1 - 1-30 gün'
        WHEN '2' THEN '2 - 31-60 gün'
        WHEN '3' THEN '3 - 61-90 gün'
        WHEN '4' THEN '4 - 91-120 gün'
        WHEN '5' THEN '5 - 120+ gün'
        WHEN 'C' THEN 'Kapalı'
        WHEN 'X' THEN 'Bilinmiyor'
    END                                              AS dpd_kova
FROM raw.bureau_balance;

ALTER TABLE staging.bureau_balance ADD PRIMARY KEY (sk_id_bureau, months_balance);


-- =====================================================================
-- Doğrulama (tablo kurulduktan sonra DBeaver'da çalıştır)
-- Beklenen: 27.299.925 satır
--   aktif_ay = 0-5 toplamı (~7,84 M)
--   gecikme_90_arti oranı aktif aylar içinde ~%0,9
-- =====================================================================
-- SELECT
--     COUNT(*)                                       AS toplam,
--     SUM(aktif_ay)                                  AS aktif_ay,
--     ROUND(100.0 * AVG(gecikmede), 2)               AS gecikme_yuzde_aktif,
--     ROUND(100.0 * AVG(gecikme_90_arti), 2)         AS npl_yuzde_aktif,
--     MIN(months_balance)                            AS en_eski_ay,
--     MAX(months_balance)                            AS en_yeni_ay
-- FROM staging.bureau_balance;
