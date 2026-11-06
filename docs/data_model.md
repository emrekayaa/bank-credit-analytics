# Veri Modeli

## 1. Genel Bakış

Bu projede Kaggle'daki **Home Credit Default Risk** veri seti kullanılıyor. Home Credit, kredi geçmişi olmayan ya da sınırlı olan kişilere kredi veren uluslararası bir tüketici finansmanı kurumu. Veri, bu kurumun gerçek ve anonimleştirilmiş kredi başvurularını, müşterilerin başka kurumlardaki kredi geçmişini (kredi bürosu) ve Home Credit'teki önceki kredilerinin aylık hareketlerini içeriyor.

Veri seti 8 veri tablosu ve 1 sütun açıklama tablosundan oluşuyor; toplamda yaklaşık **58 milyon satır**. Tüm tablolar PostgreSQL'de `raw` şemasına, kaynak CSV'nin birebir kopyası olarak (tüm sütunlar `TEXT`) yüklendi. Yükleme sonrası satır sayıları kaynak dosyalarla karşılaştırıldı ve kayıp olmadığı doğrulandı.

Bu veri seti, halka açık kaynaklar arasında bankacılık kredi riskini en gerçekçi ve en kapsamlı şekilde yansıtan, ilişkisel yapıda ve büyük hacimli bir veri olduğu için seçildi.

## 2. Tablo Hiyerarşisi

```
application_train / test        1 satır = 1 müşteri / başvuru        (sk_id_curr)
│
├── bureau                      başka kurumdaki 1 kredi               (sk_id_bureau)
│   └── bureau_balance          o kredinin 1 ayı
│
└── previous_application        Home Credit'e 1 önceki başvuru        (sk_id_prev)
    ├── pos_cash_balance        o kredinin 1 ayı
    ├── credit_card_balance     o kartın 1 ayı
    └── installments_payments   o kredinin 1 ödeme hareketi
```

Model iki koldan oluşuyor:

- **Sol kol (büro):** müşterinin **başka kurumlardaki** kredi geçmişi
- **Sağ kol (Home Credit):** müşterinin **Home Credit'teki** önceki başvuruları ve kredilerinin hareketleri

## 3. Tablo Kataloğu

| Tablo | Grain (1 satır =) | Anahtar | Üst tabloya bağlantı | Satır |
|---|---|---|---|---|
| `application_train` | 1 başvuru / müşteri (hedef değişkenli) | `sk_id_curr` | — | 307.511 |
| `application_test` | 1 başvuru / müşteri (hedefsiz) | `sk_id_curr` | — | 48.744 |
| `bureau` | Başka kurumdaki 1 kredi | `sk_id_bureau` | `sk_id_curr` | 1.716.428 |
| `bureau_balance` | Büro kredisinin 1 ayı | `sk_id_bureau` + `months_balance` | `sk_id_bureau` | 27.299.925 |
| `previous_application` | Home Credit'e 1 önceki başvuru | `sk_id_prev` | `sk_id_curr` | 1.670.214 |
| `pos_cash_balance` | POS / nakit kredinin 1 ayı | `sk_id_prev` + `months_balance` | `sk_id_prev` | 10.001.358 |
| `credit_card_balance` | Kredi kartının 1 ayı | `sk_id_prev` + `months_balance` | `sk_id_prev` | 3.840.312 |
| `installments_payments` | 1 ödeme hareketi | — | `sk_id_prev` | 13.605.401 |
| `homecredit_columns_description` | 1 sütunun açıklaması | — | — | 219 |

### Tablo içerikleri

- **application_train / test:** Başvuru anındaki müşteri bilgileri: demografi (yaş, cinsiyet, aile), gelir, kredi tutarı, taksit, mal fiyatı, iş bilgisi, konut bilgisi, dış skorlar. `train` tablosunda `target` sütunu var.
- **bureau:** Müşterinin başka kurumlardaki kredileri: kredi türü, durumu (aktif/kapalı), tutarı, borcu, gecikme bilgisi.
- **bureau_balance:** Büro kredilerinin aylık gecikme durumu (`status`).
- **previous_application:** Home Credit'e daha önce yapılan başvurular: ürün türü, istenen ve onaylanan tutar, sonuç (onay, red, iptal), red nedeni.
- **pos_cash_balance:** Mağazadan taksitli alım ve nakit kredilerin aylık bakiyesi ve gecikmesi.
- **credit_card_balance:** Kredi kartlarının aylık bakiyesi, limiti, harcaması, ödemesi ve gecikmesi.
- **installments_payments:** Taksitlerin ödenmesi gereken tarihi ve tutarı ile gerçekte ödendiği tarih ve tutar.

