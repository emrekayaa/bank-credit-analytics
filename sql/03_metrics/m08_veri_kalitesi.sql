-- =====================================================================
-- metrics.mv_veri_kalitesi  (MATERIALIZED VIEW)
-- Kaynak: raw ve staging tabloları
-- Grain: 1 satır = 1 veri kalitesi kontrolü
-- Amaç: Sayfa 10 (Veri Kalitesi ve Metodoloji). Staging aşamasında
--       bulunan sorunları ve verilen kararları CANLI sayılarla gösterir.
--
-- Teknik: Yetim kayıt ve kapsama kontrolleri LEFT JOIN ile yapılır.
--   İlk sürümde COUNT(*) FILTER (WHERE NOT EXISTS (...)) kullanılmıştı.
--   NOT EXISTS yalnızca WHERE içinde verimli bir anti-join'e çevrilir;
--   FILTER veya SELECT içinde HER SATIR İÇİN ayrı alt sorgu çalışır
--   ve çok yavaşlar. Ders: alt sorgunun NEREDE yazıldığı performansı
--   belirler.
--   Ayrıca work_mem artırıldı: 27 M satırlık DISTINCT bellekte yapılsın,
--   diske taşmasın (yalnızca bu oturum için geçerli).
-- Yenileme: REFRESH MATERIALIZED VIEW metrics.mv_veri_kalitesi;
-- =====================================================================

SET work_mem = '256MB';

DROP MATERIALIZED VIEW IF EXISTS metrics.mv_veri_kalitesi;

