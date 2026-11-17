-- =====================================================================
-- core.ozet_kart
-- Kaynak: staging.credit_card_balance
-- Grain: 1 satır = 1 müşteri (sk_id_curr)
--
-- Notlar:
--   - Kullanım, limit aşımı ve gecikme oranları yalnızca AKTİF kart
--     aylarında (limit > 0) hesaplanıyor; sıfır limitli aylar paydaya
--     girmiyor (bkz. staging profili H2).
--   - limit_kullanim_orani, asgari_alti_odeme ve nakit_avans_payi
--     staging'de NULL'lu tanımlandığı için AVG() doğru paydayı kendisi seçer.
--   - Gecikme metrikleri toleranslı gecikme (sk_dpd_def) üzerinden.
-- =====================================================================

DROP TABLE IF EXISTS core.ozet_kart;

CREATE TABLE core.ozet_kart AS
SELECT
    sk_id_curr,

    -- Hacim
    COUNT(DISTINCT sk_id_prev)                                     AS kart_sayisi,
    SUM(aktif_kart_ayi)                                            AS kart_aktif_ay_sayisi,

    -- Kart kullanımı (tüm geçmiş)
    ROUND(AVG(limit_kullanim_orani), 3)                            AS kart_ort_kullanim,
    ROUND(MAX(limit_kullanim_orani), 3)                            AS kart_max_kullanim,
    ROUND(AVG(limit_asimi) FILTER (WHERE aktif_kart_ayi = 1), 3)   AS kart_limit_asimi_ay_orani,
    ROUND(AVG(asgari_alti_odeme), 3)                               AS kart_asgari_alti_odeme_orani,
    ROUND(AVG(nakit_avans_payi), 3)                                AS kart_ort_nakit_avans_payi,

    -- Kart kullanımı (son 12 ay)
    ROUND(AVG(limit_kullanim_orani) FILTER (WHERE months_balance >= -12), 3)
                                                                   AS kart_ort_kullanim_12ay,
    ROUND(AVG(asgari_alti_odeme)    FILTER (WHERE months_balance >= -12), 3)
                                                                   AS kart_asgari_alti_odeme_orani_12ay,

    -- Gecikme
    ROUND(AVG(gecikmede) FILTER (WHERE aktif_kart_ayi = 1), 3)     AS kart_gecikmeli_ay_orani,
    MAX(sk_dpd_def)                                                AS kart_max_gecikme_gun,
    SUM(gecikme_90_arti)                                           AS kart_90_arti_ay_sayisi,
    MAX(olumsuz_durum)                                             AS kart_olumsuz_durum_var,

    -- Başvuru anındaki durum (son ay)
    SUM(amt_balance)             FILTER (WHERE months_balance = -1) AS kart_son_ay_bakiye,
    SUM(amt_credit_limit_actual) FILTER (WHERE months_balance = -1) AS kart_son_ay_limit,
    ROUND(SUM(amt_balance)             FILTER (WHERE months_balance = -1)
          / NULLIF(SUM(amt_credit_limit_actual) FILTER (WHERE months_balance = -1), 0), 3)
                                                                   AS kart_son_ay_kullanim
FROM staging.credit_card_balance
GROUP BY sk_id_curr;

ALTER TABLE core.ozet_kart ADD PRIMARY KEY (sk_id_curr);


-- =====================================================================
-- Doğrulama
-- Beklenen müşteri sayısı: 103.558 (keşif bölüm 10b)
-- =====================================================================
-- SELECT
--     COUNT(*)                                                  AS musteri,
--     ROUND(AVG(kart_sayisi), 2)                                AS ort_kart,
--     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kart_ort_kullanim)    AS medyan_ort_kullanim,
--     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kart_son_ay_kullanim) AS medyan_son_ay_kullanim,
--     ROUND(100.0 * AVG(CASE WHEN kart_son_ay_kullanim > 0.9 THEN 1 ELSE 0 END), 2) AS limite_dayali_yuzde,
--     ROUND(100.0 * AVG(kart_olumsuz_durum_var), 2)             AS olumsuz_durum_yuzde
-- FROM core.ozet_kart;
