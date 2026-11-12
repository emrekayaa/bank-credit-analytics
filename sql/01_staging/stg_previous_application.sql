-- =====================================================================
-- staging.previous_application
-- Kaynak: raw.previous_application
-- Grain: 1 satır = müşterinin Home Credit'e yaptığı 1 önceki başvuru (sk_id_prev)
-- Dönüşümler:
--   - days_* (days_decision hariç): 365243 yer tutucusu → NULL
--     ("olay gerçekleşmedi / henüz gerçekleşmedi")
--   - flag_last_appl_per_contract: Y/N → 1/0 (N = 8.475 olası tekrar kayıt)
--   - code_reject_reason: XAP (red yok) → NULL, XNA → 'Bilinmiyor'
--   - rate_interest_*: sadece %0,36 dolu; fiyatlama analizinde kullanılamaz
-- =====================================================================

DROP TABLE IF EXISTS staging.previous_application;

CREATE TABLE staging.previous_application AS
SELECT
    -- ===== Kimlikler =====
    sk_id_prev::numeric::int                                   AS sk_id_prev,
    sk_id_curr::numeric::int                                   AS sk_id_curr,

    -- ===== Ürün ve başvuru =====
    name_contract_type,
    amt_annuity::numeric                                       AS amt_annuity,
    amt_application::numeric                                   AS amt_application,
    amt_credit::numeric                                        AS amt_credit,
    amt_down_payment::numeric                                  AS amt_down_payment,
    amt_goods_price::numeric                                   AS amt_goods_price,
    weekday_appr_process_start,
    hour_appr_process_start::numeric::int                      AS hour_appr_process_start,
    CASE WHEN flag_last_appl_per_contract = 'Y'
         THEN 1 ELSE 0 END                                     AS flag_last_appl_per_contract,
    nflag_last_appl_in_day::numeric::int                       AS nflag_last_appl_in_day,
    rate_down_payment::numeric                                 AS rate_down_payment,
    rate_interest_primary::numeric                             AS rate_interest_primary,
    rate_interest_privileged::numeric                          AS rate_interest_privileged,
    name_cash_loan_purpose,

    -- ===== Karar =====
    name_contract_status,
    days_decision::numeric::int                                AS days_decision,
    name_payment_type,
    CASE code_reject_reason
         WHEN 'XAP' THEN NULL
         WHEN 'XNA' THEN 'Bilinmiyor'
         ELSE code_reject_reason END                           AS code_reject_reason,

    -- ===== Müşteri ve kanal =====
    name_type_suite,
    name_client_type,
    name_goods_category,
    name_portfolio,
    name_product_type,
    channel_type,
    sellerplace_area::numeric::int                             AS sellerplace_area,
    name_seller_industry,
    cnt_payment::numeric::int                                  AS cnt_payment,
    name_yield_group,
    product_combination,

    -- ===== Kredi yaşam döngüsü tarihleri (365243 → NULL) =====
    NULLIF(days_first_drawing::numeric::int, 365243)           AS days_first_drawing,
    NULLIF(days_first_due::numeric::int, 365243)               AS days_first_due,
    NULLIF(days_last_due_1st_version::numeric::int, 365243)    AS days_last_due_1st_version,
    NULLIF(days_last_due::numeric::int, 365243)                AS days_last_due,
    NULLIF(days_termination::numeric::int, 365243)             AS days_termination,
    nflag_insured_on_approval::numeric::int                    AS nflag_insured_on_approval,

    -- ===== Türetilmiş sütunlar =====
    CASE WHEN name_contract_status = 'Approved'
         THEN 1 ELSE 0 END                                     AS onaylandi,
    ROUND(amt_credit::numeric
          / NULLIF(amt_application::numeric, 0), 3)            AS onaylanan_istenen_orani
FROM raw.previous_application;

ALTER TABLE staging.previous_application ADD PRIMARY KEY (sk_id_prev);


-- =====================================================================
-- Doğrulama (tablo kurulduktan sonra DBeaver'da çalıştır)
-- Beklenen: 1.670.214 satır, 1.036.781 onaylı,
--           code_reject_reason NULL sayısı = 1.353.093 (XAP)
-- =====================================================================
-- SELECT
--     COUNT(*)                                   AS toplam,
--     SUM(onaylandi)                             AS onayli,
--     COUNT(*) - COUNT(code_reject_reason)       AS red_nedeni_null,
--     COUNT(days_termination)                    AS kapanis_tarihi_dolu,
--     PERCENTILE_CONT(0.5) WITHIN GROUP
--         (ORDER BY onaylanan_istenen_orani)     AS medyan_onaylanan_istenen
-- FROM staging.previous_application;