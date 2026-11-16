-- =====================================================================
-- staging.bureau
-- Kaynak: raw.bureau
-- Grain: 1 satır = müşterinin başka bir kurumdaki 1 kredisi (sk_id_bureau)
--
-- Profil bulguları (1.716.428 satır) ve kararlar:
--   Durum: Closed %62,9 | Active %36,7 | Sold 6.527 | Bad debt 21
--     → Sold / Bad debt = ciddi geçmiş temerrüt → olumsuz_kapanis bayrağı
--   Para birimi: %99,92 currency 1; kur bilgisi yok
--     → tutar toplamlarında sadece currency 1 kullanılmalı (ana_para_birimi)
--   Kredi türü: 15 tür, ilk ikisi %96 → kredi_turu_grup (7 grup)
--   Tarihler (iş kuralı doğrulaması):
--     - Planlanan bitiş açılıştan önce: 164 → NULL
--     - Planlanan bitiş 40 yıldan uzak: 38.485, %99,5'i kredi kartı
--       (vadesiz ürün yer tutucusu) → NULL + plan_bitis_yok bayrağı
--     - Gerçek bitiş açılıştan önce: 20 → NULL
--     - Güncelleme başvurudan sonra: 17 → NULL
--     - Güncelleme açılıştan önce: 135 → NULL
--   Tutarlar:
--     - Negatif borç 8.418 (fazla ödeme) → korunuyor; borc_pozitif = 0 alt sınırlı
--     - Negatif limit 351 → NULL
--     - Doluluk: borç %85, taksit %28,5 (zayıf), max gecikme tutarı %34,5
-- =====================================================================

DROP TABLE IF EXISTS staging.bureau;

CREATE TABLE staging.bureau AS
SELECT
    -- ===== Kimlikler =====
    sk_id_bureau::numeric::int                               AS sk_id_bureau,
    sk_id_curr::numeric::int                                 AS sk_id_curr,

    -- ===== Kredi bilgisi =====
    credit_active,
    credit_currency,
    credit_type,
    cnt_credit_prolong::numeric::int                         AS cnt_credit_prolong,

    -- ===== Tarihler (iş kurallarıyla temizlenmiş) =====
    days_credit::numeric::int                                AS days_credit,
    CASE
        WHEN days_credit_enddate::numeric > 365 * 40                     THEN NULL
        WHEN days_credit_enddate::numeric < days_credit::numeric         THEN NULL
        ELSE days_credit_enddate::numeric::int
    END                                                      AS days_credit_enddate,
    CASE
        WHEN days_enddate_fact::numeric < days_credit::numeric           THEN NULL
        ELSE days_enddate_fact::numeric::int
    END                                                      AS days_enddate_fact,
    CASE
        WHEN days_credit_update::numeric > 0                             THEN NULL
        WHEN days_credit_update::numeric < days_credit::numeric          THEN NULL
        ELSE days_credit_update::numeric::int
    END                                                      AS days_credit_update,

    -- ===== Gecikme =====
    credit_day_overdue::numeric::int                         AS credit_day_overdue,
    amt_credit_max_overdue::numeric                          AS amt_credit_max_overdue,
    amt_credit_sum_overdue::numeric                          AS amt_credit_sum_overdue,

    -- ===== Tutarlar =====
    amt_credit_sum::numeric                                  AS amt_credit_sum,
    amt_credit_sum_debt::numeric                             AS amt_credit_sum_debt,
    CASE
        WHEN amt_credit_sum_limit::numeric < 0 THEN NULL
        ELSE amt_credit_sum_limit::numeric
    END                                                      AS amt_credit_sum_limit,
    amt_annuity::numeric                                     AS amt_annuity,

    -- ===== Türetilmiş sütunlar =====
    CASE
        WHEN credit_type IN ('Consumer credit', 'Cash loan (non-earmarked)')
            THEN 'Tüketici'
        WHEN credit_type = 'Credit card'
            THEN 'Kredi kartı'
        WHEN credit_type = 'Car loan'
            THEN 'Taşıt'
        WHEN credit_type IN ('Mortgage', 'Real estate loan')
            THEN 'Konut'
        WHEN credit_type = 'Microloan'
            THEN 'Mikrokredi'
        WHEN credit_type IN ('Loan for business development',
                             'Loan for working capital replenishment',
                             'Loan for the purchase of equipment')
            THEN 'Ticari'
        ELSE 'Diğer'
    END                                                      AS kredi_turu_grup,
    CASE WHEN credit_active = 'Active'
         THEN 1 ELSE 0 END                                   AS aktif,
    CASE WHEN credit_active IN ('Sold', 'Bad debt')
         THEN 1 ELSE 0 END                                   AS olumsuz_kapanis,
    CASE WHEN credit_currency = 'currency 1'
         THEN 1 ELSE 0 END                                   AS ana_para_birimi,
    CASE WHEN days_credit_enddate::numeric > 365 * 40
         THEN 1 ELSE 0 END                                   AS plan_bitis_yok,
    CASE WHEN credit_day_overdue::numeric > 0
         THEN 1 ELSE 0 END                                   AS su_an_gecikmede,
    GREATEST(amt_credit_sum_debt::numeric, 0)                AS borc_pozitif
FROM raw.bureau;

ALTER TABLE staging.bureau ADD PRIMARY KEY (sk_id_bureau);
CREATE INDEX idx_stg_bureau_curr ON staging.bureau (sk_id_curr);


-- =====================================================================
-- Doğrulama (tablo kurulduktan sonra DBeaver'da çalıştır)
-- Beklenen: 1.716.428 satır | olumsuz_kapanis 6.548 | plan_bitis_yok 38.485
--           ana_para_birimi 1.715.020 | aktif 630.607
-- =====================================================================
-- SELECT
--     COUNT(*)                       AS toplam,
--     SUM(aktif)                     AS aktif,
--     SUM(olumsuz_kapanis)           AS olumsuz_kapanis,
--     SUM(ana_para_birimi)           AS ana_para_birimi,
--     SUM(plan_bitis_yok)            AS plan_bitis_yok,
--     SUM(su_an_gecikmede)           AS su_an_gecikmede,
--     COUNT(*) - COUNT(days_credit_enddate) AS plan_bitis_null
-- FROM staging.bureau;
--
-- SELECT kredi_turu_grup, COUNT(*) AS adet
-- FROM staging.bureau
-- GROUP BY 1
-- ORDER BY 2 DESC;