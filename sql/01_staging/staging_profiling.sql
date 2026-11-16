-- =====================================================================
-- HOME CREDIT - STAGING PROFİL VE KARAR KAYDI
-- Amaç: Staging tablolarını yazmadan önce yapılan profil sorgularını,
--       bulguları ve verilen dönüşüm kararlarını tek yerde toplamak.
-- Kaynak: raw şeması (tüm sütunlar TEXT)
-- İlgili dosyalar: sql/01_staging/stg_*.sql
--
-- İçindekiler
--   A. Genel yöntem ve kurallar
--   B. application_train   → staging.application
--   C. previous_application → staging.previous_application
--   D. installments_payments → staging.installments_payments
--   E. bureau              → staging.bureau
--   F. bureau_balance      → staging.bureau_balance
--   G. pos_cash_balance    → staging.pos_cash_balance
--   H. credit_card_balance → staging.credit_card_balance
--   I. Staging doğrulama sorguları
-- =====================================================================


-- =====================================================================
-- A. GENEL YÖNTEM VE KURALLAR
-- ---------------------------------------------------------------------
-- Her tablo için adımlar:
--   1) Önek / sütun profili → 2) Şüpheli değer kontrolü →
--   3) Tip kararları → 4) stg_*.sql yaz → 5) psql -f ile çalıştır →
--   6) Doğrulama sorgusu
--
-- Genel kurallar:
--   - Bilgiyi silme, işaretle: tuhaf değer → NULL + bayrak sütunu.
--   - '1.0' gibi ondalıklı yazılmış tam sayılar → ::numeric::int
--     (Postgres'te '1.0'::int HATA verir).
--   - Bölmelerde NULLIF(payda, 0) → sıfıra bölme hatası olmaz.
--   - Bir kalıp görünce önce kırılıma bak: rastgele hata her yere
--     dağılır, sistematik yer tutucu belirli bir grupta toplanır.
--   - İş kuralı doğrulaması: sütunlar arası mantık (ör. kapanış
--     açılıştan önce olamaz).
--   - Oranın yanında her zaman adet göster (küçük gruplar yanıltır).
--   - SQL dosyaları terminalden çalıştırılır:
--       psql homecredit -f sql/01_staging/stg_xxx.sql
-- =====================================================================


-- =====================================================================
-- B. APPLICATION_TRAIN → staging.application
-- =====================================================================

-- B1. Sütunları öneke göre grupla
-- Bulgu: 122 sütun ~15 gruba indi (amt_, days_, flag_, name_ ...).
--   İstisnalar:
--   - amt_req_credit_bureau_* tutar değil, sorgu ADEDİ → int
--   - fondkapremont/housetype/wallsmaterial/emergencystate_mode
--     sayı değil KATEGORİ → text
SELECT
    SPLIT_PART(column_name, '_', 1)                          AS onek,
    COUNT(*)                                                 AS sutun_sayisi,
    STRING_AGG(column_name, ', ' ORDER BY ordinal_position)  AS sutunlar
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name   = 'application_train'
GROUP BY 1
ORDER BY 2 DESC;

-- B2. Bayrak ve cinsiyet değerleri
-- Bulgu: flag_own_car, flag_own_realty → Y/N (0/1 değil) → CASE ile 0/1
--        code_gender: F 202.448 | M 105.059 | XNA 4 → XNA NULL
SELECT 'flag_own_car' AS sutun, flag_own_car AS deger, COUNT(*) FROM raw.application_train GROUP BY 2
UNION ALL
SELECT 'flag_own_realty', flag_own_realty, COUNT(*) FROM raw.application_train GROUP BY 2
UNION ALL
SELECT 'code_gender', code_gender, COUNT(*) FROM raw.application_train GROUP BY 2
ORDER BY 1, 2;

-- B3. Tam sayıların yazım biçimi
-- Bulgu: '1.0', '-4260.0' biçiminde → ::numeric::int
SELECT cnt_fam_members, days_registration, amt_req_credit_bureau_year, own_car_age
FROM raw.application_train
WHERE own_car_age IS NOT NULL
LIMIT 5;

-- B4. days_employed yer tutucusu
-- Bulgu: 55.374 satır (%18) = 365.243 gün (~1.000 yıl) → yer tutucu
SELECT
    COUNT(*) FILTER (WHERE days_employed::numeric > 0)  AS pozitif_adet,
    MAX(days_employed::numeric)                         AS en_buyuk_deger
FROM raw.application_train;

-- B5. Yer tutucu kimde?
-- Bulgu: 55.352 emekli + 22 işsiz.
--   - Emekliler en düşük riskli grup: %5,39 (genel %8,07).
--   - KARAR: days_employed 365243 → NULL + calisma_bilgisi_yok bayrağı.
--   - İşsiz (22) ve doğum izni (5) oranları küçük örneklem → yorumlanmaz.
SELECT
    name_income_type,
    COUNT(*)                                                 AS toplam,
    COUNT(*) FILTER (WHERE days_employed::numeric = 365243)  AS placeholder_adet,
    ROUND(100.0 * AVG(target::int), 2)                       AS temerrut_orani
FROM raw.application_train
GROUP BY 1
ORDER BY 2 DESC;

-- B6. SELECT listesi üretici (122 sütun için SQL'i SQL ile üretmek)
-- Not: stg_application.sql bu çıktıyla yazıldı. CASE ilk eşleşen
--      kuralda durur; özel durumlar üstte, genel kural (ELSE) altta.
SELECT STRING_AGG(
    CASE
        WHEN column_name IN ('flag_own_car', 'flag_own_realty')
            THEN 'CASE WHEN ' || column_name || ' = ''Y'' THEN 1 ELSE 0 END AS ' || column_name
        WHEN column_name = 'code_gender'
            THEN 'NULLIF(code_gender, ''XNA'') AS code_gender'
        WHEN column_name = 'days_employed'
            THEN 'NULLIF(days_employed::numeric::int, 365243) AS days_employed'
        WHEN column_name IN ('occupation_type', 'organization_type',
                             'weekday_appr_process_start', 'fondkapremont_mode',
                             'housetype_mode', 'wallsmaterial_mode', 'emergencystate_mode')
             OR column_name LIKE 'name\_%'
            THEN column_name
        WHEN column_name IN ('amt_income_total', 'amt_credit', 'amt_annuity',
                             'amt_goods_price', 'region_population_relative')
             OR column_name LIKE 'ext\_source%'
             OR column_name LIKE '%\_avg'
             OR column_name LIKE '%\_mode'
             OR column_name LIKE '%\_medi'
            THEN column_name || '::numeric AS ' || column_name
        ELSE column_name || '::numeric::int AS ' || column_name
    END,
    E',\n    ' ORDER BY ordinal_position
) AS select_listesi
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name   = 'application_train';

-- B7. Türetilen sütunlar (stg_application.sql)
--   yas, calisma_yili, calisma_bilgisi_yok,
--   kredi_gelir_orani, taksit_gelir_orani (DSR), kredi_mal_orani (LTV benzeri)
-- Doğrulama bulguları:
--   yaş 20,5–69,1 | max çalışma 49 yıl | calisma_bilgisi_yok 55.374
--   medyan kredi/gelir 3,27 | medyan taksit/gelir 0,163 | medyan kredi/mal 1,119
--   - Kredi mal fiyatından ~%12 fazla (sigorta, masraf); <1 = peşinat.


-- =====================================================================
-- C. PREVIOUS_APPLICATION → staging.previous_application
-- =====================================================================

-- C1. Sütunları öneke göre grupla
-- Bulgu: 37 sütun. rate_* (faiz/peşinat oranları) bu tabloda var.
SELECT
    SPLIT_PART(column_name, '_', 1)                          AS onek,
    COUNT(*)                                                 AS sutun_sayisi,
    STRING_AGG(column_name, ', ' ORDER BY ordinal_position)  AS sutunlar
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name   = 'previous_application'
GROUP BY 1
ORDER BY 2 DESC;

-- C2. days_* sütunlarında 365243 yer tutucusu
-- Bulgu: decision 0 | first_drawing 934.444 (~%56) | first_due 40.645
--        last_due_1st 93.864 | last_due 211.221 | termination 225.913
--   - Yaşam döngüsü olayı "gerçekleşmedi / henüz gerçekleşmedi".
--   - KARAR: days_decision hariç hepsinde 365243 → NULL.
SELECT
    COUNT(*) FILTER (WHERE days_decision::numeric             = 365243) AS days_decision,
    COUNT(*) FILTER (WHERE days_first_drawing::numeric        = 365243) AS days_first_drawing,
    COUNT(*) FILTER (WHERE days_first_due::numeric            = 365243) AS days_first_due,
    COUNT(*) FILTER (WHERE days_last_due_1st_version::numeric = 365243) AS days_last_due_1st,
    COUNT(*) FILTER (WHERE days_last_due::numeric             = 365243) AS days_last_due,
    COUNT(*) FILTER (WHERE days_termination::numeric          = 365243) AS days_termination
FROM raw.previous_application;

-- C3. Bayrak, durum ve red nedeni
-- Bulgu:
--   Durum: Approved 1.036.781 (%62,1) | Canceled 316.319 (%18,9)
--          Refused 290.678 (%17,4) | Unused offer 26.436 (%1,6)
--   Onay oranının iki tanımı:
--     - Onaylanan / tüm başvurular            = %62,1 (krediye dönüşme)
--     - Onaylanan / (onaylanan + reddedilen)  = %78,1 (bankanın evet deme oranı)
--   Red nedeni:
--     - XAP 1.353.093 = uygulanamaz (reddedilmemiş) → NULL
--     - XNA 5.244     = bilgi yok                   → 'Bilinmiyor'
--     - CLIENT 26.436 = Unused offer ile birebir aynı → müşteri vazgeçmiş
--     - HC, LIMIT, SCO, SCOFR, VERIF, SYSTEM: resmi açıklama yok (tahmin)
--   Çapraz kontrol: red kodları toplamı 290.685 vs Refused 290.678 → 7 fark.
--   flag_last_appl_per_contract: Y 1.661.739 | N 8.475 (olası tekrar) → 0/1
SELECT 'flag_last_appl_per_contract' AS sutun, flag_last_appl_per_contract AS deger, COUNT(*) FROM raw.previous_application GROUP BY 2
UNION ALL
SELECT 'name_contract_status', name_contract_status, COUNT(*) FROM raw.previous_application GROUP BY 2
UNION ALL
SELECT 'code_reject_reason', code_reject_reason, COUNT(*) FROM raw.previous_application GROUP BY 2
ORDER BY 1, 3 DESC;

-- C4. Faiz ve peşinat doluluğu
-- Bulgu: faiz %0,36 | imtiyazlı faiz %0,36 | peşinat %46,36
--   - Faiz neredeyse tamamen boş → fiyatlama analizi bu veriyle YAPILAMAZ.
--   - Peşinat muhtemelen yalnızca belirli ürünlerde dolu (ileride kontrol).
SELECT
    COUNT(*)                                                       AS toplam,
    ROUND(100.0 * COUNT(rate_interest_primary)    / COUNT(*), 2)   AS faiz_dolu_yuzde,
    ROUND(100.0 * COUNT(rate_interest_privileged) / COUNT(*), 2)   AS imtiyazli_faiz_dolu_yuzde,
    ROUND(100.0 * COUNT(rate_down_payment)        / COUNT(*), 2)   AS pesinat_dolu_yuzde
FROM raw.previous_application;

-- C5. Türetilen sütunlar (stg_previous_application.sql)
--   onaylandi (0/1), onaylanan_istenen_orani (amt_credit / amt_application)


-- =====================================================================
-- D. INSTALLMENTS_PAYMENTS → staging.installments_payments
-- =====================================================================

-- D1. Boşluklar, yer tutucular ve uç değerler
-- Bulgu (13.605.401 satır):
--   - Ödeme tarihi / tutarı boş: 2.905 (aynı satırlar, %0,02) → korunuyor
--   - 365243 yer tutucusu: yok
--   - Gecikme aralığı: −3.189 ile +2.884 gün → uç değerler silinmiyor,
--     analizde DPD kovalarıyla ele alınacak
--   - Sıfır ödeme: 1.440
--   - Grain = ödeme hareketi (taksit parça parça ödenebilir).
--     Primary key yok → sk_id_prev ve sk_id_curr üzerinde index.
SELECT
    COUNT(*)                                                      AS toplam,
    COUNT(*) - COUNT(days_entry_payment)                          AS odeme_tarihi_bos,
    COUNT(*) - COUNT(amt_payment)                                 AS odeme_tutari_bos,
    COUNT(*) FILTER (WHERE days_instalment::numeric    = 365243)  AS vade_placeholder,
    COUNT(*) FILTER (WHERE days_entry_payment::numeric = 365243)  AS odeme_placeholder,
    MIN(days_entry_payment::numeric - days_instalment::numeric)   AS en_erken_odeme,
    MAX(days_entry_payment::numeric - days_instalment::numeric)   AS en_gec_odeme,
    COUNT(*) FILTER (WHERE amt_payment::numeric = 0)              AS sifir_odeme
FROM raw.installments_payments;

-- D2. Türetilen sütunlar (stg_installments_payments.sql)
--   gecikme_gun (+ geç, − erken), gec_odendi (0/1),
--   eksik_odeme (+ eksik, − fazla), odeme_orani
-- Doğrulama bulguları:
--   - Ödemelerin %8,43'ü geç (ödeme satırı bazında).
--   - Medyan gecikme −6 gün: tipik müşteri vadeden 6 gün önce ödüyor.
--   - p99 = 18 gün: ödemelerin %99'u vadeden en fazla 18 gün sonra.
--   - Not: Taksit ve müşteri bazında oranlar core katmanında hesaplanacak.


-- =====================================================================
-- E. BUREAU → staging.bureau
-- =====================================================================

-- E1. Kategori değerleri
-- Bulgu:
--   credit_active: Closed 1.079.273 (%62,9) | Active 630.607 (%36,7)
--                  Sold 6.527 | Bad debt 21
--     → Sold / Bad debt = ciddi geçmiş temerrüt → olumsuz_kapanis bayrağı
--   credit_currency: currency 1 %99,92; diğer üçü toplam 1.408
--     → kur yok; tutar toplamlarında yalnızca currency 1 (ana_para_birimi)
--   credit_type: 15 tür; Consumer %72,9 + Credit card %23,4 = %96
--     → kredi_turu_grup: Tüketici, Kredi kartı, Taşıt, Konut,
--       Mikrokredi, Ticari, Diğer
SELECT 'credit_active' AS sutun, credit_active AS deger, COUNT(*) FROM raw.bureau GROUP BY 2
UNION ALL
SELECT 'credit_currency', credit_currency, COUNT(*) FROM raw.bureau GROUP BY 2
UNION ALL
SELECT 'credit_type', credit_type, COUNT(*) FROM raw.bureau GROUP BY 2
ORDER BY 1, 3 DESC;

-- E2. Tarih aralıkları
-- Bulgu:
--   days_credit (açılış)              −2.922 … 0       ✓ (~8 yıl geriye)
--   days_credit_enddate (plan bitiş)  −42.060 … +31.199 ✗
--   days_enddate_fact (gerçek bitiş)  −42.023 … 0       ✗
--   days_credit_update (güncelleme)   −41.947 … +372    ✗
SELECT
    MIN(days_credit::numeric)          AS min_acilis,
    MAX(days_credit::numeric)          AS max_acilis,
    MIN(days_credit_enddate::numeric)  AS min_planlanan_bitis,
    MAX(days_credit_enddate::numeric)  AS max_planlanan_bitis,
    MIN(days_enddate_fact::numeric)    AS min_gercek_bitis,
    MAX(days_enddate_fact::numeric)    AS max_gercek_bitis,
    MIN(days_credit_update::numeric)   AS min_guncelleme,
    MAX(days_credit_update::numeric)   AS max_guncelleme
FROM raw.bureau;

-- E3. İş kuralı ihlalleri (kaç satır etkileniyor?)
-- Bulgu:
--   Planlanan bitiş açılıştan önce: 164   → NULL
--   Planlanan bitiş > 40 yıl:       38.485 → incelendi (E4)
--   Gerçek bitiş açılıştan önce:    20    → NULL
--   Güncelleme başvurudan sonra:    17    → NULL
--   Güncelleme açılıştan önce:      135   → NULL
--   40 yıl eşiği varsayımdır (en uzun vadeli ürün: konut).
SELECT
    COUNT(*) AS toplam,
    COUNT(*) FILTER (WHERE days_credit_enddate::numeric < days_credit::numeric)  AS plan_bitis_acilistan_once,
    COUNT(*) FILTER (WHERE days_credit_enddate::numeric > 365 * 40)              AS plan_bitis_40_yildan_fazla,
    COUNT(*) FILTER (WHERE days_enddate_fact::numeric   < days_credit::numeric)  AS gercek_bitis_acilistan_once,
    COUNT(*) FILTER (WHERE days_credit_update::numeric  > 0)                     AS guncelleme_basvurudan_sonra,
    COUNT(*) FILTER (WHERE days_credit_update::numeric  < days_credit::numeric)  AS guncelleme_acilistan_once
FROM raw.bureau;

-- E4. 40 yıldan uzak bitiş: hangi kredi türlerinde?
-- Bulgu: 38.485'in 38.298'i (%99,5) kredi kartı (kartların %9,5'i).
--        Tüketici kredisinde 187 (dağınık → gerçek hata).
--   → Kartlarda "vadesiz ürün" yer tutucusu.
--   → KARAR: > 40 yıl → NULL + plan_bitis_yok bayrağı.
SELECT
    credit_type,
    COUNT(*)                                                                AS toplam,
    COUNT(*) FILTER (WHERE days_credit_enddate::numeric > 365 * 40)          AS uzak_bitis,
    ROUND(100.0 * COUNT(*) FILTER (WHERE days_credit_enddate::numeric > 365 * 40)
          / COUNT(*), 1)                                                    AS uzak_bitis_yuzde
FROM raw.bureau
GROUP BY 1
HAVING COUNT(*) FILTER (WHERE days_credit_enddate::numeric > 365 * 40) > 0
ORDER BY 3 DESC;

-- E5. Tutarlar ve doluluk
-- Bulgu:
--   Negatif borç 8.418 (%0,5) = fazla ödeme → korunuyor,
--     borç yükü için borc_pozitif = GREATEST(borç, 0)
--   Negatif limit 351 → NULL
--   Doluluk: borç %85 | taksit %28,5 (zayıf) | max gecikme tutarı %34,5
--   En uzun mevcut gecikme: 2.792 gün (~7,6 yıl)
SELECT
    COUNT(*)                                                   AS toplam,
    COUNT(*) FILTER (WHERE amt_credit_sum_debt::numeric < 0)   AS negatif_borc,
    COUNT(*) FILTER (WHERE amt_credit_sum_limit::numeric < 0)  AS negatif_limit,
    ROUND(100.0 * COUNT(amt_credit_sum_debt) / COUNT(*), 2)    AS borc_dolu_yuzde,
    ROUND(100.0 * COUNT(amt_annuity) / COUNT(*), 2)            AS taksit_dolu_yuzde,
    ROUND(100.0 * COUNT(amt_credit_max_overdue) / COUNT(*), 2) AS max_gecikme_dolu_yuzde,
    MAX(credit_day_overdue::numeric)                           AS max_gecikme_gun
FROM raw.bureau;

-- E6. Türetilen sütunlar (stg_bureau.sql)
--   kredi_turu_grup, aktif, olumsuz_kapanis, ana_para_birimi,
--   plan_bitis_yok, su_an_gecikmede, borc_pozitif


-- =====================================================================
-- F. BUREAU_BALANCE → staging.bureau_balance
-- =====================================================================

-- F1. Referans bütünlüğü (yetim kayıtlar ve kapsama)
-- Not: İlk deneme NOT IN (alt sorgu) ile yazıldı ve 3+ dakikada bitmedi.
--      Büyük tablolarda NOT IN yerine JOIN kullanılır.
--      FULL OUTER JOIN iki taraftaki eşleşmeyenleri tek sorguda gösterir.
-- Bulgu:
--   Aylık geçmişi olan kredi (bureau_balance):  817.395
--   Yetim kredi (bureau'da kaydı yok):          43.041 (%5,3)
--     → müşteriye bağlanamaz, join'de düşer; silinmiyor, belgeleniyor
--   Büro kredisi (bureau):                    1.716.428
--   Aylık geçmişi olan büro kredisi:            774.354 (yalnızca %45)
--     → DPD analizi büro kredilerinin yarısından azını kapsar.
--       Geçmişi olmayan "gecikmesiz" değil, "bilinmiyor" sayılmalı.
WITH bb AS (
    SELECT DISTINCT sk_id_bureau::numeric::int AS sk_id_bureau
    FROM raw.bureau_balance
)
SELECT
    COUNT(bb.sk_id_bureau)                                            AS bb_kredi_sayisi,
    COUNT(*) FILTER (WHERE bb.sk_id_bureau IS NOT NULL
                       AND b.sk_id_bureau  IS NULL)                   AS yetim_kredi,
    COUNT(b.sk_id_bureau)                                             AS bureau_kredi_sayisi,
    COUNT(*) FILTER (WHERE bb.sk_id_bureau IS NOT NULL
                       AND b.sk_id_bureau  IS NOT NULL)               AS gecmisi_olan_kredi
FROM bb
FULL OUTER JOIN staging.bureau b
    ON b.sk_id_bureau = bb.sk_id_bureau;

-- F2. Türetilen sütunlar (stg_bureau_balance.sql)
--   aktif_ay (status 0-5), gecikmede, gecikme_90_arti, dpd_kova
--   - gecikmede ve gecikme_90_arti C/X aylarında NULL → AVG() otomatik
--     olarak yalnızca aktif aylar üzerinden hesaplanır (doğru payda).
--   - Bileşik primary key (sk_id_bureau, months_balance) hatasız kuruldu
--     → tekrar eden kredi-ay yok.
-- Doğrulama bulguları:
--   Gecikme oranı (aktif aylar) %4,37 | 90+ oranı (aktif aylar) %0,87
--   Ay aralığı −96 … 0 (8 yıl) → bureau.days_credit (−2.922 gün) ile tutarlı


-- =====================================================================
-- G. POS_CASH_BALANCE → staging.pos_cash_balance
-- =====================================================================

-- G1. Benzersizlik, gecikme ve boşluklar
-- Not: COUNT(DISTINCT (a, b)) iki sütunun birlikte benzersizliğini sayar.
-- Bulgu (10.001.358 satır):
--   - (sk_id_prev, months_balance) benzersiz → bileşik primary key
--   - En eski ay −96 (8 yıl)
--   - En yüksek gecikme 4.231 gün (~11,6 yıl, pencereden uzun; şüpheli,
--     silinmiyor)
--   - Gecikmeli ay: sk_dpd > 0 → 295.227 (%2,95)
--                   sk_dpd_def > 0 → 113.969 (%1,14)
--     → Gecikmelerin ~%61'i küçük tutarlı (önemlilik eşiği altında).
--     → KARAR: risk ölçümünde toleranslı gecikme (sk_dpd_def) kullanılır.
--   - Vade boş: 26.071 (%0,26)
SELECT
    COUNT(*)                                        AS toplam,
    COUNT(DISTINCT (sk_id_prev, months_balance))    AS benzersiz_kredi_ay,
    MIN(months_balance::int)                        AS en_eski_ay,
    MAX(sk_dpd::int)                                AS max_dpd,
    COUNT(*) FILTER (WHERE sk_dpd::int > 0)         AS gecikmeli_ay,
    COUNT(*) FILTER (WHERE sk_dpd_def::int > 0)     AS gecikmeli_ay_tolerans,
    COUNT(*) - COUNT(cnt_instalment)                AS vade_bos
FROM raw.pos_cash_balance;

-- G2. Sözleşme durumları
-- Bulgu: Active 9.151.119 (%91,5) | Completed 744.883 (%7,4)
--        Signed 87.260 | Demand 7.065 | Returned to the store 5.461
--        Approved 4.917 | Amortized debt 636 | Canceled 15 | XNA 2 (→ NULL)
--   - Demand = muacceliyet (borcun tamamı talep edilmiş) → ciddi temerrüt
--   - Amortized debt: resmi açıklama yok (tahmin: zarar yazılmış borç)
--   → KARAR: Demand + Amortized debt = olumsuz_durum bayrağı
SELECT name_contract_status, COUNT(*) AS adet
FROM raw.pos_cash_balance
GROUP BY 1
ORDER BY 2 DESC;

-- G3. Türetilen sütunlar (stg_pos_cash_balance.sql)
--   gecikmede, gecikme_90_arti, dpd_kova (sk_dpd_def üzerinden; büro ile
--   aynı isim ve kova yapısı), olumsuz_durum, kalan_taksit_orani


-- =====================================================================
-- H. CREDIT_CARD_BALANCE → staging.credit_card_balance
-- =====================================================================

-- H1. Bakiye, limit, harcama ve boşluklar
-- Bulgu (3.840.312 satır):
--   - (sk_id_prev, months_balance) benzersiz → bileşik primary key
--   - Negatif bakiye 2.345 (fazla ödeme) → korunuyor
--   - Sıfır limit 753.823 (%19,6) → incelendi (H2)
--   - Limit aşımı (bakiye > limit > 0) 334.362 (%8,7) → limit_asimi bayrağı
--   - Negatif harcama 4 (iade/iptal) → korunuyor
--   - Ödeme boş 767.988 | ATM boş 749.816 → incelendi (H2)
--   - En uzun toleranslı gecikme 3.260 gün
SELECT
    COUNT(*)                                                         AS toplam,
    COUNT(DISTINCT (sk_id_prev, months_balance))                     AS benzersiz_kart_ay,
    COUNT(*) FILTER (WHERE amt_balance::numeric < 0)                 AS negatif_bakiye,
    COUNT(*) FILTER (WHERE amt_credit_limit_actual::numeric = 0)     AS sifir_limit,
    COUNT(*) FILTER (WHERE amt_balance::numeric
                         > amt_credit_limit_actual::numeric
                       AND amt_credit_limit_actual::numeric > 0)     AS limit_asimi,
    COUNT(*) FILTER (WHERE amt_drawings_atm_current::numeric < 0
                        OR amt_drawings_current::numeric < 0)        AS negatif_harcama,
    COUNT(*) - COUNT(amt_payment_current)                            AS odeme_bos,
    COUNT(*) - COUNT(amt_drawings_atm_current)                       AS atm_bos,
    MAX(sk_dpd_def::numeric)                                         AS max_dpd_def
FROM raw.credit_card_balance;

-- H2. Hipotez testi: sıfır limit ve boş alanlar aynı satırlar mı?
-- Hipotez: Sıfır limit, boş ödeme ve boş ATM sayıları birbirine çok yakın
--          → hepsi aynı "aktif olmayan kart ayı" satırları.
-- Bulgu:
--   Limit durumu  Satır      Bakiyeli   Ödeme boş  ATM boş   Harcama yapan
--   Limit var     3.086.489  1.673.555  578.924    558.078   612.216
--   Sıfır limit     753.823      7.992  189.064    191.738     4.650
--   ✓ Sıfır limit = aktif olmayan kart ayı (yalnızca %1'inde bakiye var)
--     → aktif_kart_ayi = limit > 0; kullanım oranı sıfır limitte NULL
--   ✗ Boş alanlar aynı satırlar DEĞİL (~579 bin boş ödeme limitli kartlarda)
--     → NULL = "o ay ilgili hareket kaydı yok"; 0'a çevrilmiyor
--   Ders: Hipotezi test etmeden davranılsaydı 579 bin aktif kart ayı
--         yanlışlıkla analizden çıkarılırdı.
SELECT
    CASE WHEN amt_credit_limit_actual::numeric = 0
         THEN 'Sıfır limit' ELSE 'Limit var' END                    AS limit_durumu,
    COUNT(*)                                                         AS satir,
    COUNT(*) FILTER (WHERE amt_balance::numeric > 0)                 AS bakiyesi_olan,
    COUNT(*) FILTER (WHERE amt_payment_current IS NULL)              AS odeme_bos,
    COUNT(*) FILTER (WHERE amt_drawings_atm_current IS NULL)         AS atm_bos,
    COUNT(*) FILTER (WHERE amt_drawings_current::numeric > 0)        AS harcama_yapan
FROM raw.credit_card_balance
GROUP BY 1;

-- H3. Sözleşme durumları
-- Bulgu: Active 3.698.436 | Completed 128.918 | Signed 11.058
--        Demand 1.365 | Sent proposal 513 | Refused 17 | Approved 5
--   → Demand = olumsuz_durum; XNA yok.
SELECT name_contract_status, COUNT(*) AS adet
FROM raw.credit_card_balance
GROUP BY 1
ORDER BY 2 DESC;

-- H4. Türetilen sütunlar (stg_credit_card_balance.sql)
--   Kart kullanımı:
--     aktif_kart_ayi, limit_kullanim_orani (bakiye / limit),
--     limit_asimi, asgari_odeme_karsilama (ödeme / asgari),
--     asgari_alti_odeme (NULL'lu bayrak), nakit_avans_payi (ATM / toplam)
--   Gecikme (POS ve büro ile aynı yapı):
--     gecikmede, gecikme_90_arti, dpd_kova, olumsuz_durum
--   Not: amt_recivable sütun adındaki yazım hatası kaynaktan geliyor.


-- =====================================================================
-- I. STAGING DOĞRULAMA SORGULARI
-- Tablolar kurulduktan sonra, beklenen değerlerle karşılaştır.
-- =====================================================================

-- I1. Satır sayıları (raw ile aynı olmalı)
-- Beklenen: application 307.511 | previous_application 1.670.214
--           installments_payments 13.605.401 | bureau 1.716.428
--           bureau_balance 27.299.925 | pos_cash_balance 10.001.358
--           credit_card_balance 3.840.312
SELECT 'application'           AS tablo, COUNT(*) AS satir FROM staging.application
UNION ALL
SELECT 'previous_application',            COUNT(*)          FROM staging.previous_application
UNION ALL
SELECT 'installments_payments',           COUNT(*)          FROM staging.installments_payments
UNION ALL
SELECT 'bureau',                          COUNT(*)          FROM staging.bureau
UNION ALL
SELECT 'bureau_balance',                  COUNT(*)          FROM staging.bureau_balance
UNION ALL
SELECT 'pos_cash_balance',                COUNT(*)          FROM staging.pos_cash_balance
UNION ALL
SELECT 'credit_card_balance',             COUNT(*)          FROM staging.credit_card_balance;

-- I2. staging.application
SELECT
    MIN(yas)                 AS min_yas,
    MAX(yas)                 AS max_yas,
    MAX(calisma_yili)        AS max_calisma_yili,
    SUM(calisma_bilgisi_yok) AS calisma_bilgisi_yok_adet,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kredi_gelir_orani)  AS medyan_kredi_gelir,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY taksit_gelir_orani) AS medyan_taksit_gelir,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kredi_mal_orani)    AS medyan_kredi_mal
FROM staging.application;

-- I3. staging.previous_application
-- Beklenen: onaylı 1.036.781 | red_nedeni_null 1.353.093
SELECT
    COUNT(*)                               AS toplam,
    SUM(onaylandi)                         AS onayli,
    COUNT(*) - COUNT(code_reject_reason)   AS red_nedeni_null,
    COUNT(days_termination)                AS kapanis_tarihi_dolu,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY onaylanan_istenen_orani) AS medyan_onaylanan_istenen
FROM staging.previous_application;

-- I4. staging.installments_payments
-- Beklenen: gecikme_bos 2.905 | geç %8,43 | medyan −6 | p99 18
SELECT
    COUNT(*)                                                   AS toplam,
    COUNT(*) - COUNT(gecikme_gun)                              AS gecikme_bos,
    ROUND(100.0 * AVG(gec_odendi), 2)                          AS gec_odeme_yuzde,
    PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY gecikme_gun)  AS medyan_gecikme,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY gecikme_gun)  AS p99_gecikme
