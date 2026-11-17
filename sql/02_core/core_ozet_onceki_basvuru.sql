-- =====================================================================
-- core.ozet_onceki_basvuru
-- Kaynak: staging.previous_application
-- Grain: 1 satır = 1 müşteri (sk_id_curr)
-- Not: flag_last_appl_per_contract = 0 olan olası tekrar kayıtlar hariç.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.ozet_onceki_basvuru;

CREATE TABLE core.ozet_onceki_basvuru AS
SELECT
    sk_id_curr,
    COUNT(*)                                                    AS onceki_basvuru_sayisi,
    SUM(onaylandi)                                              AS onaylanan_sayisi,
    COUNT(*) FILTER (WHERE name_contract_status = 'Refused')    AS reddedilen_sayisi,
    COUNT(*) FILTER (WHERE name_contract_status = 'Canceled')   AS iptal_sayisi,
    ROUND(
        COUNT(*) FILTER (WHERE name_contract_status = 'Refused')::numeric
        / NULLIF(COUNT(*) FILTER (WHERE name_contract_status IN ('Approved', 'Refused')), 0)
    , 3)                                                        AS red_orani,
    MAX(days_decision)                                          AS son_basvuru_gun,
    ROUND(AVG(onaylanan_istenen_orani) FILTER (WHERE onaylandi = 1), 3)
                                                                AS ort_onaylanan_istenen_orani,
    SUM(amt_credit) FILTER (WHERE onaylandi = 1)                AS toplam_onaylanan_tutar
FROM staging.previous_application
WHERE flag_last_appl_per_contract = 1
GROUP BY sk_id_curr;

ALTER TABLE core.ozet_onceki_basvuru ADD PRIMARY KEY (sk_id_curr);