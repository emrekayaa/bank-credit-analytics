-- =====================================================================
-- HOME CREDIT - VERİ KEŞFİ (EXPLORATION)
-- Amaç: Tabloların yapısını (grain), anahtarlarını ve ilk iş
-- içgörülerini çıkarmak. Staging/core katmanından önceki keşif adımı.
-- Not: raw katmanında tüm sütunlar TEXT; hesaplarda ::int ile çeviriyoruz.
-- =====================================================================


-- =====================================================================
-- 1. Hedef değişken dağılımı
-- Soru: Başvuruların yüzde kaçı ödeme güçlüğü yaşamış?
-- Bulgu: %8,07 (24.825 / 307.511).
--   - Veri dengesiz (~11'e 1). Modellemede accuracy yerine
--     ROC-AUC, Gini ve PR-AUC kullanılacak.
--   - target = 1, "ilk taksitlerden birinde gecikme" demek;
--     bankaların resmi 90 gün temerrüt (NPL) tanımından daha geniş.
-- =====================================================================
SELECT
    target,
    COUNT(*)                                            AS adet,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS yuzde
FROM raw.application_train
GROUP BY target
ORDER BY target;


-- =====================================================================
-- 2. application_train grain kontrolü
-- Soru: sk_id_curr benzersiz mi?
-- Bulgu: Evet (307.511 satır = 307.511 benzersiz id, fark 0).
--   - Grain: 1 satır = 1 müşteri / başvuru.
-- =====================================================================
SELECT
    COUNT(*)                              AS toplam_satir,
    COUNT(DISTINCT sk_id_curr)            AS benzersiz_basvuru,
    COUNT(*) - COUNT(DISTINCT sk_id_curr) AS fark
FROM raw.application_train;


-- =====================================================================
-- 3. previous_application grain kontrolü
-- Soru: sk_id_prev benzersiz mi?
-- Bulgu: [sonucunu yaz]
--   - Grain: 1 satır = müşterinin Home Credit'e yaptığı 1 önceki başvuru.
-- =====================================================================
SELECT
    COUNT(*)                              AS toplam_satir,
    COUNT(DISTINCT sk_id_prev)            AS benzersiz_onceki_basvuru,
    COUNT(*) - COUNT(DISTINCT sk_id_prev) AS fark
FROM raw.previous_application;


-- =====================================================================
-- 4. Müşteri başına önceki başvuru sayısı
-- Soru: Bir müşterinin ortalama, medyan ve en fazla kaç önceki başvurusu var?
-- Yöntem: CTE ile önce müşteri bazında say, sonra özetle.
-- Bulgu: 338.857 müşteri. Ortalama 4,93, medyan 4, en fazla 77.
--   - 338.857 > 307.511 çünkü tablo train + test müşterilerini kapsıyor.
--   - Dağılım sağa çarpık; az sayıda müşteri çok sık başvuruyor.
--     Sık başvuru bir risk sinyali olabilir ("başvuru sayısı", "red oranı"
--     modelde özellik olacak).
--   - Join kuralı: bu tablo application_train'e doğrudan join edilmez,
--     önce müşteri bazında özetlenir (yoksa satırlar ~5 katına çıkar).
-- =====================================================================
WITH musteri_basvuru AS (
    SELECT sk_id_curr, COUNT(*) AS basvuru_sayisi
    FROM raw.previous_application
    GROUP BY sk_id_curr
)
SELECT
    COUNT(*)                                                    AS musteri_sayisi,
    ROUND(AVG(basvuru_sayisi), 2)                               AS ortalama,
    MAX(basvuru_sayisi)                                         AS en_fazla,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY basvuru_sayisi) AS medyan
FROM musteri_basvuru;


-- =====================================================================
-- 5. Müşteri başına dış kredi sayısı (kredi bürosu)
-- Soru: Bir müşterinin başka kurumlarda ortalama kaç kredisi var?
-- Bulgu: ~305 bin müşteri. Ortalama [yaz], medyan [yaz], en fazla [yaz].
--   - Bu sayı train ile doğrudan karşılaştırılamaz: bureau da
--     train + test müşterilerini kapsıyor (bkz. sorgu 7).
--   - Grain: 1 satır = müşterinin başka kurumdaki 1 kredisi.
-- =====================================================================
WITH musteri_dis_kredi AS (
    SELECT sk_id_curr, COUNT(*) AS kredi_sayisi
    FROM raw.bureau
    GROUP BY sk_id_curr
)
SELECT
    COUNT(*)                                                  AS musteri_sayisi,
    ROUND(AVG(kredi_sayisi), 2)                               AS ortalama,
    MAX(kredi_sayisi)                                         AS en_fazla,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kredi_sayisi) AS medyan
FROM musteri_dis_kredi;