CREATE MATERIALIZED VIEW metrics.mv_veri_kalitesi AS
WITH bb_kredi AS (
    -- Aylık geçmişi olan büro kredileri (tekil)
    SELECT sk_id_bureau
    FROM staging.bureau_balance
    GROUP BY sk_id_bureau
),
kontroller AS (
    -- ===== application =====
    SELECT 1 AS sira, 'application' AS tablo,
           'Yer tutucu' AS tur,
           'days_employed = 365243 (çoğu emekli)' AS kontrol,
           SUM(calisma_bilgisi_yok)::bigint AS etkilenen, COUNT(*)::bigint AS toplam,
           'NULL + calisma_bilgisi_yok bayrağı' AS karar
    FROM staging.application
    UNION ALL
    SELECT 2, 'application', 'Bilinmeyen değer',
           'code_gender = XNA',
           COUNT(*) FILTER (WHERE code_gender IS NULL), COUNT(*),
           'NULL'
    FROM staging.application

    -- ===== previous_application =====
    UNION ALL
    SELECT 3, 'previous_application', 'Yer tutucu',
           'days_first_drawing = 365243',
           COUNT(*) FILTER (WHERE days_first_drawing::numeric = 365243), COUNT(*),
           'NULL (olay gerçekleşmedi)'
    FROM raw.previous_application
    UNION ALL
    SELECT 4, 'previous_application', 'Yer tutucu',
           'days_termination = 365243',
           COUNT(*) FILTER (WHERE days_termination::numeric = 365243), COUNT(*),
           'NULL (olay gerçekleşmedi)'
    FROM raw.previous_application
    UNION ALL
    SELECT 5, 'previous_application', 'Eksik veri',
           'Faiz oranı boş',
           COUNT(*) - COUNT(rate_interest_primary), COUNT(*),
           'Fiyatlama analizi yapılamaz'
    FROM staging.previous_application
    UNION ALL
    SELECT 6, 'previous_application', 'Olası tekrar',
           'flag_last_appl_per_contract = N',
           COUNT(*) FILTER (WHERE flag_last_appl_per_contract = 0), COUNT(*),
           'Analizlerde hariç'
    FROM staging.previous_application

    -- ===== installments_payments =====
    UNION ALL
    SELECT 7, 'installments_payments', 'Eksik veri',
           'Ödeme kaydı yok',
           COUNT(*) - COUNT(days_entry_payment), COUNT(*),
           'Korundu (ödenmemiş taksit)'
    FROM staging.installments_payments

    -- ===== bureau =====
    UNION ALL
    SELECT 8, 'bureau', 'Yer tutucu',
           'Planlanan bitiş 40 yıldan uzak (%99,5 kredi kartı)',
           SUM(plan_bitis_yok)::bigint, COUNT(*),
           'NULL + plan_bitis_yok bayrağı'
    FROM staging.bureau
    UNION ALL
    SELECT 9, 'bureau', 'Mantık hatası',
           'Gerçek kapanış açılıştan önce',
           COUNT(*) FILTER (WHERE days_enddate_fact::numeric < days_credit::numeric), COUNT(*),
           'NULL'
    FROM raw.bureau
    UNION ALL
    SELECT 10, 'bureau', 'Aykırı değer',
           'Negatif borç (fazla ödeme)',
           COUNT(*) FILTER (WHERE amt_credit_sum_debt < 0), COUNT(*),
           'Korundu; borç toplamlarında 0'
    FROM staging.bureau
    UNION ALL
    SELECT 11, 'bureau', 'Tutarsız birim',
           'Ana para birimi dışında',
           COUNT(*) FILTER (WHERE ana_para_birimi = 0), COUNT(*),
           'Tutar toplamlarına katılmadı'
    FROM staging.bureau
    UNION ALL
    SELECT 12, 'bureau', 'Kapsama',
           'Aylık geçmişi olmayan büro kredisi',
           COUNT(*) FILTER (WHERE bb.sk_id_bureau IS NULL), COUNT(*),
           'Gecikme oranı "bilinmiyor" (NULL)'
    FROM staging.bureau b
    LEFT JOIN bb_kredi bb ON bb.sk_id_bureau = b.sk_id_bureau

    -- ===== bureau_balance =====
    UNION ALL
    SELECT 13, 'bureau_balance', 'Referans bütünlüğü',
           'Yetim kredi (bureau''da kaydı yok)',
           COUNT(*) FILTER (WHERE b.sk_id_bureau IS NULL), COUNT(*),
           'Join''de düşer; belgelendi'
    FROM bb_kredi k
    LEFT JOIN staging.bureau b ON b.sk_id_bureau = k.sk_id_bureau

    -- ===== pos_cash_balance =====
    UNION ALL
    SELECT 14, 'pos_cash_balance', 'Tanım farkı',
           'Gecikme var ama tolerans altında (küçük tutarlı)',
           COUNT(*) FILTER (WHERE sk_dpd > 0 AND sk_dpd_def = 0), COUNT(*),
           'Risk ölçümünde toleranslı gecikme kullanıldı'
    FROM staging.pos_cash_balance

    -- ===== credit_card_balance =====
    UNION ALL
    SELECT 15, 'credit_card_balance', 'Kapsama',
           'Sıfır limitli (aktif olmayan) kart ayı',
           COUNT(*) FILTER (WHERE aktif_kart_ayi = 0), COUNT(*),
           'Kullanım oranı paydasından çıkarıldı'
    FROM staging.credit_card_balance
    UNION ALL
    SELECT 16, 'credit_card_balance', 'Risk sinyali',
           'Limit aşımı (bakiye > limit)',
           SUM(limit_asimi)::bigint, COUNT(*),
           'Korundu + limit_asimi bayrağı'
    FROM staging.credit_card_balance
)
SELECT
    sira,
    tablo,
    tur,
    kontrol,
    etkilenen,
    toplam,
    ROUND(100.0 * etkilenen / NULLIF(toplam, 0), 2)               AS etkilenen_yuzde,
    karar
FROM kontroller;


-- =====================================================================
-- Kontrol (staging profilindeki sayılarla karşılaştır)
-- Beklenen örnekler: 1 → 55.374 | 3 → 934.444 | 8 → 38.485
--                    12 → 942.074 | 13 → 43.041
-- =====================================================================
-- SELECT * FROM metrics.mv_veri_kalitesi ORDER BY sira;