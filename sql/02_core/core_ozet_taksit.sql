-- =====================================================================
-- core.ozet_taksit
-- Kaynak: staging.installments_payments
-- Grain: 1 satır = 1 müşteri (sk_id_curr)
--
-- İki seviyeli özet:
--   ödeme hareketi (staging) → taksit (CTE) → müşteri (bu tablo)
--   Bir taksit parça parça ödenebildiği için önce taksit seviyesine
--   indiriliyor; yoksa parçalı taksitler birden fazla sayılır.
--
-- Taksit tanımı: (sk_id_prev, num_instalment_version, num_instalment_number)
-- Gecikme: tolerans yok; 1 gün bile geç ödenen taksit "geç" sayılır.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.ozet_taksit;

CREATE TABLE core.ozet_taksit AS
WITH taksit AS (
    -- 1. adım: ödeme hareketlerini taksit seviyesine indir
    SELECT
        sk_id_curr,
        sk_id_prev,
        num_instalment_version,
        num_instalment_number,
        MIN(days_instalment)         AS vade_gun,
        MAX(amt_instalment)          AS gereken_tutar,
        SUM(amt_payment)             AS odenen_tutar,
        MAX(days_entry_payment)      AS son_odeme_gun
    FROM staging.installments_payments
    GROUP BY 1, 2, 3, 4
),
taksit_detay AS (
    -- Taksit bazında gecikme ve eksik ödeme
    SELECT
        *,
        son_odeme_gun - vade_gun                                AS gecikme_gun,
        CASE WHEN son_odeme_gun > vade_gun THEN 1 ELSE 0 END    AS gec,
        CASE WHEN son_odeme_gun - vade_gun > 30 THEN 1 ELSE 0 END AS gec_30_arti,
        CASE WHEN odenen_tutar < gereken_tutar THEN 1 ELSE 0 END AS eksik
    FROM taksit
)
-- 2. adım: taksitleri müşteri seviyesine indir
SELECT
    sk_id_curr,
    COUNT(*)                                                    AS taksit_sayisi,
    COUNT(DISTINCT sk_id_prev)                                  AS kredi_sayisi,

    -- Tüm geçmiş
    SUM(gec)                                                    AS gec_taksit_sayisi,
    ROUND(AVG(gec), 3)                                          AS gec_taksit_orani,
    SUM(gec_30_arti)                                            AS gec_30_arti_sayisi,
    MAX(gecikme_gun)                                            AS max_gecikme_gun,
    ROUND(AVG(gecikme_gun) FILTER (WHERE gec = 1), 1)           AS ort_gecikme_gun_gec_olanlarda,
    ROUND(AVG(eksik), 3)                                        AS eksik_odeme_orani,

    -- Son 12 ay (vadesi başvurudan önceki 365 gün içinde olan taksitler)
    COUNT(*) FILTER (WHERE vade_gun >= -365)                    AS taksit_sayisi_12ay,
    ROUND(AVG(gec) FILTER (WHERE vade_gun >= -365), 3)          AS gec_taksit_orani_12ay,
    MAX(gecikme_gun) FILTER (WHERE vade_gun >= -365)            AS max_gecikme_gun_12ay,

    -- Ödeme alışkanlığı
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gecikme_gun)    AS medyan_gecikme_gun
FROM taksit_detay
GROUP BY sk_id_curr;

ALTER TABLE core.ozet_taksit ADD PRIMARY KEY (sk_id_curr);


-- =====================================================================
-- Doğrulama
-- =====================================================================
-- SELECT
--     COUNT(*)                                                  AS musteri,
--     SUM(taksit_sayisi)                                        AS toplam_taksit,
--     ROUND(100.0 * SUM(gec_taksit_sayisi) / SUM(taksit_sayisi), 2) AS gec_taksit_yuzde,
--     ROUND(100.0 * AVG(CASE WHEN gec_taksit_sayisi > 0 THEN 1 ELSE 0 END), 2)
--                                                               AS en_az_bir_gec_musteri_yuzde,
--     ROUND(100.0 * AVG(CASE WHEN gec_30_arti_sayisi > 0 THEN 1 ELSE 0 END), 2)
--                                                               AS en_az_bir_30_arti_musteri_yuzde
-- FROM core.ozet_taksit;
