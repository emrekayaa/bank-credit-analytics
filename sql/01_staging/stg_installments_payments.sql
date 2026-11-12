-- =====================================================================
-- staging.installments_payments
-- Kaynak: raw.installments_payments
-- Grain: 1 satır = 1 ödeme hareketi.
--   Bir taksit parça parça ödendiyse birden fazla satır olur.
--   Taksit bazında analiz için core katmanında
--   (sk_id_prev, num_instalment_version, num_instalment_number) bazında
--   özetlenecek.
-- Profil bulguları (13.605.401 satır):
--   - 365243 yer tutucusu yok.
--   - 2.905 satırda ödeme tarihi ve tutarı boş (ödeme kaydı yok) → korunuyor.
--   - 1.440 satırda ödeme tutarı 0.
--   - Gecikme aralığı −3.189 ile +2.884 gün: uç değerler var, silinmiyor;
--     analizde DPD kovalarıyla ele alınacak.
-- =====================================================================

DROP TABLE IF EXISTS staging.installments_payments;

CREATE TABLE staging.installments_payments AS
SELECT
    -- ===== Kimlikler =====
    sk_id_prev::numeric::int                       AS sk_id_prev,
    sk_id_curr::numeric::int                       AS sk_id_curr,

    -- ===== Taksit =====
    num_instalment_version::numeric::int           AS num_instalment_version,
    num_instalment_number::numeric::int            AS num_instalment_number,

    -- ===== Gereken ve gerçekleşen =====
    days_instalment::numeric::int                  AS days_instalment,
    days_entry_payment::numeric::int               AS days_entry_payment,
    amt_instalment::numeric                        AS amt_instalment,
    amt_payment::numeric                           AS amt_payment,

    -- ===== Türetilmiş sütunlar =====
    -- Pozitif = geç ödeme, negatif = erken ödeme, NULL = ödeme kaydı yok
    (days_entry_payment::numeric
     - days_instalment::numeric)::int              AS gecikme_gun,
    CASE
        WHEN days_entry_payment IS NULL THEN NULL
        WHEN days_entry_payment::numeric > days_instalment::numeric THEN 1
        ELSE 0
    END                                            AS gec_odendi,
    -- Pozitif = eksik ödeme, negatif = fazla ödeme
    ROUND(amt_instalment::numeric
          - amt_payment::numeric, 2)               AS eksik_odeme,
    ROUND(amt_payment::numeric
          / NULLIF(amt_instalment::numeric, 0), 3) AS odeme_orani
FROM raw.installments_payments;

CREATE INDEX idx_stg_inst_prev ON staging.installments_payments (sk_id_prev);
CREATE INDEX idx_stg_inst_curr ON staging.installments_payments (sk_id_curr);


-- =====================================================================
-- Doğrulama (tablo kurulduktan sonra DBeaver'da çalıştır)
-- Beklenen: 13.605.401 satır, gecikme_gun boş = 2.905
-- =====================================================================
-- SELECT
--     COUNT(*)                                            AS toplam,
--     COUNT(*) - COUNT(gecikme_gun)                       AS gecikme_bos,
--     ROUND(100.0 * AVG(gec_odendi), 2)                   AS gec_odeme_yuzde,
--     PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY gecikme_gun) AS medyan_gecikme,
--     PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY gecikme_gun) AS p99_gecikme
-- FROM staging.installments_payments;