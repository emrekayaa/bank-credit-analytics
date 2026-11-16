-- =====================================================================
-- staging.pos_cash_balance
-- Kaynak: raw.pos_cash_balance
-- Grain: 1 satır = 1 POS / nakit kredinin 1 ayı (sk_id_prev + months_balance)
--
-- Profil bulguları (10.001.358 satır):
--   - (sk_id_prev, months_balance) benzersiz → bileşik primary key.
--   - Ay aralığı −96 … 0 (8 yıl; diğer tablolarla tutarlı).
--   - En yüksek gecikme 4.231 gün (~11,6 yıl): pencereden uzun, şüpheli;
--     silinmiyor, DPD kovasında 90+ grubuna düşüyor.
--   - Gecikmeli ay: sk_dpd > 0 → 295.227 (%2,95)
--                   sk_dpd_def > 0 → 113.969 (%1,14)
--     → Gecikmelerin ~%61'i küçük tutarlı (tolerans altında).
--     → Risk ölçümünde sk_dpd_def (toleranslı) kullanılacak.
--   - Vade (cnt_instalment) boş: 26.071 (%0,26).
--   - Durumlar: Active %91,5 | Completed %7,4 | Signed 87.260
--     Demand 7.065 | Returned to the store 5.461 | Approved 4.917
--     Amortized debt 636 | Canceled 15 | XNA 2 (→ NULL)
--     → Demand (muacceliyet: borcun tamamı talep edilmiş) ve
--       Amortized debt (tahmin: zarar yazılmış borç) = olumsuz_durum
-- =====================================================================

DROP TABLE IF EXISTS staging.pos_cash_balance;

CREATE TABLE staging.pos_cash_balance AS
SELECT
    -- ===== Kimlikler =====
    sk_id_prev::numeric::int                              AS sk_id_prev,
    sk_id_curr::numeric::int                              AS sk_id_curr,
    months_balance::numeric::int                          AS months_balance,

    -- ===== Vade =====
    cnt_instalment::numeric::int                          AS cnt_instalment,
    cnt_instalment_future::numeric::int                   AS cnt_instalment_future,

    -- ===== Durum ve gecikme =====
    NULLIF(name_contract_status, 'XNA')                   AS name_contract_status,
    sk_dpd::numeric::int                                  AS sk_dpd,
    sk_dpd_def::numeric::int                              AS sk_dpd_def,

    -- ===== Türetilmiş sütunlar =====
    -- Gecikme bayrakları toleranslı gecikme (sk_dpd_def) üzerinden
    CASE WHEN sk_dpd_def::numeric > 0
         THEN 1 ELSE 0 END                                AS gecikmede,
    CASE WHEN sk_dpd_def::numeric > 90
         THEN 1 ELSE 0 END                                AS gecikme_90_arti,
    CASE
        WHEN sk_dpd_def::numeric = 0   THEN '0 - Gecikmesiz'
        WHEN sk_dpd_def::numeric <= 30 THEN '1 - 1-30 gün'
        WHEN sk_dpd_def::numeric <= 60 THEN '2 - 31-60 gün'
        WHEN sk_dpd_def::numeric <= 90 THEN '3 - 61-90 gün'
        WHEN sk_dpd_def::numeric <= 120 THEN '4 - 91-120 gün'
        ELSE '5 - 120+ gün'
    END                                                   AS dpd_kova,
    CASE WHEN name_contract_status IN ('Demand', 'Amortized debt')
         THEN 1 ELSE 0 END                                AS olumsuz_durum,
    -- Kalan taksit oranı: 1 = yeni başlamış, 0 = bitmek üzere
    ROUND(cnt_instalment_future::numeric
          / NULLIF(cnt_instalment::numeric, 0), 3)        AS kalan_taksit_orani
FROM raw.pos_cash_balance;

ALTER TABLE staging.pos_cash_balance ADD PRIMARY KEY (sk_id_prev, months_balance);
CREATE INDEX idx_stg_pos_curr ON staging.pos_cash_balance (sk_id_curr);


-- =====================================================================
-- Doğrulama (tablo kurulduktan sonra DBeaver'da çalıştır)
-- Beklenen: 10.001.358 satır | gecikmede 113.969 | olumsuz_durum 7.701
-- =====================================================================
-- SELECT
--     COUNT(*)                                  AS toplam,
--     SUM(gecikmede)                            AS gecikmede,
--     SUM(gecikme_90_arti)                      AS gecikme_90_arti,
--     SUM(olumsuz_durum)                        AS olumsuz_durum,
--     COUNT(*) - COUNT(name_contract_status)    AS durum_null
-- FROM staging.pos_cash_balance;
--
-- SELECT dpd_kova, COUNT(*) AS adet
-- FROM staging.pos_cash_balance
-- GROUP BY 1
-- ORDER BY 1;