### Kapsama

| Ölçü | Değer |
|---|---|
| Train müşterisi | 307.511 |
| Büro kaydı olan train müşterisi | 263.491 |
| Büro kaydı olmayan train müşterisi | 44.020 (%14,31) |
| Önceki başvurusu olan müşteri (train + test) | 338.857 |
| Kredi kartı olan müşteri (train + test) | ~104 bin (~%29) |

## 4. Join Kuralları

**Kural 1: Alt tablolar, üst tabloya join edilmeden önce özetlenir.**
Her alt tablo, bağlandığı tabloya göre "bir'e çok" ilişkisindedir. Doğrudan join satırları çoğaltır ve toplamları şişirir.

```sql
-- Yanlış: satırlar müşteri başına ~5 katına çıkar
SELECT ...
FROM raw.application_train a
JOIN raw.previous_application p ON a.sk_id_curr = p.sk_id_curr;

-- Doğru: önce müşteri bazında özetle, sonra join et
WITH onceki AS (
    SELECT sk_id_curr, COUNT(*) AS onceki_basvuru_sayisi
    FROM raw.previous_application
    GROUP BY sk_id_curr
)
SELECT ...
FROM raw.application_train a
LEFT JOIN onceki o ON a.sk_id_curr = o.sk_id_curr;
```

**Kural 2: Müşteri tablosundan yapılan join'ler `LEFT JOIN` olur.**
Her müşterinin büro kaydı ya da önceki başvurusu yoktur. `INNER JOIN` bu müşterileri sessizce analizden düşürür (ör. 44.020 kayıtsız müşteri).

**Kural 3: İki seviyeli tablolar iki adımda özetlenir.**
`bureau_balance` → önce `sk_id_bureau` bazında özetlenir → `bureau` ile birleşir → sonra `sk_id_curr` bazında özetlenir → müşteri tablosuna bağlanır. Aynı mantık `previous_application` altındaki üç tablo için geçerlidir.

**Kural 4: Train ve test müşterileri birlikte bulunur.**
`bureau` ve `previous_application` tabloları hem train hem test müşterilerini kapsar. Bu tablolardaki müşteri sayıları train ile doğrudan karşılaştırılmaz; karşılaştırma train tablosundan `LEFT JOIN` ile yapılır.

## 5. Bilinen Veri Özellikleri

**Hedef değişken (`target`)**
- `1` = müşteri ilk taksitlerinden en az birinde belirli bir günden fazla gecikmiş; `0` = diğer durumlar.
- Bu, bankaların resmi temerrüt (90+ gün, NPL) tanımından daha geniştir. Projede "temerrüt oranı" bu tanımla kullanılır.
- Dağılım dengesiz: %8,07 sorunlu, %91,93 sorunsuz.

**Tarih sütunları (`days_*`)**
- Tarihler, başvuru gününe göre gün farkı olarak verilmiş; geçmiş tarihler **negatif**.
- Örnek: `days_birth = -12000` → başvurudan 12.000 gün önce doğmuş (~33 yaş). Yaş = `-days_birth / 365`.
- `days_employed` sütununda gerçek olmayan büyük pozitif bir değer (365243) olduğu biliniyor; çalışmayan/emekli müşterileri işaret ediyor olabilir. Staging aşamasında doğrulanacak.

**Ay sütunları (`months_balance`)**
- Başvuru ayına göre ay farkı; `-1` = başvurudan bir önceki ay.

**`bureau_balance.status` kodları**

| Kod | Anlamı |
|---|---|
| C | Kredi kapanmış |
| X | Durum bilinmiyor |
| 0 | Gecikme yok |
| 1 | 1–30 gün gecikme |
| 2 | 31–60 gün gecikme |
| 3 | 61–90 gün gecikme |
| 4 | 91–120 gün gecikme |
| 5 | 120+ gün gecikme, satılmış ya da zarar yazılmış |

- C ve X aktif ay değildir. Gecikme oranlarında payda yalnızca 0–5 olmalıdır.
- X, "gecikme yok" olarak yorumlanmamalı; ayrı kategori olarak ele alınmalıdır.

**Kategorik değerler**
- Bazı kategorik sütunlarda `XNA` ya da `XAP` gibi "bilinmiyor / uygulanamaz" anlamına gelen değerler bulunuyor. Staging aşamasında NULL'a çevrilip çevrilmeyeceğine karar verilecek.

**Ham katman**
- `raw` şemasındaki tüm sütunlar `TEXT` tipinde. Tip dönüşümleri staging katmanında yapılır; raw katmanına dokunulmaz.
- Sütun adları küçük harfe çevrildi (Postgres'te tırnak gerektirmemesi için).
