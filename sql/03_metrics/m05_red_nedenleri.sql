-- =====================================================================
-- metrics.v_red_nedenleri
-- Kaynak: staging.previous_application
-- Grain: 1 satır = red nedeni × ürün × karar dönemi
-- Amaç: Sayfa 5, red nedenleri grafiği.
--
-- Notlar:
--   - Yalnızca reddedilen başvurular (name_contract_status = 'Refused').
--   - Red kodlarının resmi açıklaması veri setinde YOK. Açıklamalar
--     kod adından tahmindir; dashboard'da "tahmini" diye belirtilmeli.
--   - 7 başvuru reddedilmemiş ama red kodu almış (staging profil C3);
--     bu filtreyle dışarıda kalıyorlar.
-- =====================================================================

DROP VIEW IF EXISTS metrics.v_red_nedenleri;

CREATE VIEW metrics.v_red_nedenleri AS
SELECT
    COALESCE(code_reject_reason, 'Bilinmiyor')                    AS red_kodu,
    CASE code_reject_reason
        WHEN 'HC'     THEN 'HC (açıklanmamış)'
        WHEN 'LIMIT'  THEN 'Limit yetersiz (tahmini)'
        WHEN 'SCO'    THEN 'Skor yetersiz (tahmini)'
        WHEN 'SCOFR'  THEN 'Skor / dolandırıcılık şüphesi (tahmini)'
        WHEN 'VERIF'  THEN 'Doğrulama sorunu (tahmini)'
        WHEN 'SYSTEM' THEN 'Sistem (tahmini)'
        WHEN 'CLIENT' THEN 'Müşteri vazgeçti'
        ELSE               'Bilinmiyor'
    END                                                           AS red_nedeni,
    CASE name_contract_type
        WHEN 'Cash loans'      THEN 'Nakit kredi'
        WHEN 'Consumer loans'  THEN 'Tüketici (POS) kredisi'
        WHEN 'Revolving loans' THEN 'Döner kredi'
        ELSE 'Bilinmiyor'
    END                                                           AS urun_turu,
    CASE
        WHEN days_decision >= -365  THEN '1) Son 1 yıl'
        WHEN days_decision >= -730  THEN '2) 1-2 yıl önce'
        WHEN days_decision >= -1095 THEN '3) 2-3 yıl önce'
        WHEN days_decision >= -1825 THEN '4) 3-5 yıl önce'
        ELSE                             '5) 5 yıldan eski'
    END                                                           AS karar_donemi,
    COUNT(*)                                                      AS red_sayisi,
    SUM(amt_application)                                          AS reddedilen_tutar
FROM staging.previous_application
WHERE name_contract_status = 'Refused'
  AND flag_last_appl_per_contract = 1
GROUP BY 1, 2, 3, 4;


-- =====================================================================
-- Kontrol
-- =====================================================================
-- SELECT red_nedeni, SUM(red_sayisi) AS red,
--        ROUND(100.0 * SUM(red_sayisi) / SUM(SUM(red_sayisi)) OVER (), 2) AS pay
-- FROM metrics.v_red_nedenleri
-- GROUP BY 1 ORDER BY 2 DESC;
