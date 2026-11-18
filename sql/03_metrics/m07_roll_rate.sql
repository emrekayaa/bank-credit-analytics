-- =====================================================================
-- metrics.mv_roll_rate  (MATERIALIZED VIEW)
-- Kaynak: staging.pos_cash_balance, staging.credit_card_balance
-- Grain: 1 satır = kaynak × bu ayki kova × sonraki ayki durum
-- Amaç: Sayfa 9 (Portföy Dinamiği): roll rate matrisi.
--
-- Roll rate nedir?
--   Bu ay belirli bir gecikme kovasında olan kredinin, bir sonraki ay
--   hangi kovaya geçtiği. Örnek: "1-30 gün" kovasındakilerin %X'i
--   ertesi ay "31-60 gün"e kayıyor (kötüleşme), %Y'si "Gecikmesiz"e
--   dönüyor (düzelme). Bankaların risk ekiplerinin temel tablosu.
--
-- Yöntem:
--   - LEAD() ile aynı kredinin bir sonraki ay kaydı bulunur.
--   - Yalnızca ARDIŞIK aylar sayılır (sonraki_ay = bu_ay + 1);
--     arada boşluk varsa geçiş sayılmaz.
--   - Başlangıç: yalnızca aktif aylar (POS: Active, kart: limit > 0).
--   - Sonraki ay kredi tamamlanmışsa durum = 'Kapandı'.
--
-- Tableau'da oran: SUM([adet]) / TOTAL(SUM([adet])) bu_ay_kova bazında.
-- Yenileme: REFRESH MATERIALIZED VIEW metrics.mv_roll_rate;
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS metrics.mv_roll_rate;

CREATE MATERIALIZED VIEW metrics.mv_roll_rate AS
WITH aylar AS (
    SELECT
        'Home Credit POS / nakit'                         AS kaynak,
        sk_id_prev,
        months_balance,
        dpd_kova,
        (name_contract_status = 'Active')                 AS aktif,
        (name_contract_status = 'Completed')              AS tamamlandi
    FROM staging.pos_cash_balance

    UNION ALL

    SELECT
        'Home Credit kredi kartı',
        sk_id_prev,
        months_balance,
        dpd_kova,
        (aktif_kart_ayi = 1),
        (name_contract_status = 'Completed')
    FROM staging.credit_card_balance
),
gecis AS (
    SELECT
        kaynak,
        months_balance,
        dpd_kova,
        aktif,
        LEAD(months_balance) OVER w                       AS sonraki_ay,
        LEAD(dpd_kova)       OVER w                       AS sonraki_kova,
        LEAD(tamamlandi)     OVER w                       AS sonraki_tamamlandi
    FROM aylar
    WINDOW w AS (PARTITION BY kaynak, sk_id_prev ORDER BY months_balance)
)
SELECT
    kaynak,
    dpd_kova                                              AS bu_ay_kova,
    CASE WHEN sonraki_tamamlandi THEN '6) Kapandı'
         ELSE sonraki_kova END                            AS sonraki_ay_durum,
    COUNT(*)                                              AS adet
FROM gecis
WHERE aktif
  AND sonraki_ay = months_balance + 1
GROUP BY 1, 2, 3;


-- =====================================================================
-- Kontrol: roll rate matrisi (POS)
-- Beklenti: köşegen (aynı kovada kalma) ve "Gecikmesiz" baskın;
--           kova büyüdükçe düzelme olasılığı azalmalı.
-- =====================================================================
-- SELECT bu_ay_kova, sonraki_ay_durum, adet,
--        ROUND(100.0 * adet / SUM(adet) OVER (PARTITION BY bu_ay_kova), 2) AS gecis_orani
-- FROM metrics.mv_roll_rate
-- WHERE kaynak = 'Home Credit POS / nakit'
-- ORDER BY 1, 2;