FROM staging.installments_payments;

-- I5. staging.bureau
-- Beklenen: aktif 630.607 | olumsuz_kapanis 6.548 | ana_para_birimi 1.715.020
--           plan_bitis_yok 38.485 | plan_bitis_null ~38.649
SELECT
    COUNT(*)                               AS toplam,
    SUM(aktif)                             AS aktif,
    SUM(olumsuz_kapanis)                   AS olumsuz_kapanis,
    SUM(ana_para_birimi)                   AS ana_para_birimi,
    SUM(plan_bitis_yok)                    AS plan_bitis_yok,
    SUM(su_an_gecikmede)                   AS su_an_gecikmede,
    COUNT(*) - COUNT(days_credit_enddate)  AS plan_bitis_null
FROM staging.bureau;

SELECT kredi_turu_grup, COUNT(*) AS adet
FROM staging.bureau
GROUP BY 1
ORDER BY 2 DESC;

-- I6. staging.bureau_balance
-- Sonuç: gecikme %4,37 | 90+ %0,87 | ay aralığı −96 … 0
SELECT
    COUNT(*)                                AS toplam,
    SUM(aktif_ay)                           AS aktif_ay,
    ROUND(100.0 * AVG(gecikmede), 2)        AS gecikme_yuzde_aktif,
    ROUND(100.0 * AVG(gecikme_90_arti), 2)  AS npl_yuzde_aktif,
    MIN(months_balance)                     AS en_eski_ay,
    MAX(months_balance)                     AS en_yeni_ay
