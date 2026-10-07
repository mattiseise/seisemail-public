# Gmail-kiintiö: sopimus kaikille asiakasohjelmille

Mac-sovellus, iPhone, Mac mini -daemon ja Windows-portti käyttävät samaa Google-projektia
(`seisemail`), joten ne jakavat saman **käyttäjäkohtaisen minuuttikiintiön**. Tämä dokumentti
kertoo, miten jokainen asiakas pysyy sen sisällä. Spesifikaatio on Swift-koodi
(`Sources/MailCore/Net/Gmail*.swift`) ja sen testit; Windows-portti käyttää samoja fixtureja
(`Tests/MailCoreTests/Fixtures/gmail_403_*.json`, `threads_list_history.json`,
`thread_metadata_history.json`). Suunnitelma ja perustelut: `docs/design/gmail-quota.md`.

## 1. Kiintiö

- **Units per minute per user: 15 000** (nostettu 4.10.2026; uusi projekti saa 6 000).
  Ikkuna on liukuva 60 s. Google päästää rajan yli vähän (havaittu noin 6 320 / 6 000), joten
  rajalla ei suunnitella.
- `perUserLimit` muutetaan koodissa (`GmailQuotaPolicy`) vasta, kun Cloud-konsoli näyttää uuden
  arvon.

## 2. Hinnasto (yksikköä per kutsu)

| Kutsu | Yksiköt |
|---|---|
| `GET threads` (lista) | 10 |
| `GET threads/{id}` (mikä tahansa `format`) | 40 |
| `POST threads/{id}/modify` · `/trash` · `/untrash` | 10 · 20 · 10 |
| `DELETE threads/{id}` | 20 |
| `GET messages` · `GET messages/{id}` | 5 · 20 |
| `GET messages/{id}/attachments/{a}` | 20 |
| `POST messages/{id}/modify` · `/trash` | 5 · 20 |
| `POST messages/batchModify` (enintään 1 000 viestiä) | 50 |
| `POST upload/…/messages/send` | 100 |
| POST messages (insert) | 25 |
| `GET labels`, `GET labels/{id}` | 1 |
| `POST labels`, `PUT`/`PATCH`/`DELETE labels/{id}` | 5 |
| `GET history` | 2 |
| `GET profile`, `GET settings/sendAs` | 1 |
| Muu `gmail.googleapis.com`-kutsu | 40 (varovainen oletus) |

Muut isännät (esim. `oauth2.googleapis.com`) eivät kuulu kiintiöön.

## 3. Osuudet ja kaistat

| Asiakas | Kokonaisosuus | Taustakaista | Yhtä aikaa |
|---|---|---|---|
| Mac, iPhone, Windows (`.macApp`) | 70 % = 10 500 | 50 % = 7 500 | 8, joista tausta enintään 6 |
| Daemon (`.daemon`) | 20 % = 3 000 | 20 % = 3 000 | 4 |

- Daemonin lajittelu ja joukkotyöt (lähetettyjen täydennys, uudelleensynkronointi, `backfill`) käyttävät enintään 2 000 yksikköä minuutissa, joten herätykselle jää aina vähintään 1 000. Tahdin voi hidastaa `daemon.json`-asetuksella `sync.unitsPerMinute` (100–2 000), mutta ei nostaa yli 2 000:n.
- **Interaktiivinen kaista:** kaikki muut kuin GET-kutsut, `threads/{id}?format=full`, liitteet,
  `settings/sendAs` ja GET, jonka `cachePolicy` on `.reloadIgnoringLocalCacheData` (tuore luku
  ennen kirjoitusta). Muu on taustaa.
- Tausta saa käyttää vain oman osuutensa, joten käyttäjän toiminnoille jää aina vähintään 3 000
  yksikköä minuutissa. Interaktiivinen menee aina ensin; kaistan sisällä järjestys on FIFO.
- Kirjanpito on asiakkaan oma (liukuva ikkuna, veloitus kun kutsu päästetään). Jos asiakkaat
  kuormittavat yhtä aikaa ja Google silti rajoittaa, yhteinen odotus (kohta 4) hoitaa loput.

## 4. Mitä yritetään uudelleen

- **Rajoitus:** HTTP 429 (mikä tahansa runko) ja HTTP 403, jonka `error.errors[].reason` on
  `rateLimitExceeded` tai `userRateLimitExceeded` tai `error.details[].reason` on
  `RATE_LIMIT_EXCEEDED`. Jos runko ei ole JSONia, etsitään samat merkkijonot.
- **Ei rajoitus** (välitetään sellaisenaan, ei uudelleenyritystä): `dailyLimitExceeded`,
  `quotaExceeded`, `insufficientPermissions`, `ACCESS_TOKEN_SCOPE_INSUFFICIENT`,
  `accessNotConfigured`/`SERVICE_DISABLED`, `forbidden`, `domainPolicy` ja jäsentymätön 403.