-- =====================================================================
-- 6. Aylık gecikme durumu dağılımı (bureau_balance.status)
-- Soru: Dış kredilerin aylık durumları nasıl dağılıyor?
-- Kodlar: C = kapanmış, X = bilinmiyor, 0 = gecikme yok,
--         1 = 1-30 gün, 2 = 31-60, 3 = 61-90, 4 = 91-120,
--         5 = 120+ gün / satılmış / zarar yazılmış.
-- Bulgu: C %49,99 | X %21,28 | 0 %27,47 | 1 %0,89 | 2 %0,09
--        3 %0,03 | 4 %0,02 | 5 %0,23
--   - 1-5 arası değerler DPD (Days Past Due) kovaları; 4 ve 5 NPL karşılığı.
--   - Payda uyarısı: C ve X aktif değil. Gerçek gecikme oranı için
--     payda sadece 0-5 olmalı (ör. 5 kovası aktif aylar içinde ~%0,8).
--   - 5 kovası yeniden yükseliyor: "son durak", krediler orada birikiyor.
--   - X ayrı kategori olarak ele alınmalı, "gecikme yok" sayılmamalı.
--   - Roll rate (kova geçiş) analizinin temeli bu tablo olacak.
-- =====================================================================
SELECT
    status,
    COUNT(*)                                            AS adet,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS yuzde
FROM raw.bureau_balance
GROUP BY status
ORDER BY status;


-- =====================================================================
-- 7. Büro kaydı kapsaması
-- Soru: Train müşterilerinin kaçının kredi bürosu kaydı var?
-- Yöntem: Büro müşterilerini CTE'de DISTINCT ile tekilleştir (grain),
--         sonra LEFT JOIN. COUNT(sütun) NULL'ları saymaz.
-- Bulgu: 263.491 kayıtlı, 44.020 kayıtsız (%14,31).
--   - İlk bakışta 307k vs 305k karşılaştırması "2 bin kayıtsız" gibi
--     görünüyordu; doğru payda ile gerçek sayı 44 bin. Payda önemli.
--   - Kayıtsız = kredi geçmişi yok ("thin file / no-hit" segmenti).
-- =====================================================================
WITH buro_musterileri AS (
    SELECT DISTINCT sk_id_curr
    FROM raw.bureau
)
SELECT
    COUNT(*)                                                      AS toplam_musteri,
    COUNT(b.sk_id_curr)                                           AS buro_kaydi_olan,
    COUNT(*) - COUNT(b.sk_id_curr)                                AS buro_kaydi_olmayan,
    ROUND(100.0 * (COUNT(*) - COUNT(b.sk_id_curr)) / COUNT(*), 2) AS kayitsiz_yuzde
FROM raw.application_train a
LEFT JOIN buro_musterileri b
    ON a.sk_id_curr = b.sk_id_curr;


-- =====================================================================
-- 8. Büro kaydına göre temerrüt oranı
-- Soru: Kredi geçmişi olmayan müşteriler daha mı riskli?
-- Not: Temerrüt bilgisi (target) büroden değil, Home Credit'in kendi
--      kredisinden gelir. Büro = geçmiş, target = bu kredinin sonucu.
-- Bulgu: Büro kaydı var %7,73 | Büro kaydı yok %10,12 (~1,3 kat).
--   - Bu tablo tek başına "Home Credit doğru kredi verdi mi?" sorusunu
--     cevaplamaz:
--       * Seçim yanlılığı: sadece kabul edilen başvuruları görüyoruz.
--       * Fiyatlama: riskli segment yüksek faiz/düşük tutarla kârlı olabilir.
--       * Karıştırıcı değişken: fark yaş/gelirden kaynaklanıyor olabilir.
--   - Sonraki adım: segmentlerin kredi tutarı, gelir ve yaşını karşılaştır.
-- =====================================================================
WITH buro_musterileri AS (
    SELECT DISTINCT sk_id_curr
    FROM raw.bureau
)
SELECT
    CASE
        WHEN b.sk_id_curr IS NULL THEN 'Büro kaydı yok'
        ELSE 'Büro kaydı var'
    END                                     AS segment,
    COUNT(*)                                AS musteri_sayisi,
    SUM(a.target::int)                      AS temerrut_sayisi,
    ROUND(100.0 * AVG(a.target::int), 2)    AS temerrut_orani
FROM raw.application_train a
LEFT JOIN buro_musterileri b
    ON a.sk_id_curr = b.sk_id_curr
GROUP BY 1
ORDER BY 1;

