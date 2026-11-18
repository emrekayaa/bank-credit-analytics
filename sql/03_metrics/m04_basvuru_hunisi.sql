-- =====================================================================
-- metrics.v_basvuru_hunisi
-- Kaynak: staging.previous_application
-- Grain: 1 satır = ürün × müşteri tipi × kanal × karar dönemi
-- Amaç: Sayfa 5 (Başvuru ve Onay Hunisi).
--
-- ÖNEMLİ (Tableau'da oran hesabı):
--   Bu view ÖZET satırlar içerir. Oranları satır bazında ortalamayın;
--   her zaman toplamların oranını alın:
--     Onay oranı (tümü)    = SUM([onaylanan]) / SUM([basvuru])
--     Onay oranı (karar)   = SUM([onaylanan]) / (SUM([onaylanan]) + SUM([reddedilen]))
--     Onaylanan/istenen    = SUM([onaylanan_tutar]) / SUM([onaylanan_istenen_tutar])
--   Ortalamaların ortalaması yanlış sonuç verir.
--
-- Notlar:
--   - flag_last_appl_per_contract = 0 (olası tekrar kayıt) hariç.
--   - Train + test müşterilerinin başvurularını içerir.
--   - Karar dönemi göreli: başvurudan kaç yıl önce karar verildiği.
-- =====================================================================

DROP VIEW IF EXISTS metrics.v_basvuru_hunisi;

CREATE VIEW metrics.v_basvuru_hunisi AS
SELECT
    CASE name_contract_type
        WHEN 'Cash loans'      THEN 'Nakit kredi'
        WHEN 'Consumer loans'  THEN 'Tüketici (POS) kredisi'
        WHEN 'Revolving loans' THEN 'Döner kredi'
        ELSE 'Bilinmiyor'
    END                                                           AS urun_turu,
    CASE name_client_type
        WHEN 'New'       THEN 'Yeni'
        WHEN 'Repeater'  THEN 'Tekrar eden'
        WHEN 'Refreshed' THEN 'Yenilenmiş'
        ELSE 'Bilinmiyor'
    END                                                           AS musteri_tipi,
    channel_type                                                  AS kanal,
    CASE
        WHEN days_decision >= -365  THEN '1) Son 1 yıl'
        WHEN days_decision >= -730  THEN '2) 1-2 yıl önce'
        WHEN days_decision >= -1095 THEN '3) 2-3 yıl önce'
        WHEN days_decision >= -1825 THEN '4) 3-5 yıl önce'
        ELSE                             '5) 5 yıldan eski'
    END                                                           AS karar_donemi,

    -- ===== Huni adetleri =====
    COUNT(*)                                                      AS basvuru,
    SUM(onaylandi)                                                AS onaylanan,
    COUNT(*) FILTER (WHERE name_contract_status = 'Refused')      AS reddedilen,
    COUNT(*) FILTER (WHERE name_contract_status = 'Canceled')     AS iptal,
    COUNT(*) FILTER (WHERE name_contract_status = 'Unused offer') AS kullanilmayan_teklif,

    -- ===== Tutarlar =====
    SUM(amt_application)                                          AS istenen_tutar,
    SUM(amt_credit)      FILTER (WHERE onaylandi = 1)             AS onaylanan_tutar,
    SUM(amt_application) FILTER (WHERE onaylandi = 1)             AS onaylanan_istenen_tutar
FROM staging.previous_application
WHERE flag_last_appl_per_contract = 1
GROUP BY 1, 2, 3, 4;


-- =====================================================================
-- Kontrol: iki onay oranı (staging'de %62,1 ve %78,1 bulmuştuk;
--          tekrar kayıtlar çıkarıldığı için çok küçük fark olabilir)
-- =====================================================================
-- SELECT
--     SUM(basvuru)                                                    AS basvuru,
--     ROUND(100.0 * SUM(onaylanan) / SUM(basvuru), 2)                 AS onay_orani_tum,
--     ROUND(100.0 * SUM(onaylanan) / (SUM(onaylanan) + SUM(reddedilen)), 2) AS onay_orani_karar
-- FROM metrics.v_basvuru_hunisi;
