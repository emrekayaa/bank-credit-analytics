-- =====================================================================
-- staging.credit_card_balance
-- Kaynak: raw.credit_card_balance
-- Grain: 1 satır = 1 kredi kartının 1 ayı (sk_id_prev + months_balance)
--
-- Profil bulguları (3.840.312 satır):
--   - (sk_id_prev, months_balance) benzersiz → bileşik primary key.
--   - Sıfır limit: 753.823 (%19,6). Bunların yalnızca 7.992'sinde bakiye,
--     4.650'sinde harcama var → büyük ölçüde AKTİF OLMAYAN kart ayları.
--     → aktif_kart_ayi = limit > 0; kullanım oranı sıfır limitte NULL.
--   - Boş ödeme 767.988 / boş ATM 749.816: sıfır limitle AYNI satırlar
--     DEĞİL (~579 bin boş ödeme limiti olan kartlarda).
--     → Hipotez test edilip çürütüldü. NULL = "o ay ilgili hareket kaydı yok";
--       0'a çevrilmiyor, oranlar NULL'ları atlıyor.
--   - Limit aşımı (bakiye > limit > 0): 334.362 (%8,7) → limit_asimi bayrağı.
--   - Negatif bakiye 2.345 (fazla ödeme), negatif harcama 4 (iade) → korunuyor.
--   - En uzun toleranslı gecikme: 3.260 gün → DPD kovasında 90+.
--   - Durumlar: Active 3.698.436 | Completed 128.918 | Signed 11.058
--     Demand 1.365 | Sent proposal 513 | Refused 17 | Approved 5
--     → Demand (muacceliyet) = olumsuz_durum
--   - Not: amt_recivable sütun adındaki yazım hatası kaynaktan geliyor.
-- =====================================================================

DROP TABLE IF EXISTS staging.credit_card_balance;

CREATE TABLE staging.credit_card_balance AS
SELECT
    -- ===== Kimlikler =====
    sk_id_prev::numeric::int                                  AS sk_id_prev,
    sk_id_curr::numeric::int                                  AS sk_id_curr,
    months_balance::numeric::int                              AS months_balance,

    -- ===== Bakiye ve limit =====
    amt_balance::numeric                                      AS amt_balance,
    amt_credit_limit_actual::numeric                          AS amt_credit_limit_actual,

    -- ===== Harcamalar (tutar) =====
    amt_drawings_atm_current::numeric                         AS amt_drawings_atm_current,
    amt_drawings_current::numeric                             AS amt_drawings_current,
    amt_drawings_other_current::numeric                       AS amt_drawings_other_current,
    amt_drawings_pos_current::numeric                         AS amt_drawings_pos_current,

    -- ===== Ödemeler =====
    amt_inst_min_regularity::numeric                          AS amt_inst_min_regularity,
    amt_payment_current::numeric                              AS amt_payment_current,
    amt_payment_total_current::numeric                        AS amt_payment_total_current,

    -- ===== Alacak =====
    amt_receivable_principal::numeric                         AS amt_receivable_principal,
    amt_recivable::numeric                                    AS amt_recivable,
    amt_total_receivable::numeric                             AS amt_total_receivable,

    -- ===== Harcamalar (adet) =====
    cnt_drawings_atm_current::numeric::int                    AS cnt_drawings_atm_current,
    cnt_drawings_current::numeric::int                        AS cnt_drawings_current,
    cnt_drawings_other_current::numeric::int                  AS cnt_drawings_other_current,
    cnt_drawings_pos_current::numeric::int                    AS cnt_drawings_pos_current,
    cnt_instalment_mature_cum::numeric::int                   AS cnt_instalment_mature_cum,

    -- ===== Durum ve gecikme =====
    name_contract_status,
    sk_dpd::numeric::int                                      AS sk_dpd,
    sk_dpd_def::numeric::int                                  AS sk_dpd_def,

    -- ===== Türetilmiş sütunlar: kart kullanımı =====
    CASE WHEN amt_credit_limit_actual::numeric > 0
         THEN 1 ELSE 0 END                                    AS aktif_kart_ayi,
    -- Limit kullanım oranı: sadece aktif kart aylarında
    ROUND(amt_balance::numeric
          / NULLIF(amt_credit_limit_actual::numeric, 0), 3)   AS limit_kullanim_orani,
    CASE WHEN amt_credit_limit_actual::numeric > 0
          AND amt_balance::numeric > amt_credit_limit_actual::numeric
         THEN 1 ELSE 0 END                                    AS limit_asimi,
    -- Asgari ödeme karşılama: 1 = tam asgari, <1 = asgarinin altı
    ROUND(amt_payment_total_current::numeric
          / NULLIF(amt_inst_min_regularity::numeric, 0), 3)   AS asgari_odeme_karsilama,
    CASE
        WHEN amt_inst_min_regularity::numeric > 0
         AND amt_payment_total_current IS NOT NULL
         AND amt_payment_total_current::numeric
             < amt_inst_min_regularity::numeric               THEN 1
        WHEN amt_inst_min_regularity::numeric > 0
         AND amt_payment_total_current IS NOT NULL             THEN 0
        ELSE NULL
    END                                                       AS asgari_alti_odeme,
    -- Nakit avans payı: ATM çekimi / toplam harcama
    ROUND(amt_drawings_atm_current::numeric
          / NULLIF(amt_drawings_current::numeric, 0), 3)      AS nakit_avans_payi,

    -- ===== Türetilmiş sütunlar: gecikme (POS ve büro ile aynı yapı) =====
    CASE WHEN sk_dpd_def::numeric > 0
         THEN 1 ELSE 0 END                                    AS gecikmede,
    CASE WHEN sk_dpd_def::numeric > 90
         THEN 1 ELSE 0 END                                    AS gecikme_90_arti,
    CASE
        WHEN sk_dpd_def::numeric = 0    THEN '0 - Gecikmesiz'
        WHEN sk_dpd_def::numeric <= 30  THEN '1 - 1-30 gün'
        WHEN sk_dpd_def::numeric <= 60  THEN '2 - 31-60 gün'
        WHEN sk_dpd_def::numeric <= 90  THEN '3 - 61-90 gün'
        WHEN sk_dpd_def::numeric <= 120 THEN '4 - 91-120 gün'
        ELSE '5 - 120+ gün'
    END                                                       AS dpd_kova,
    CASE WHEN name_contract_status = 'Demand'
         THEN 1 ELSE 0 END                                    AS olumsuz_durum
FROM raw.credit_card_balance;

ALTER TABLE staging.credit_card_balance ADD PRIMARY KEY (sk_id_prev, months_balance);
CREATE INDEX idx_stg_cc_curr ON staging.credit_card_balance (sk_id_curr);


-- =====================================================================
-- Doğrulama (tablo kurulduktan sonra DBeaver'da çalıştır)
-- Beklenen: 3.840.312 satır | aktif_kart_ayi 3.086.489
--           limit_asimi 334.362 | olumsuz_durum 1.365
-- =====================================================================
-- SELECT
--     COUNT(*)                                                       AS toplam,
--     SUM(aktif_kart_ayi)                                            AS aktif_kart_ayi,
--     SUM(limit_asimi)                                               AS limit_asimi,
--     SUM(olumsuz_durum)                                             AS olumsuz_durum,
--     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY limit_kullanim_orani) AS medyan_kullanim,
--     ROUND(100.0 * AVG(asgari_alti_odeme), 2)                       AS asgari_alti_yuzde,
--     ROUND(100.0 * AVG(gecikmede), 2)                               AS gecikme_yuzde
-- FROM staging.credit_card_balance;