-- =====================================================================
-- 9. Büro segmentlerinin profil karşılaştırması
-- Soru: Kayıtsız segmentin yüksek temerrüdü (bkz. 8) yaş/gelir
--       farkından mı kaynaklanıyor? Banka bu segmente farklı limit
--       veriyor mu?
-- Bulgu:
--                    Yaş    Gelir     Kredi    Kredi/Gelir
--   Büro kaydı var   44,1   171.402   606.403  3,95
--   Büro kaydı yok   42,9   153.212   554.872  4,03
--   - Fark küçük: kayıtsızlar ~1 yaş genç, geliri ~%11, kredisi ~%8 düşük.
--     Bu fark 1,3 katlık risk farkını tek başına açıklamıyor gibi;
--     büro kaydının yokluğu kendi başına bir risk sinyali olabilir.
--     (Kesin test: data science bölümünde çok değişkenli model.)
--   - Fiyatlama sorusu: riskli segmentin kredi/gelir oranı daha düşük
--     değil, hatta biraz yüksek. Banka limitte risk ayrımı yapmıyor
--     görünüyor. Faiz oranı görünmediği için kesin değil; kredi politikası
--     açısından incelenmeli.
--   - Uyarı: gelir sağa çarpık ve uç değerli. Ortalama yerine medyanla
--     tekrar kontrol edilmeli.
-- =====================================================================
WITH buro_musterileri AS (
    SELECT DISTINCT sk_id_curr
    FROM raw.bureau
)
SELECT
    CASE
        WHEN b.sk_id_curr IS NULL THEN 'Büro kaydı yok'
        ELSE 'Büro kaydı var'
    END                                                 AS segment,
    COUNT(*)                                            AS musteri_sayisi,
    ROUND(AVG(-a.days_birth::int / 365.0), 1)           AS ort_yas,
    ROUND(AVG(a.amt_income_total::numeric), 0)          AS ort_gelir,
    ROUND(AVG(a.amt_credit::numeric), 0)                AS ort_kredi,
    ROUND(AVG(a.amt_credit::numeric
              / a.amt_income_total::numeric), 2)        AS kredi_gelir_orani
FROM raw.application_train a
LEFT JOIN buro_musterileri b
    ON a.sk_id_curr = b.sk_id_curr
GROUP BY 1
ORDER BY 1;

-- =====================================================================
-- 10. Home Credit içi geçmiş tabloların grain kontrolü
-- Soru: pos_cash_balance, credit_card_balance ve installments_payments
--       tablolarında bir satır neyi temsil ediyor?
-- Bulgu:
--   Tablo                   Satır    Kredi    Müşteri  Kredi başına satır
--   pos_cash_balance        10,0 M   936 bin  337 bin  10,7
--   credit_card_balance      3,8 M   104 bin  104 bin  36,8
--   installments_payments   13,6 M   998 bin  340 bin  13,6
--
--   - Grain:
--       * pos_cash_balance      → 1 kredinin 1 ayı (months_balance)
--       * credit_card_balance   → 1 kartın 1 ayı (months_balance)
--       * installments_payments → 1 ödeme hareketi (bir taksit parça
--         parça ödendiyse birden fazla satır olur)
--   - Gecikme analizi installments_payments'tan yapılacak: ödenmesi
--     gereken gün ile ödendiği gün bu tabloda.
--   - Kart penetrasyonu düşük: ~356 bin müşterinin ~%29'unun kartı var,
--     kartı olanın genelde tek kartı var. Cross-sell fırsatı.
--   - Kart ortalama 37 ay, POS kredisi 11 ay izleniyor: kart döner ürün,
--     kredi vadesi dolunca kapanıyor.
--   - previous_application'da 1,67 M başvuru var, bu tablolarda en fazla
--     ~1 M kredi. Fark = reddedilen/iptal edilen başvurular (hiç
--     kullandırılmadı). Onay oranı metriği buradan çıkacak.
--
-- Veri modeli (tüm tablolar):
--   application_train            1 satır = 1 müşteri        (sk_id_curr)
--   ├── bureau                   başka kurumdaki 1 kredi     (sk_id_bureau)
--   │   └── bureau_balance       o kredinin 1 ayı
--   └── previous_application     Home Credit'e 1 önceki başvuru (sk_id_prev)
--       ├── pos_cash_balance       o kredinin 1 ayı
--       ├── credit_card_balance    o kartın 1 ayı
--       └── installments_payments  o kredinin 1 ödemesi
--   Kural: alt tablolar üst tabloya join edilmeden önce özetlenir.
-- =====================================================================

-- 10a. POS ve nakit krediler
SELECT
    COUNT(*)                                                 AS toplam_satir,
    COUNT(DISTINCT sk_id_prev)                               AS benzersiz_kredi,
    COUNT(DISTINCT sk_id_curr)                               AS benzersiz_musteri,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT sk_id_prev), 1) AS kredi_basina_satir
FROM raw.pos_cash_balance;

-- 10b. Kredi kartları
SELECT
    COUNT(*)                                                 AS toplam_satir,
    COUNT(DISTINCT sk_id_prev)                               AS benzersiz_kredi,
    COUNT(DISTINCT sk_id_curr)                               AS benzersiz_musteri,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT sk_id_prev), 1) AS kredi_basina_satir
FROM raw.credit_card_balance;

-- 10c. Taksit ödemeleri
SELECT
    COUNT(*)                                                 AS toplam_satir,
    COUNT(DISTINCT sk_id_prev)                               AS benzersiz_kredi,
    COUNT(DISTINCT sk_id_curr)                               AS benzersiz_musteri,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT sk_id_prev), 1) AS kredi_basina_satir
FROM raw.installments_payments;