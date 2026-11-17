-- =====================================================================
-- core.ozet_pos
-- Kaynak: staging.pos_cash_balance
-- Grain: 1 satır = 1 müşteri (sk_id_curr)
--
-- Notlar:
--   - Gecikme metrikleri toleranslı gecikme (sk_dpd_def) üzerinden
--     (gecikmelerin ~%61'i küçük tutarlı, bkz. staging profili).
--   - Oranlar "ay" bazında: müşterinin POS kredilerinin aylarının
--     yüzde kaçında gecikme var.
--   - months_balance −1 = başvurudan önceki son ay.
-- =====================================================================

DROP TABLE IF EXISTS core.ozet_pos;

CREATE TABLE core.ozet_pos AS
SELECT
    sk_id_curr,

    -- Hacim
    COUNT(DISTINCT sk_id_prev)                                     AS pos_kredi_sayisi,
    COUNT(*)                                                       AS pos_ay_sayisi,

    -- Tüm geçmiş
    ROUND(AVG(gecikmede), 3)                                       AS pos_gecikmeli_ay_orani,
    SUM(gecikme_90_arti)                                           AS pos_90_arti_ay_sayisi,
    MAX(sk_dpd_def)                                                AS pos_max_gecikme_gun,
    MAX(olumsuz_durum)                                             AS pos_olumsuz_durum_var,

    -- Son 12 ay
    ROUND(AVG(gecikmede) FILTER (WHERE months_balance >= -12), 3)  AS pos_gecikmeli_ay_orani_12ay,
    MAX(sk_dpd_def)      FILTER (WHERE months_balance >= -12)      AS pos_max_gecikme_gun_12ay,

    -- Başvuru anındaki durum (son ay)
    COUNT(DISTINCT sk_id_prev) FILTER (WHERE months_balance = -1
                                         AND name_contract_status = 'Active')
                                                                   AS pos_aktif_kredi_sayisi,
    SUM(cnt_instalment_future) FILTER (WHERE months_balance = -1
                                         AND name_contract_status = 'Active')
                                                                   AS pos_kalan_taksit_sayisi
FROM staging.pos_cash_balance
GROUP BY sk_id_curr;

ALTER TABLE core.ozet_pos ADD PRIMARY KEY (sk_id_curr);


-- =====================================================================
-- Doğrulama
-- Beklenen müşteri sayısı: 337.252 (keşif bölüm 10a)
-- =====================================================================
-- SELECT
--     COUNT(*)                                                       AS musteri,
--     ROUND(AVG(pos_kredi_sayisi), 2)                                AS ort_kredi,
--     ROUND(100.0 * AVG(CASE WHEN pos_max_gecikme_gun > 0  THEN 1 ELSE 0 END), 2) AS en_az_bir_gecikme_yuzde,
--     ROUND(100.0 * AVG(CASE WHEN pos_90_arti_ay_sayisi > 0 THEN 1 ELSE 0 END), 2) AS en_az_bir_90_arti_yuzde,
--     ROUND(100.0 * AVG(pos_olumsuz_durum_var), 2)                   AS olumsuz_durum_yuzde,
--     ROUND(100.0 * AVG(CASE WHEN pos_aktif_kredi_sayisi > 0 THEN 1 ELSE 0 END), 2) AS aktif_pos_kredili_yuzde
-- FROM core.ozet_pos;
