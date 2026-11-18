-- =====================================================================
-- core.ozet_buro
-- Kaynak: staging.bureau + staging.bureau_balance
-- Grain: 1 satır = 1 müşteri (sk_id_curr)
--
-- İki seviyeli özet:
--   1) bureau_balance (kredi-ay) → büro kredisi seviyesine özetlenir
--   2) bureau ile LEFT JOIN → müşteri seviyesine özetlenir
--
-- Notlar:
--   - Büro kredilerinin yalnızca ~%45'inin aylık geçmişi var. Geçmişi
--     olmayan kredilerde aylık gecikme metrikleri NULL kalır
--     ("gecikmesiz" değil, "bilinmiyor").
--   - 43.041 yetim kredi (bureau_balance'ta var, bureau'da yok) LEFT JOIN
--     bureau tarafından yapıldığı için kendiliğinden düşer.
--   - Tutar toplamlarında yalnızca ana para birimi (currency 1) kullanılır;
--     kur bilgisi yok.
--   - Borç toplamlarında negatif borç (fazla ödeme) 0 sayılır (borc_pozitif).
--   - Aylık gecikme oranı ağırlıklıdır: toplam gecikmeli ay / toplam aktif ay.
-- =====================================================================

DROP TABLE IF EXISTS core.ozet_buro;

CREATE TABLE core.ozet_buro AS
WITH bb_kredi AS (
    -- 1. adım: aylık geçmişi büro kredisi seviyesine indir
    SELECT
        sk_id_bureau,
        SUM(aktif_ay)                                         AS aktif_ay_sayisi,
        SUM(gecikmede)                                        AS gecikmeli_ay_sayisi,
        SUM(gecikme_90_arti)                                  AS ay_90_arti_sayisi,
        SUM(aktif_ay)  FILTER (WHERE months_balance >= -12)   AS aktif_ay_sayisi_12ay,
        SUM(gecikmede) FILTER (WHERE months_balance >= -12)   AS gecikmeli_ay_sayisi_12ay
    FROM staging.bureau_balance
    GROUP BY sk_id_bureau
),
kredi AS (
    -- Büro kredisi + aylık özet (geçmişi olmayan kredilerde NULL)
    SELECT
        b.*,
        bb.sk_id_bureau IS NOT NULL                           AS aylik_gecmis_var,
        bb.aktif_ay_sayisi,
        bb.gecikmeli_ay_sayisi,
        bb.ay_90_arti_sayisi,
        bb.aktif_ay_sayisi_12ay,
        bb.gecikmeli_ay_sayisi_12ay
    FROM staging.bureau b
    LEFT JOIN bb_kredi bb
        ON b.sk_id_bureau = bb.sk_id_bureau
)
-- 2. adım: müşteri seviyesine indir
SELECT
    sk_id_curr,

    -- ===== Hacim ve geçmiş uzunluğu =====
    COUNT(*)                                                  AS buro_kredi_sayisi,
    SUM(aktif)                                                AS buro_aktif_kredi_sayisi,
    COUNT(DISTINCT kredi_turu_grup)                           AS buro_kredi_turu_sayisi,
    ROUND(-MIN(days_credit) / 365.25, 1)                      AS buro_kredi_gecmisi_yil,
    MAX(days_credit)                                          AS buro_son_kredi_gun,
    COUNT(*) FILTER (WHERE days_credit >= -365)               AS buro_son_1yil_acilan_kredi,
    MAX(CASE WHEN kredi_turu_grup = 'Mikrokredi'
             THEN 1 ELSE 0 END)                               AS buro_mikrokredi_var,

    -- ===== Olumsuz geçmiş =====
    MAX(olumsuz_kapanis)                                      AS buro_olumsuz_kapanis_var,
    SUM(cnt_credit_prolong)                                   AS buro_uzatma_sayisi,

    -- ===== Başvuru anındaki gecikme (tüm krediler) =====
    SUM(su_an_gecikmede)                                      AS buro_su_an_gecikmede_kredi,
    MAX(credit_day_overdue)                                   AS buro_max_gecikme_gun,

    -- ===== Borç yükü (aktif krediler, ana para birimi) =====
    SUM(borc_pozitif)   FILTER (WHERE aktif = 1 AND ana_para_birimi = 1)
                                                              AS buro_aktif_borc,
    SUM(amt_credit_sum) FILTER (WHERE aktif = 1 AND ana_para_birimi = 1)
                                                              AS buro_aktif_kredi_tutari,
    ROUND(
        SUM(borc_pozitif)   FILTER (WHERE aktif = 1 AND ana_para_birimi = 1)
        / NULLIF(SUM(amt_credit_sum) FILTER (WHERE aktif = 1 AND ana_para_birimi = 1), 0)
    , 3)                                                      AS buro_borc_tutar_orani,
    SUM(amt_credit_sum_overdue) FILTER (WHERE ana_para_birimi = 1)
                                                              AS buro_gecikmis_tutar,

    -- ===== Aylık gecikme geçmişi (yalnızca aylık geçmişi olan krediler) =====
    COUNT(*) FILTER (WHERE aylik_gecmis_var)                  AS buro_aylik_gecmisli_kredi,
    ROUND(SUM(gecikmeli_ay_sayisi)::numeric
          / NULLIF(SUM(aktif_ay_sayisi), 0), 3)               AS buro_gecikmeli_ay_orani,
    SUM(ay_90_arti_sayisi)                                    AS buro_90_arti_ay_sayisi,
    ROUND(SUM(gecikmeli_ay_sayisi_12ay)::numeric
          / NULLIF(SUM(aktif_ay_sayisi_12ay), 0), 3)          AS buro_gecikmeli_ay_orani_12ay
FROM kredi
GROUP BY sk_id_curr;

ALTER TABLE core.ozet_buro ADD PRIMARY KEY (sk_id_curr);


-- =====================================================================
-- Doğrulama
-- Beklenen müşteri sayısı: ~305 bin (keşif bölüm 5; train + test)
-- =====================================================================
-- SELECT
--     COUNT(*)                                                    AS musteri,
--     ROUND(AVG(buro_kredi_sayisi), 2)                            AS ort_kredi,
--     ROUND(100.0 * AVG(CASE WHEN buro_aylik_gecmisli_kredi > 0
--                            THEN 1 ELSE 0 END), 2)               AS aylik_gecmisi_olan_yuzde,
--     ROUND(100.0 * AVG(buro_olumsuz_kapanis_var), 2)             AS olumsuz_kapanis_yuzde,
--     ROUND(100.0 * AVG(CASE WHEN buro_su_an_gecikmede_kredi > 0
--                            THEN 1 ELSE 0 END), 2)               AS su_an_gecikmede_yuzde,
--     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY buro_kredi_gecmisi_yil) AS medyan_gecmis_yil,
--     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY buro_borc_tutar_orani)  AS medyan_borc_tutar_orani
-- FROM core.ozet_buro;