- **Yksi yhteinen odotus per tili.** Uusi rajoitus (pyyntöön, joka päästettiin edellisen
  rajoituksen jälkeen) kasvattaa laskuria `n` ja odotus on `min(2^(n−1) s, 32 s) + 0–1 s`
  satunnaisesti; pidempi `Retry-After` (enintään 60 s) voittaa. Odotuksen jälkeen lähtee yksi
  koepyyntö yksin; sen onnistuminen avaa portin. Vanhemmat 403-vastaukset eivät kasvata laskuria.
- Jokaisen rajoituksen jälkeen kattoja pienennetään puoleen (alaraja 25 %), ja ne kasvavat
  0,25 jokaista rauhallista minuuttia kohden. Laskuri nollautuu minuutin rauhan jälkeen.
- **Yksittäinen pyyntö** yrittää enintään 7 kertaa ja odottaa jonossa ja uudelleenyrityksissä
  yhteensä enintään 90 s. Sen jälkeen virhe on `GmailError.rateLimited`. Kuusi odotusta on
  yhteensä 63–69 s, joten viimeinen yritys osuu jo kokonaan uuteen ikkunaan.
- 5xx-virheet ja 401 hoitaa `LiveGmailClient.perform` kuten ennenkin.
- **Herätyskierros** keskeytyy `rateLimited`-virheeseen kuten yhteyskatkoon (muita ketjuja ei enää
  haeta), ja seuraava kierros on 60 s päästä.

## 5. Lukuvälimuisti

- Vain `GET threads/{id}?format=metadata` ja `format=minimal` -rungot välimuistitetaan, muistissa,
  enintään 1 000 (LRU), enintään tunnin ajan.
- **Osuma vaatii:** viimeisin lista (`threads.list` palauttaa `threads[].historyId`) on enintään
  120 s vanha ja kertoo saman `historyId`:n kuin välimuistissa oleva runko. Vanhempi
  `historyId` ei korvaa uudempaa havaintoa.
- **Lista ennen hakua:** jokainen rivien hakija listaa juuri ennen kuin hakee rivit, joten osuma
  on täsmälleen se tila, jonka hakijan oma lista kertoi.
- **Tuore luku ennen kirjoitusta:** `.reloadIgnoringLocalCacheData` ohittaa välimuistin (ja
  kulkee interaktiivisella kaistalla). Snooze ja daemon lukevat näin ennen `modify`a.
- **Herättäjä:** kierros listaa `Torkku`-ketjut (`threads.list`, joka antaa `historyId`:t) ja lukee
  niiden tunnisteet välimuistin kautta (`format=minimal`). Vain ketju, jonka välimuistin tunnisteet
  vaativat muutosta, luetaan uudelleen tuoreena ja päätös tehdään uudelleen ennen `modify`a.
  Kierros maksaa noin `11 + 40 × muuttuneet + 40 × erääntyneet` yksikköä.
- **Lukumäärät:** näkymä, joka on tasan yksi tunniste (`is:starred`, `label:torkku`), saa
  lukemattomien määrän `GET labels/{id}`-kutsulla (1 yksikkö) haun (10) sijaan.
- Kirjoitus ketjuun (`threads/{id}/…`, `DELETE threads/{id}`) tyhjentää ketjun rivit ennen ja
  jälkeen kutsun; viestikirjoitus (`messages/*`, myös `batchModify`) tyhjentää kaiken. Kirjoitusta
  ennen alkanutta vastausta ei tallenneta.

## 6. Joukkotoiminnot

- Monen ketjun arkistointi, luetuksi tai lukemattomaksi merkintä ja tähdet tehdään
  `messages.batchModify`-kutsulla (50 yksikköä 1 000 viestiltä), kun ketjujen viesti-ID:t
  tunnetaan rivin metadatasta. Muuten käytetään `threads.modify`a ketju kerrallaan.
  Roskakoriin siirto tehdään aina `threads.trash`illa.
- Yksittäisen ketjun toiminnot käyttävät `threads.modify`a.
- Rivit lähtevät listalta heti, ja tila näkyy listan alla ("Arkistoidaan 140 ketjua…" →
  "Arkistoitu 140 ketjua"). ⌘Z kumoaa koko joukon myös kesken ajon: lähettämättömiä ei lähetetä,
  ja jo tehdyt palautetaan. Vain lopullisesti (90 s jälkeen) epäonnistuneet palaavat listalle
  ilmoituksella "x/y epäonnistui".
- Torkutus (myös monen ketjun) noudattaa samoja sääntöjä ilman tilariviä: ⌘Z kumoaa sen myös
  kesken ajon, ja ensimmäinen lopullinen rajoitus päättää sen; aloittamattomat ketjut palaavat
  listalle heti.
- `batchModify` muuttaa ne viestit, jotka rivin metadatassa oli. Jos ketjuun on sen jälkeen
  tullut uusi viesti, se jää koskematta (Gmailin tapaan uusi viesti palauttaa ketjun saapuneisiin).

## 7. Loki

```
log show --predicate 'subsystem == "fi.mak8r.mail" && category == "quota"' --last 1h
```

- Jokainen rajoitus `.error`-tasolla: tila, kutsun laji, syy, `quota_limit`, ikkunan yksiköt,
  laskuri ja odotus.
- Luovutus `.error`-tasolla.
- Välimuistin osumat ja ohitukset `.debug`-tasolla 100 haun välein.
