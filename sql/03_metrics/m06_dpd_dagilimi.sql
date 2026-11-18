-- =====================================================================
-- metrics.mv_dpd_dagilimi  (MATERIALIZED VIEW)
-- Kaynak: staging.bureau_balance, staging.pos_cash_balance,
--         staging.credit_card_balance
-- Grain: 1 satır = kaynak × zaman penceresi × DPD kovası
-- Amaç: Sayfa 6 ve 9: üç kaynağın gecikme kovası dağılımını yan yana
--       göstermek (staging'de üçüne de aynı kova yapısını vermiştik).
--
-- Neden MATERIALIZED?
--   Normal view her sorguda altındaki sorguyu yeniden çalıştırır. Bu view
--   41 milyon satır tarıyor; Tableau her filtrede bunu tekrarlamasın diye
--   sonuç diskte saklanır. Kaynak veri değişirse elle yenilenir:
--     REFRESH MATERIALIZED VIEW metrics.mv_dpd_dagilimi;
--
-- Doğru payda (yalnızca aktif aylar):
--   - Büro: aktif_ay = 1 (C kapalı ve X bilinmiyor hariç)
--   - POS:  name_contract_status = 'Active'
--   - Kart: aktif_kart_ayi = 1 (limit > 0)
-- Tableau'da pay: SUM([ay_sayisi]) / TOTAL(SUM([ay_sayisi])) kaynak bazında.
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS metrics.mv_dpd_dagilimi;

CREATE MATERIALIZED VIEW metrics.mv_dpd_dagilimi AS
SELECT
    'Kredi bürosu'                                                AS kaynak,
    CASE WHEN months_balance >= -12 THEN 'Son 12 ay'
                                    ELSE 'Daha eski' END          AS pencere,
    dpd_kova,
    COUNT(*)                                                      AS ay_sayisi
FROM staging.bureau_balance
WHERE aktif_ay = 1
GROUP BY 1, 2, 3

UNION ALL

SELECT
    'Home Credit POS / nakit',
    CASE WHEN months_balance >= -12 THEN 'Son 12 ay' ELSE 'Daha eski' END,
    dpd_kova,
    COUNT(*)
FROM staging.pos_cash_balance
WHERE name_contract_status = 'Active'
GROUP BY 1, 2, 3

UNION ALL

SELECT
    'Home Credit kredi kartı',
    CASE WHEN months_balance >= -12 THEN 'Son 12 ay' ELSE 'Daha eski' END,
    dpd_kova,
    COUNT(*)
FROM staging.credit_card_balance
WHERE aktif_kart_ayi = 1
GROUP BY 1, 2, 3;


-- =====================================================================
-- Kontrol: kaynak bazında kova payları
-- =====================================================================
-- SELECT kaynak, dpd_kova, SUM(ay_sayisi) AS ay,
--        ROUND(100.0 * SUM(ay_sayisi)
--              / SUM(SUM(ay_sayisi)) OVER (PARTITION BY kaynak), 2) AS pay
-- FROM metrics.mv_dpd_dagilimi
-- GROUP BY 1, 2
-- ORDER BY 1, 2;
