-- =====================================================================
-- HOME CREDIT - CORE KATMANI KAYDI
-- Amaç: Core katmanında ne yapıldığını, neden yapıldığını, hangi
--       tekniklerin kullanıldığını ve doğrulama sonuçlarını tek yerde
--       toplamak. İlgili dosyalar: sql/02_core/*.sql
--
-- İçindekiler
--   A. Amaç, kurallar ve teknikler
--   B. core.ozet_onceki_basvuru
--   C. core.ozet_taksit
--   D. core.ozet_pos
--   E. core.ozet_kart
--   F. core.ozet_buro
--   G. core.musteri (müşteri 360)
--   H. Toplu doğrulama sorguları
--
-- Çalıştırma sırası (terminalde, proje klasöründe):
--   psql homecredit -f sql/02_core/core_ozet_onceki_basvuru.sql
--   psql homecredit -f sql/02_core/core_ozet_taksit.sql
--   psql homecredit -f sql/02_core/core_ozet_pos.sql
--   psql homecredit -f sql/02_core/core_ozet_kart.sql
--   psql homecredit -f sql/02_core/core_ozet_buro.sql
--   psql homecredit -f sql/02_core/core_musteri.sql      ← en son
-- =====================================================================


-- =====================================================================
-- A. AMAÇ, KURALLAR VE TEKNİKLER
-- ---------------------------------------------------------------------
-- Problem:
--   Staging'de her tablo kendi grain'inde (müşteri, kredi, ay, ödeme).
--   Ama analizlerin ve modelin sorusu müşteri bazında:
--   "Bu müşteri riskli mi?"
--
-- Çözüm:
--   Alt tabloları müşteri seviyesine ÖZETLE, sonra tek tabloda BİRLEŞTİR.
--
--     previous_application  → ozet_onceki_basvuru ┐
--     installments_payments → ozet_taksit         │
--     pos_cash_balance      → ozet_pos            ├→ core.musteri
--     credit_card_balance   → ozet_kart           │   (1 satır = 1 müşteri)
--     bureau + bureau_bal.  → ozet_buro           ┘
--
-- Kurallar:
--   1) Önce özetle, sonra birleştir (doğrudan join satırları çoğaltır).
--   2) Müşteri tablosundan join'ler LEFT JOIN (geçmişi olmayan düşmesin).
--   3) Geçmişi olmayan müşterinin oranı 0 değil NULL
--      ("gecikmesi yok" ≠ "bilmiyoruz").
--   4) Her metriğin grain'i bilinmeli (taksit mi, ay mı, müşteri mi?).
--   5) Sütunlar kaynak önekiyle adlandırılır: buro_, pos_, kart_ ...
--   6) Her özet tablonun müşteri sayısı keşifteki sayıyla karşılaştırılır.
--
-- Teknikler:
--   - İki seviyeli özet: CTE ile önce ara seviye, sonra müşteri.
--   - Üç zaman bakışı: tüm geçmiş | son 12 ay | başvuru anı (son ay).
--       FILTER (WHERE months_balance >= -12)   → son 12 ay
--       FILTER (WHERE months_balance = -1)     → başvurudan önceki son ay
--   - AVG(...) FILTER (WHERE ...): FILTER her toplama fonksiyonuyla çalışır.
--   - Ağırlıklı oran: SUM(pay) / SUM(payda) (kredi oranlarının ortalaması
--     yerine; kısa ve uzun krediler eşit ağırlık almasın diye).
--   - LEFT JOIN ... USING (sk_id_curr): SELECT * ile anahtar tek kez gelir.
--   - Kapsama bayrakları: buro_kaydi_var, kart_var ...
--
-- Veri sızıntısı (leakage) yok:
--   Alt tablolardaki tüm bilgiler başvuru anından ÖNCEYE ait
--   (months_balance ve days_* ≤ 0). Model, bankanın karar anında
--   bilebileceği bilgilerle kurulacak.
-- =====================================================================


-- =====================================================================
-- B. core.ozet_onceki_basvuru
-- ---------------------------------------------------------------------
-- Kaynak: staging.previous_application | Seviye: tek (başvuru → müşteri)
-- Filtre: flag_last_appl_per_contract = 1 (olası tekrar kayıtlar hariç)
-- Sütunlar:
--   onceki_basvuru_sayisi, onaylanan_sayisi, reddedilen_sayisi,
--   iptal_sayisi, red_orani, son_basvuru_gun,
--   ort_onaylanan_istenen_orani, toplam_onaylanan_tutar
-- Kararlar:
--   - red_orani paydası = onaylanan + reddedilen (bankanın kararları).
--     İptal ve kullanılmayan teklif bankanın kararı değil.
--   - son_basvuru_gun = MAX(days_decision): günler negatif, en büyük
--     değer en yakın tarih.
-- Doğrulama: müşteri sayısı = [yaz] (keşifte 338.857; tekrar kayıtlar
--            çıkarıldığı için birkaç eksik olabilir)
-- =====================================================================
SELECT
    COUNT(*)                                                  AS musteri,
    ROUND(AVG(onceki_basvuru_sayisi), 2)                      AS ort_basvuru,
    (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY red_orani))  AS medyan_red_orani,
    ROUND(100.0 * AVG(CASE WHEN reddedilen_sayisi > 0
                           THEN 1 ELSE 0 END), 2)             AS en_az_bir_red_yuzde
FROM core.ozet_onceki_basvuru;


-- =====================================================================
-- C. core.ozet_taksit
-- ---------------------------------------------------------------------
-- Kaynak: staging.installments_payments
-- Seviye: iki (ödeme hareketi → taksit → müşteri)
--   Neden? Bir taksit parça parça ödenebilir. Doğrudan müşteri bazında
--   özetlenirse parçalı taksit birden çok sayılır.
-- Taksit seviyesinde:
--   MIN(days_instalment)    → vade (parçaların vadesi aynı)
--   SUM(amt_payment)        → ödenen toplam
--   MAX(days_entry_payment) → taksit SON parça ödendiğinde tamamlanır
-- Sütunlar:
--   taksit_sayisi, kredi_sayisi, gec_taksit_sayisi, gec_taksit_orani,
--   gec_30_arti_sayisi, max_gecikme_gun, ort_gecikme_gun_gec_olanlarda,
--   eksik_odeme_orani, *_12ay versiyonları, medyan_gecikme_gun
-- Doğrulama: 339.587 müşteri ✓ (keşifle aynı) | 12.951.918 taksit
-- Bulgular:
--   - Geç ödenen TAKSİT oranı:                  %8,52
--   - En az bir kez geç ödeyen MÜŞTERİ:         %52,96
--     → Aynı soru, iki farklı cevap. Müşteri başına ~38 taksit var;
--       "en az bir kez" metriği uzun geçmişi cezalandırır.
--       Müşteri karşılaştırmasında ORAN (gec_taksit_orani) daha adil.
--   - En az bir kez 30+ gün geç ödeyen müşteri: %6,31
--     → Küçük gecikmeler normal davranış; ciddi gecikme ayrı bir grup.
-- =====================================================================
SELECT
    COUNT(*)                                                      AS musteri,
    SUM(taksit_sayisi)                                            AS toplam_taksit,
    ROUND(100.0 * SUM(gec_taksit_sayisi) / SUM(taksit_sayisi), 2) AS gec_taksit_yuzde,
    ROUND(100.0 * AVG(CASE WHEN gec_taksit_sayisi > 0  THEN 1 ELSE 0 END), 2)
                                                                  AS en_az_bir_gec_musteri_yuzde,
    ROUND(100.0 * AVG(CASE WHEN gec_30_arti_sayisi > 0 THEN 1 ELSE 0 END), 2)
                                                                  AS en_az_bir_30_arti_musteri_yuzde
FROM core.ozet_taksit;


-- =====================================================================
-- D. core.ozet_pos
-- ---------------------------------------------------------------------
-- Kaynak: staging.pos_cash_balance | Seviye: tek (kredi-ay → müşteri)
-- Gecikme: toleranslı gecikme (sk_dpd_def) üzerinden.
-- Sütunlar:
--   pos_kredi_sayisi, pos_ay_sayisi, pos_gecikmeli_ay_orani,
--   pos_90_arti_ay_sayisi, pos_max_gecikme_gun, pos_olumsuz_durum_var,
--   *_12ay versiyonları,
--   pos_aktif_kredi_sayisi, pos_kalan_taksit_sayisi (başvuru anı)
-- Doğrulama: müşteri sayısı = [yaz] (beklenen 337.252)
-- =====================================================================
SELECT
    COUNT(*)                                                                   AS musteri,
    ROUND(AVG(pos_kredi_sayisi), 2)                                            AS ort_kredi,
    ROUND(100.0 * AVG(CASE WHEN pos_max_gecikme_gun > 0   THEN 1 ELSE 0 END), 2) AS en_az_bir_gecikme_yuzde,
    ROUND(100.0 * AVG(CASE WHEN pos_90_arti_ay_sayisi > 0 THEN 1 ELSE 0 END), 2) AS en_az_bir_90_arti_yuzde,
    ROUND(100.0 * AVG(pos_olumsuz_durum_var), 2)                               AS olumsuz_durum_yuzde,
    ROUND(100.0 * AVG(CASE WHEN pos_aktif_kredi_sayisi > 0 THEN 1 ELSE 0 END), 2) AS aktif_pos_kredili_yuzde
FROM core.ozet_pos;


-- =====================================================================
-- E. core.ozet_kart
-- ---------------------------------------------------------------------
-- Kaynak: staging.credit_card_balance | Seviye: tek (kart-ay → müşteri)
-- Kullanım, limit aşımı ve gecikme oranları yalnızca AKTİF kart
-- aylarında (limit > 0). Staging'deki NULL'lu sütunlar sayesinde AVG()
-- doğru paydayı kendisi seçer.
-- Sütunlar:
--   kart_sayisi, kart_aktif_ay_sayisi, kart_ort_kullanim,
--   kart_max_kullanim, kart_limit_asimi_ay_orani,
--   kart_asgari_alti_odeme_orani, kart_ort_nakit_avans_payi,
--   *_12ay versiyonları, kart_gecikmeli_ay_orani, kart_max_gecikme_gun,
--   kart_90_arti_ay_sayisi, kart_olumsuz_durum_var,
--   kart_son_ay_bakiye, kart_son_ay_limit, kart_son_ay_kullanim
-- Doğrulama: 103.558 müşteri ✓ (keşifle aynı)
-- Bulgular:
--   - Müşteri başına 1,01 kart (neredeyse herkesin tek kartı var).
--   - Medyan kullanım: tüm geçmiş %24,1 → başvurudan önceki ay %26,1.
--     Kullanım başvuruya yaklaştıkça artıyor (nakit ihtiyacı hipotezi).
--   - Limite dayalı (>%90) müşteri: %14,48. Bu bir ALT SINIR: son ayda
--     aktif kartı olmayanlar da paydada. Gerçek oran aktif kartlılar
--     içinde daha yüksek.
--   - Olumsuz durum (Demand): %0,02.
-- =====================================================================
SELECT
    COUNT(*)                                                           AS musteri,
    ROUND(AVG(kart_sayisi), 2)                                         AS ort_kart,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kart_ort_kullanim)     AS medyan_ort_kullanim,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kart_son_ay_kullanim)  AS medyan_son_ay_kullanim,
    ROUND(100.0 * AVG(CASE WHEN kart_son_ay_kullanim > 0.9 THEN 1 ELSE 0 END), 2)
                                                                       AS limite_dayali_yuzde,
    ROUND(100.0 * AVG(kart_olumsuz_durum_var), 2)                      AS olumsuz_durum_yuzde
FROM core.ozet_kart;


-- =====================================================================
-- F. core.ozet_buro
-- ---------------------------------------------------------------------
-- Kaynak: staging.bureau + staging.bureau_balance
-- Seviye: iki (kredi-ay → büro kredisi → müşteri)
--   1) bureau_balance büro kredisi seviyesine özetlenir
--   2) bureau'ya LEFT JOIN, sonra müşteri seviyesine özetlenir
-- Kararlar:
--   - Aylık geçmişi olmayan kredilerde gecikme oranı NULL ("bilinmiyor").
--   - 43.041 yetim kredi, join bureau tarafından yapıldığı için düşer.
--   - Tutarlarda yalnızca ana para birimi; borçta negatifler 0 (borc_pozitif).
--   - Aylık gecikme oranı ağırlıklı: toplam gecikmeli ay / toplam aktif ay.
-- Sütunlar:
--   Hacim:   buro_kredi_sayisi, buro_aktif_kredi_sayisi,
--            buro_kredi_turu_sayisi, buro_kredi_gecmisi_yil,
--            buro_son_kredi_gun, buro_son_1yil_acilan_kredi (kredi açlığı),
--            buro_mikrokredi_var
--   Olumsuz: buro_olumsuz_kapanis_var (Sold / Bad debt), buro_uzatma_sayisi
--   Anlık:   buro_su_an_gecikmede_kredi, buro_max_gecikme_gun
--   Borç:    buro_aktif_borc, buro_aktif_kredi_tutari,
--            buro_borc_tutar_orani, buro_gecikmis_tutar
--   Aylık:   buro_aylik_gecmisli_kredi, buro_gecikmeli_ay_orani,
--            buro_90_arti_ay_sayisi, buro_gecikmeli_ay_orani_12ay
-- Doğrulama: 305.811 müşteri ✓ (keşifle aynı)
-- =====================================================================
SELECT
    COUNT(*)                                                     AS musteri,
    ROUND(AVG(buro_kredi_sayisi), 2)                             AS ort_kredi,
    ROUND(100.0 * AVG(CASE WHEN buro_aylik_gecmisli_kredi > 0
                           THEN 1 ELSE 0 END), 2)                AS aylik_gecmisi_olan_yuzde,
    ROUND(100.0 * AVG(buro_olumsuz_kapanis_var), 2)              AS olumsuz_kapanis_yuzde,
    ROUND(100.0 * AVG(CASE WHEN buro_su_an_gecikmede_kredi > 0
                           THEN 1 ELSE 0 END), 2)                AS su_an_gecikmede_yuzde,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY buro_kredi_gecmisi_yil) AS medyan_gecmis_yil,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY buro_borc_tutar_orani)  AS medyan_borc_tutar_orani
FROM core.ozet_buro;


-- =====================================================================
-- G. core.musteri (müşteri 360)
-- ---------------------------------------------------------------------
-- Kaynak: staging.application + 5 özet tablo
-- Grain: 1 satır = 1 müşteri (yalnızca train; target var)
-- Yapı:
--   staging.application
--     LEFT JOIN ozet_onceki_basvuru USING (sk_id_curr)
--     LEFT JOIN ozet_taksit         USING (sk_id_curr)
--     LEFT JOIN ozet_pos            USING (sk_id_curr)
--     LEFT JOIN ozet_kart           USING (sk_id_curr)
--     LEFT JOIN ozet_buro           USING (sk_id_curr)
-- Eklenen sütunlar:
--   Kapsama: buro_kaydi_var, onceki_basvuru_var, taksit_gecmisi_var,
--            pos_gecmisi_var, kart_var
--   Borç:    buro_borc_gelir_orani   = dış aktif borç / yıllık gelir
--            toplam_borc_gelir_orani = (dış aktif borç + yeni kredi) / gelir
--            (büro kaydı yoksa dış borç COALESCE ile 0)
-- En önemli kontrol: satır sayısı = 307.511 (join satır çoğaltmamalı).
--   Özet tablolarda primary key olduğu için çoğaltma olursa
--   ALTER TABLE ... PRIMARY KEY satırı hata verir.
-- Doğrulama: satır sayısı = [yaz]
-- application_test bu tabloda yok; model skorlama aşamasında aynı yapı
-- test için ayrıca kurulacak.
-- =====================================================================

-- G1. Satır sayısı ve kapsama
-- Beklenen: 307.511 | buro_kaydi_var 263.491
SELECT
    COUNT(*)                 AS musteri,
    SUM(buro_kaydi_var)      AS buro_kaydi_var,
    SUM(onceki_basvuru_var)  AS onceki_basvuru_var,
    SUM(taksit_gecmisi_var)  AS taksit_gecmisi_var,
    SUM(pos_gecmisi_var)     AS pos_gecmisi_var,
    SUM(kart_var)            AS kart_var
FROM core.musteri;

-- G2. Geçmiş kaynaklarına göre temerrüt
-- Bulgu: [yaz] (beklenen: büro kaydı var %7,73 / yok %10,12)
SELECT 'Büro kaydı'     AS kaynak, buro_kaydi_var     AS var_mi, COUNT(*) AS musteri,
       ROUND(100.0 * AVG(target), 2) AS temerrut_orani FROM core.musteri GROUP BY 2
UNION ALL
SELECT 'Önceki başvuru', onceki_basvuru_var, COUNT(*),
       ROUND(100.0 * AVG(target), 2) FROM core.musteri GROUP BY 2
UNION ALL
SELECT 'Kredi kartı',    kart_var, COUNT(*),
       ROUND(100.0 * AVG(target), 2) FROM core.musteri GROUP BY 2
ORDER BY 1, 2;


-- =====================================================================
-- H. TOPLU DOĞRULAMA: tüm core tablolarının satır sayısı
-- Beklenen: ozet_onceki_basvuru ~338 bin | ozet_taksit 339.587
--           ozet_pos 337.252 | ozet_kart 103.558 | ozet_buro 305.811
--           musteri 307.511
-- =====================================================================
SELECT 'ozet_onceki_basvuru' AS tablo, COUNT(*) AS satir FROM core.ozet_onceki_basvuru
UNION ALL
SELECT 'ozet_taksit',                  COUNT(*)          FROM core.ozet_taksit
UNION ALL
SELECT 'ozet_pos',                     COUNT(*)          FROM core.ozet_pos
UNION ALL
SELECT 'ozet_kart',                    COUNT(*)          FROM core.ozet_kart
UNION ALL
SELECT 'ozet_buro',                    COUNT(*)          FROM core.ozet_buro
UNION ALL
SELECT 'musteri',                      COUNT(*)          FROM core.musteri;
