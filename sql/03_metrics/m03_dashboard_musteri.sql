-- =====================================================================
-- metrics.v_dashboard_musteri
-- Kaynak: core.musteri
-- Grain: 1 satır = 1 müşteri (307.511)
-- Amaç: Tableau'nun ANA veri kaynağı. Sayfa 1-4 ve 6-8'i besler.
--       Tüm sayfalardaki ortak filtreler bu view'daki sütunlardan gelir.
--
-- Tasarım:
--   - Kategoriler Türkçeleştirildi (dashboard Türkçe olacak).
--   - Sayısal değişkenler bantlara ayrıldı. Etiketlerin başındaki
--     "1)", "2)" Tableau'da doğru sıralama için.
--   - Oranlar burada HESAPLANMAZ: Tableau'da AVG([temerrut]) ile
--     hesaplanır, böylece her filtre kombinasyonunda doğru çıkar.
--   - Bant eşikleri varsayımdır; README'de belirtilecek.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS metrics;

DROP VIEW IF EXISTS metrics.v_dashboard_musteri;

CREATE VIEW metrics.v_dashboard_musteri AS
SELECT
    -- ===== Kimlik ve hedef =====
    sk_id_curr                                                     AS musteri_id,
    target                                                         AS temerrut,
    CASE WHEN target = 1 THEN 'Temerrüt' ELSE 'Sorunsuz' END       AS temerrut_durumu,

    -- ===== Ürün =====
    CASE name_contract_type
        WHEN 'Cash loans'      THEN 'Nakit kredi'
        WHEN 'Revolving loans' THEN 'Döner kredi'
        ELSE name_contract_type
    END                                                            AS urun_turu,

    -- ===== Demografi =====
    CASE code_gender WHEN 'F' THEN 'Kadın' WHEN 'M' THEN 'Erkek'
                     ELSE 'Bilinmiyor' END                         AS cinsiyet,
    yas,
    CASE
        WHEN yas < 25 THEN '1) 25 altı'
        WHEN yas < 35 THEN '2) 25-34'
        WHEN yas < 45 THEN '3) 35-44'
        WHEN yas < 55 THEN '4) 45-54'
        ELSE               '5) 55 ve üstü'
    END                                                            AS yas_grubu,
    CASE name_education_type
        WHEN 'Secondary / secondary special' THEN 'Lise'
        WHEN 'Higher education'              THEN 'Üniversite'
        WHEN 'Incomplete higher'             THEN 'Üniversite (yarım)'
        WHEN 'Lower secondary'               THEN 'Ortaokul'
        WHEN 'Academic degree'               THEN 'Akademik derece'
        ELSE name_education_type
    END                                                            AS egitim,
    CASE name_income_type
        WHEN 'Working'              THEN 'Maaşlı çalışan'
        WHEN 'Commercial associate' THEN 'Ticari / serbest'
        WHEN 'Pensioner'            THEN 'Emekli'
        WHEN 'State servant'        THEN 'Kamu çalışanı'
        WHEN 'Unemployed'           THEN 'İşsiz'
        WHEN 'Student'              THEN 'Öğrenci'
        WHEN 'Businessman'          THEN 'İş insanı'
        WHEN 'Maternity leave'      THEN 'Doğum izni'
        ELSE name_income_type
    END                                                            AS gelir_turu,
    CASE name_family_status
        WHEN 'Married'              THEN 'Evli'
        WHEN 'Single / not married' THEN 'Bekâr'
        WHEN 'Civil marriage'       THEN 'Nikâhsız birliktelik'
        WHEN 'Separated'            THEN 'Ayrı yaşıyor'
        WHEN 'Widow'                THEN 'Dul'
        ELSE 'Bilinmiyor'
    END                                                            AS medeni_durum,
    CASE name_housing_type
        WHEN 'House / apartment'   THEN 'Ev / daire'
        WHEN 'With parents'        THEN 'Aile yanında'
        WHEN 'Municipal apartment' THEN 'Belediye konutu'
        WHEN 'Rented apartment'    THEN 'Kira'
        WHEN 'Office apartment'    THEN 'Lojman'
        WHEN 'Co-op apartment'     THEN 'Kooperatif'
        ELSE name_housing_type
    END                                                            AS konut_durumu,
    COALESCE(occupation_type, 'Bilinmiyor')                        AS meslek,
    CASE
        WHEN cnt_children = 0 THEN '0'
        WHEN cnt_children = 1 THEN '1'
        WHEN cnt_children = 2 THEN '2'
        ELSE '3+'
    END                                                            AS cocuk_sayisi,
    CASE WHEN flag_own_realty = 1 THEN 'Var' ELSE 'Yok' END        AS ev_sahipligi,
    CASE WHEN flag_own_car    = 1 THEN 'Var' ELSE 'Yok' END        AS arac_sahipligi,
    region_rating_client                                           AS bolge_risk_notu,

    -- ===== Çalışma =====
    calisma_yili,
    CASE
        WHEN calisma_bilgisi_yok = 1 THEN '0) Çalışmıyor / emekli'
        WHEN calisma_yili < 1        THEN '1) 1 yıldan az'
        WHEN calisma_yili < 3        THEN '2) 1-3 yıl'
        WHEN calisma_yili < 5        THEN '3) 3-5 yıl'
        WHEN calisma_yili < 10       THEN '4) 5-10 yıl'
        ELSE                              '5) 10 yıl ve üstü'
    END                                                            AS calisma_suresi_grubu,

    -- ===== Tutarlar =====
    amt_income_total                                               AS gelir,
    amt_credit                                                     AS kredi_tutari,
    amt_annuity                                                    AS taksit_tutari,
    amt_goods_price                                                AS mal_fiyati,
    'Q' || NTILE(5) OVER (ORDER BY amt_income_total)               AS gelir_dilimi,
    CASE
        WHEN amt_credit <  250000  THEN '1) 250 bin altı'
        WHEN amt_credit <  500000  THEN '2) 250-500 bin'
        WHEN amt_credit < 1000000  THEN '3) 500 bin-1 milyon'
        ELSE                            '4) 1 milyon ve üstü'
    END                                                            AS kredi_tutari_grubu,

    -- ===== Borçluluk =====
    kredi_gelir_orani,
    CASE
        WHEN kredi_gelir_orani < 2 THEN '1) 2 altı'
        WHEN kredi_gelir_orani < 4 THEN '2) 2-4'
        WHEN kredi_gelir_orani < 6 THEN '3) 4-6'
        ELSE                            '4) 6 ve üstü'
    END                                                            AS kredi_gelir_grubu,
    taksit_gelir_orani                                             AS dsr,
    CASE
        WHEN taksit_gelir_orani IS NULL THEN '9) Bilinmiyor'
        WHEN taksit_gelir_orani < 0.10  THEN '1) %10 altı'
        WHEN taksit_gelir_orani < 0.20  THEN '2) %10-20'
        WHEN taksit_gelir_orani < 0.30  THEN '3) %20-30'
        ELSE                                 '4) %30 ve üstü'
    END                                                            AS dsr_grubu,
    kredi_mal_orani                                                AS ltv,
    CASE
        WHEN kredi_mal_orani IS NULL THEN '9) Bilinmiyor'
        WHEN kredi_mal_orani < 1     THEN '1) 1 altı (peşinatlı)'
        WHEN kredi_mal_orani = 1     THEN '2) Tam 1'
        WHEN kredi_mal_orani < 1.2   THEN '3) 1-1,2'
        ELSE                              '4) 1,2 ve üstü'
    END                                                            AS ltv_grubu,
    toplam_borc_gelir_orani,

    -- ===== Dış skor (kredi bürosu benzeri skorlar, 0-1) =====
    ROUND(
        (COALESCE(ext_source_1, 0) + COALESCE(ext_source_2, 0) + COALESCE(ext_source_3, 0))
        / NULLIF((ext_source_1 IS NOT NULL)::int
               + (ext_source_2 IS NOT NULL)::int
               + (ext_source_3 IS NOT NULL)::int, 0)
    , 3)                                                           AS dis_skor,

    -- ===== İlişki geçmişi =====
    CASE WHEN buro_kaydi_var = 1     THEN 'Var' ELSE 'Yok' END     AS kredi_gecmisi,
    CASE WHEN onceki_basvuru_var = 1 THEN 'Mevcut müşteri'
                                     ELSE 'Yeni müşteri' END       AS musteri_tipi,
    CASE WHEN kart_var = 1 THEN 'Var' ELSE 'Yok' END               AS kart_sahipligi,

    -- ===== Önceki başvurular =====
    COALESCE(onceki_basvuru_sayisi, 0)                             AS onceki_basvuru_sayisi,
    red_orani,
    CASE
        WHEN onceki_basvuru_sayisi IS NULL THEN '0) Önceki başvuru yok'
        WHEN red_orani IS NULL             THEN '0) Karar verilmiş başvuru yok'
        WHEN red_orani = 0                 THEN '1) Hiç red yok'
        WHEN red_orani < 0.25              THEN '2) %25 altı'
        WHEN red_orani < 0.50              THEN '3) %25-50'
        ELSE                                    '4) %50 ve üstü'
    END                                                            AS red_orani_grubu,

    -- ===== Ödeme davranışı (Home Credit taksitleri) =====
    gec_taksit_orani,
    max_gecikme_gun,
    CASE
        WHEN taksit_sayisi IS NULL     THEN '0) Taksit geçmişi yok'
        WHEN gec_30_arti_sayisi > 0    THEN '3) 30+ gün gecikme var'
        WHEN gec_taksit_sayisi > 0     THEN '2) Yalnızca küçük gecikmeler'
        ELSE                                '1) Hiç gecikme yok'
    END                                                            AS odeme_davranisi,
    pos_gecikmeli_ay_orani,

    -- ===== Kredi kartı =====
    kart_son_ay_kullanim,
    kart_asgari_alti_odeme_orani,
    kart_ort_nakit_avans_payi,
    CASE
        WHEN kart_var = 0                   THEN '0) Kart yok'
        WHEN kart_son_ay_kullanim IS NULL   THEN '0) Son ay aktif değil'
        WHEN kart_son_ay_kullanim < 0.30    THEN '1) %30 altı'
        WHEN kart_son_ay_kullanim < 0.70    THEN '2) %30-70'
        WHEN kart_son_ay_kullanim < 0.90    THEN '3) %70-90'
        ELSE                                     '4) %90 ve üstü (limite dayalı)'
    END                                                            AS kart_kullanim_grubu,

    -- ===== Kredi bürosu (dış borç) =====
    COALESCE(buro_kredi_sayisi, 0)                                 AS buro_kredi_sayisi,
    COALESCE(buro_aktif_kredi_sayisi, 0)                           AS buro_aktif_kredi_sayisi,
    buro_borc_gelir_orani,
    CASE
        WHEN buro_kaydi_var = 0                                   THEN '0) Büro kaydı yok'
        WHEN COALESCE(buro_borc_gelir_orani, 0) = 0               THEN '1) Aktif dış borç yok'
        WHEN buro_borc_gelir_orani < 1                            THEN '2) Gelirin 1 katından az'
        WHEN buro_borc_gelir_orani < 3                            THEN '3) Gelirin 1-3 katı'
        ELSE                                                           '4) Gelirin 3 katı ve üstü'
    END                                                            AS dis_borc_grubu,
    CASE
        WHEN buro_kaydi_var = 0               THEN '0) Büro kaydı yok'
        WHEN buro_son_1yil_acilan_kredi = 0   THEN '1) 0'
        WHEN buro_son_1yil_acilan_kredi = 1   THEN '2) 1'
        WHEN buro_son_1yil_acilan_kredi = 2   THEN '3) 2'
        ELSE                                       '4) 3 ve üstü'
    END                                                            AS kredi_acligi_grubu,
    COALESCE(buro_olumsuz_kapanis_var, 0)                          AS buro_olumsuz_kapanis,
    CASE WHEN buro_su_an_gecikmede_kredi > 0 THEN 1 ELSE 0 END     AS buro_su_an_gecikmede,
    buro_gecikmeli_ay_orani
FROM core.musteri;


-- =====================================================================
-- Kontrol
-- Beklenen: 307.511 satır | AVG(temerrut) = 0,0807
-- =====================================================================
-- SELECT COUNT(*), ROUND(100.0 * AVG(temerrut), 2) FROM metrics.v_dashboard_musteri;
--
-- SELECT odeme_davranisi, COUNT(*) AS musteri,
--        ROUND(100.0 * AVG(temerrut), 2) AS temerrut_orani
-- FROM metrics.v_dashboard_musteri
-- GROUP BY 1 ORDER BY 1;
