-- =====================================================================
-- metrics.v_portfoy_kpi
-- Kaynak: core.musteri
-- Grain: tek satır (portföyün tamamı)
-- Amaç: Dashboard'un "Yönetici Özeti" sayfasındaki KPI kartları.
--
-- Metrik tanımları:
--   temerrut_orani        = target=1 müşteri / tüm müşteri (adet bazında)
--   temerrut_tutar_orani  = target=1 kredi tutarı / toplam kredi tutarı
--   dsr (taksit/gelir)    = yıllık taksit / yıllık gelir
--   yuksek_dsr_orani      = DSR > 0,30 olan müşteri payı
--                           (0,30 eşiği bir varsayımdır)
--   kart_penetrasyonu     = Home Credit kartı olan müşteri / tüm müşteri
--   kredi_gecmisi_olmayan = büro kaydı olmayan müşteri / tüm müşteri
--
-- Not: PERCENTILE_CONT double precision döndürür; Postgres'te
--      ROUND(double, n) yoktur → önce ::numeric.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS metrics;

CREATE OR REPLACE VIEW metrics.v_portfoy_kpi AS
SELECT
    -- ===== Hacim =====
    COUNT(*)                                                          AS musteri_sayisi,
    SUM(amt_credit)                                                   AS toplam_kredi_tutari,
    ROUND(AVG(amt_credit), 0)                                         AS ort_kredi_tutari,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amt_credit))::numeric, 0)
                                                                      AS medyan_kredi_tutari,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amt_income_total))::numeric, 0)
                                                                      AS medyan_gelir,

    -- ===== Risk =====
    SUM(target)                                                       AS temerrut_sayisi,
    ROUND(100.0 * AVG(target), 2)                                     AS temerrut_orani,
    ROUND(100.0 * SUM(amt_credit) FILTER (WHERE target = 1)
          / SUM(amt_credit), 2)                                       AS temerrut_tutar_orani,

    -- ===== Borçluluk =====
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kredi_gelir_orani))::numeric, 2)
                                                                      AS medyan_kredi_gelir,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY taksit_gelir_orani))::numeric, 3)
                                                                      AS medyan_dsr,
    ROUND(100.0 * AVG(CASE WHEN taksit_gelir_orani > 0.30 THEN 1 ELSE 0 END), 2)
                                                                      AS yuksek_dsr_orani,

    -- ===== Müşteri yapısı =====
    ROUND(100.0 * AVG(kart_var), 2)                                   AS kart_penetrasyonu,
    ROUND(100.0 * (1 - AVG(buro_kaydi_var)), 2)                       AS kredi_gecmisi_olmayan_orani,
    ROUND(100.0 * AVG(onceki_basvuru_var), 2)                         AS mevcut_musteri_orani
FROM core.musteri;


-- =====================================================================
-- Kontrol
-- Beklenen: musteri_sayisi 307.511 | temerrut_orani 8,07
--           kredi_gecmisi_olmayan_orani 14,31
-- =====================================================================
-- SELECT * FROM metrics.v_portfoy_kpi;
