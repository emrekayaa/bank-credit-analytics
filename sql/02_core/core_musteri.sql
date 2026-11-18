-- =====================================================================
-- core.musteri  (müşteri 360)
-- Kaynak: staging.application + core.ozet_* (5 özet tablo)
-- Grain: 1 satır = 1 müşteri (sk_id_curr), yalnızca train (target var)
--
-- Notlar:
--   - Tüm join'ler LEFT JOIN: geçmişi olmayan müşteriler düşmez,
--     ilgili sütunları NULL olur.
--   - USING (sk_id_curr) ile SELECT * birleştirme sütununu tek kez getirir.
--   - Özet sütunları kaynak önekiyle adlandırıldı (buro_, pos_, kart_ ...),
--     çakışma yok.
--   - Alt tablolardaki tüm bilgiler başvuru anından ÖNCEYE ait
--     → modelde veri sızıntısı (leakage) yok.
--   - application_test (target yok) burada değil; model skorlama
--     aşamasında aynı yapı test için ayrıca kurulacak.
-- =====================================================================

DROP TABLE IF EXISTS core.musteri;

CREATE TABLE core.musteri AS
SELECT
    *,

    -- ===== Kapsama bayrakları: hangi geçmiş var? =====
    CASE WHEN buro_kredi_sayisi     IS NOT NULL THEN 1 ELSE 0 END  AS buro_kaydi_var,
    CASE WHEN onceki_basvuru_sayisi IS NOT NULL THEN 1 ELSE 0 END  AS onceki_basvuru_var,
    CASE WHEN taksit_sayisi         IS NOT NULL THEN 1 ELSE 0 END  AS taksit_gecmisi_var,
    CASE WHEN pos_kredi_sayisi      IS NOT NULL THEN 1 ELSE 0 END  AS pos_gecmisi_var,
    CASE WHEN kart_sayisi           IS NOT NULL THEN 1 ELSE 0 END  AS kart_var,

    -- ===== Toplam borç yükü =====
    -- Dış aktif borç / yıllık gelir
    ROUND(buro_aktif_borc / NULLIF(amt_income_total, 0), 3)        AS buro_borc_gelir_orani,
    -- (Dış aktif borç + yeni kredi) / yıllık gelir
    ROUND((COALESCE(buro_aktif_borc, 0) + amt_credit)
          / NULLIF(amt_income_total, 0), 3)                        AS toplam_borc_gelir_orani
FROM staging.application
LEFT JOIN core.ozet_onceki_basvuru USING (sk_id_curr)
LEFT JOIN core.ozet_taksit         USING (sk_id_curr)
LEFT JOIN core.ozet_pos            USING (sk_id_curr)
LEFT JOIN core.ozet_kart           USING (sk_id_curr)
LEFT JOIN core.ozet_buro           USING (sk_id_curr);

ALTER TABLE core.musteri ADD PRIMARY KEY (sk_id_curr);


-- =====================================================================
-- Doğrulama 1: satır sayısı ve kapsama
-- Beklenen: 307.511 satır (staging.application ile aynı; join satır
--           çoğaltmamalı). buro_kaydi_var toplamı 263.491.
-- =====================================================================
-- SELECT
--     COUNT(*)                                       AS musteri,
--     SUM(buro_kaydi_var)                            AS buro_kaydi_var,
--     SUM(onceki_basvuru_var)                        AS onceki_basvuru_var,
--     SUM(taksit_gecmisi_var)                        AS taksit_gecmisi_var,
--     SUM(pos_gecmisi_var)                           AS pos_gecmisi_var,
--     SUM(kart_var)                                  AS kart_var
-- FROM core.musteri;

-- =====================================================================
-- Doğrulama 2: ilk iş kontrolü — geçmiş kaynaklarına göre temerrüt
-- =====================================================================
-- SELECT 'Büro kaydı'      AS kaynak, buro_kaydi_var     AS var_mi, COUNT(*) AS musteri,
--        ROUND(100.0 * AVG(target), 2) AS temerrut_orani FROM core.musteri GROUP BY 2
-- UNION ALL
-- SELECT 'Önceki başvuru', onceki_basvuru_var, COUNT(*),
--        ROUND(100.0 * AVG(target), 2) FROM core.musteri GROUP BY 2
-- UNION ALL
-- SELECT 'Kredi kartı',    kart_var, COUNT(*),
--        ROUND(100.0 * AVG(target), 2) FROM core.musteri GROUP BY 2
-- ORDER BY 1, 2;