FROM staging.bureau_balance;

-- I7. staging.pos_cash_balance
-- Beklenen: gecikmede 113.969 | olumsuz_durum 7.701 | durum_null 2
SELECT
    COUNT(*)                                AS toplam,
    SUM(gecikmede)                          AS gecikmede,
    SUM(gecikme_90_arti)                    AS gecikme_90_arti,
    SUM(olumsuz_durum)                      AS olumsuz_durum,
    COUNT(*) - COUNT(name_contract_status)  AS durum_null
FROM staging.pos_cash_balance;

SELECT dpd_kova, COUNT(*) AS adet
FROM staging.pos_cash_balance
GROUP BY 1
ORDER BY 1;

-- I8. staging.credit_card_balance
-- Beklenen: aktif_kart_ayi 3.086.489 | limit_asimi 334.362 | olumsuz_durum 1.365
SELECT
    COUNT(*)                                                          AS toplam,
    SUM(aktif_kart_ayi)                                               AS aktif_kart_ayi,
    SUM(limit_asimi)                                                  AS limit_asimi,
    SUM(olumsuz_durum)                                                AS olumsuz_durum,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY limit_kullanim_orani) AS medyan_kullanim,
    ROUND(100.0 * AVG(asgari_alti_odeme), 2)                          AS asgari_alti_yuzde,
    ROUND(100.0 * AVG(gecikmede), 2)                                  AS gecikme_yuzde
FROM staging.credit_card_balance;
