# Yhteiset konventiot

Sopimus Mac-sovelluksen (`Sources/Mak8rMail`), Mac mini -daemonin (`Sources/Mak8rDaemon`) ja
Windows-portin (`windows/`) välillä. Kaikki kolme lukevat ja kirjoittavat samaa tilaa samalle
postipalvelimelle, joten tämän dokumentin muutos on muutos kaikkiin kolmeen: päivitä dokumentti,
testit ja `CHANGELOG.md` samassa commitissa.

Tausta ja perustelut: `docs/HANDOFF.md` (kohdat 3 ja 5).
Gmail-kiintiö (hinnasto, osuudet, uudelleenyritykset, lukuvälimuisti): `docs/gmail-quota.md`.

## 0. Yleiset säännöt

- **Jaettu tila on palvelimella tunnisteina.** Paikallisesti tallennetaan vain välimuistia ja
  laitekohtaisia asioita (päivän laskurit, daemonin `historyId`-vesileima ja lähetettyjen
  osoitteiden välimuisti). Tieto siitä, että daemon on luokitellut ketjun, on palvelimella
  piilotettuna tunnisteena (§2). Laitteet eivät synkronoi mitään keskenään.
- **Tunnisteiden nimet ovat sopimus, ID:t eivät.** Gmailin `threads.modify` ottaa tunnisteiden
  ID:t (`Label_123…`), jotka ovat tilikohtaisia. Jokainen osapuoli pitää nimi→ID-välimuistia
  (`users.labels.list`) ja luo puuttuvan tunnisteen itse (`users.labels.create`, aina molemmat
  näkyvyyskentät). Nimi haetaan ensin täsmälleen ja sitten kirjainkoosta riippumatta, koska Gmail
  pitää nimiä kirjainkoosta riippumattomina.
  - Jos luonti palauttaa 409 (nimi on jo olemassa) tai 400 (varattu tai kelvoton nimi), välimuisti
    päivitetään listaamalla uudelleen ja käytetään löytynyttä tunnistetta. Jos nimeä ei silloinkaan
    löydy, nimi on varattu eikä sitä voi käyttää.
  - Jos ketjulla on ID, jota välimuisti ei tunne, välimuisti päivitetään ennen kuin ketjusta tehdään
    päätöksiä.
  - Jos `modify` palauttaa 400 tai 404 (tuntemattoman ID:n koodia ei ole dokumentoitu), välimuisti
    päivitetään, ketjun tunnisteet haetaan uudelleen, puuttuvat tunnisteet luodaan ja kutsu lasketaan
    uudelleen. Se lähetetään kerran uudelleen vain, jos se muuttui; muuten virhe on lopullinen.
- Järjestelmätunnisteiden ID on sama kuin nimi: `INBOX`, `UNREAD`, `STARRED`, `TRASH`, `SPAM`,
  `SENT`, `DRAFT`.
- **Kaikki toimenpiteet ovat idempotentteja.** Kaksi osapuolta voi tehdä saman asian yhtä aikaa
  rikkomatta tilaa.
- Tunnisteet asetetaan ketjutasolla (`threads.modify`), kuten upstream-koodissa.

## 1. Snooze

### Tunnisteet

| Tunniste | Merkitys | Näkyvyys luotaessa |
|---|---|---|
| `Torkku` | Ketju on torkutettu. Torkku-näkymä (haku `label:torkku`) listaa nämä. | `labelShow` / `show` |
| `Torkku/<aika>` | Herätysaika UTC:nä minuutin tarkkuudella, muoto `yyyyMMdd'T'HHmm'Z'`, esim. `Torkku/20261005T0600Z` (Helsingissä ma 5.10.2026 klo 9.00). Tunnistus: `^Torkku/(\d{8})T(\d{4})Z$`, jossa `\d` on vain ASCII 0–9, etuliite on kirjainkoon mukainen ja päivämäärän on oltava todellinen, vuosi ≥ 1970 (esim. `20260230` ja `T2400` eivät kelpaa). | `labelHide` / `hide` |

Merkki `Torkku` on myös `Torkku/<aika>`-tunnisteiden näyttövanhempi: `/`-nimet näkyvät sen alla
sisäkkäin siellä, missä ne näkyvät. Erillistä yläkansiota ei luoda. Gmailin web- ja puhelinsovellus
eivät listaa piilotettuja aikatunnisteita, mutta IMAP-ohjelmat (Apple Mail, Outlook) näyttävät ne
`Torkku`-kansion alikansioina, yksi kutakin odottavaa herätysaikaa kohden; rajapinnalla tätä ei voi
estää.

**Älä poista tai siirrä `Torkku`-tunnistetta, kun ketjuja on torkutettuna.** Gmailin webissä
ylätason tunnisteen poisto poistaa myös kaikki sen alatunnisteet (siirto siirtää ne). Silloin
torkutetuilta ketjuilta katoavat sekä merkki että kaikki `Torkku/<aika>`-tunnisteet, ja koska ne
eivät ole `INBOX`issa, ne eivät enää palaa: herättäjä ei löydä niitä eikä niitä voi palauttaa
aikatunnisteista.

### Torkutus (asiakasohjelma)

Torkuttaja hakee ketjun nykyiset tunnisteet juuri ennen kutsua (`threads.get`, `format=minimal`;
ketjun tunnisteet ovat viestien tunnisteiden unioni). Sitten yksi `threads.modify`-kutsu, jolloin
ketju ei koskaan ole yhtä aikaa `INBOX`issa ja torkutettuna:

- **remove:** `INBOX` (aina, vaikka sitä ei näkyisi) ja kaikki ketjun nykyiset `Torkku/*`-tunnisteet,
  myös epäkelvot, paitsi uusi aika
- **add:** `Torkku` ja `Torkku/<aika>`

Sama ID ei ole koskaan sekä add- että remove-listassa (uudelleentorkutus samaan minuuttiin). Aika
pyöristetään ylöspäin seuraavaan minuuttiin, ja sen on oltava tulevaisuudessa. Lukutilaan ei kosketa.

### Herätys

Herättäjä on ensisijaisesti daemon (minuutin välein). Asiakasohjelmat toimivat varalla
käynnistyessään ja 5 minuutin välein, mutta eivät siivoa (ks. Siivous).
Herättäjä päivittää ensin nimi→ID-välimuistin (`labels.list`) ja listaa ketjut `threads.list`illä
parametreilla `labelIds=<Torkku-ID>` ja `includeSpamTrash=true` (oletus on `false`, jolloin sääntö 1
ei koskaan laukeaisi), ilman `q`-hakua. Kullekin ketjulle se hakee tunnisteet (`threads.get`,
`format=minimal`, viestien unioni), päivittää välimuistin, jos ketjulla on tuntematon ID, ja tekee
heti ensimmäisen osuvan toimenpiteen:

| # | Ehto | Toimenpide |
|---|---|---|
| 0 | Ketjulla ei enää ole `Torkku`a (toinen herättäjä tai Matti ehti ensin) | Ei toimenpiteitä. |
| 1 | Ketjulla on `TRASH` tai `SPAM` | remove `Torkku` + `Torkku/*`. Ei palauteta Saapuneisiin. |
| 2 | Ketjulla on jo `INBOX` (uusi viesti ketjuun tai siirto Saapuneisiin toisessa ohjelmassa) | remove `Torkku` + `Torkku/*`. Torkku peruuntuu, `UNREAD`ia ei lisätä. |
| 3 | Herätysaika ≤ nyt | add `INBOX` + `UNREAD`, remove `Torkku` + `Torkku/*`. |
| 4 | Ei yhtään kelvollista `Torkku/*`-tunnistetta (rikkinäinen tila) | Kuten 3: herätetään heti. |
| – | Muuten | Ei toimenpiteitä. |

- Jos ketjulla on useita `Torkku/*`-tunnisteita (kaksi laitetta torkutti lähes samaan aikaan),
  käytetään **aikaisinta**.
- `UNREAD` ketjutasolla merkitsee kaikki ketjun viestit lukemattomiksi. Tämä on hyväksytty
  yksinkertaistus.
- **Siivous (vain daemon):** aikatunnisteita siivoaa ainoastaan Mac minin daemon, jonka kello on
  NTP-synkronoitu. Asiakasohjelmat (Mac-sovellus, Windows) eivät koskaan poista tunnisteita.
  Daemon poistaa jokaisen kierroksen lopuksi (`labels.delete`) ne kelvolliset
  `Torkku/<aika>`-tunnisteet, joiden aika on vähintään 5 minuuttia menneisyydessä. Poisto irrottaa
  tunnisteen myös ketjuilta, joilla se vielä on; jos sellaisella ketjulla on yhä `Torkku`, se herää
  seuraavalla kierroksella säännöllä 4, mikä on oikein, koska aika on jo mennyt. Tulevia tunnisteita
  ei poisteta, vaikka niillä ei olisi ketjuja: muuten siivous voisi poistaa tunnisteen, jonka toinen
  laite on juuri lisännyt ketjuun, ja ketju heräisi heti säännöllä 4. `Torkku`-tunnistetta ja
  epäkelpoja `Torkku/*`-nimiä ei poisteta.
  Daemon siivoaa vain, kun sen herätys on tilassa `live` (§4) ja sen kello poikkeaa Gmailin
  vastausten `Date`-otsakkeesta enintään 2 minuuttia; muuten se herättää mutta ei siivoa.

### Ajat ja pikavalinnat

- Pikavalinnat lasketaan **Europe/Helsinki**-ajassa (kesäaika huomioiden) ja tallennetaan UTC:nä.
  Sekunnit pyöristetään ylöspäin seuraavaan minuuttiin, jotta herätys ei ole koskaan ennen
  valittua hetkeä.
- Seinäkelloaika muunnetaan hetkeksi näin: kesäajan aukossa (maaliskuun viimeinen sunnuntai
  klo 3.00–3.59) aika siirtyy eteenpäin aukon verran; lokakuun toistuvalla tunnilla (klo 3.00–3.59)
  valitaan aikaisempi hetki.
- "Huomenna" on seuraava kalenteripäivä myös puolenyön jälkeen (avoin, ks. handoffin kohta 8).
- `h` avaa valikon. Pikavalinnat (Matti 7.10.2026):

| Valinta | Aika |
|---|---|
| Tänään illalla | tänään klo 20.00; klo 20 jälkeen rivi näkyy himmeänä eikä ole valittavissa (numerot pysyvät samoina) |
| Huomenna | huomenna klo 8.00 |
| Ensi viikolla | seuraava maanantai klo 8.00 (maanantaina valittuna: viikon päästä) |
| Ensi kuussa | seuraavan kuun 1. päivä klo 8.00 (kuun 1. päivänä valittuna: kuukauden päästä) |
| Oma aika | kalenteri (nuolet vaihtavat päivää, kellonaika säilyy) ja kellonaikakenttä; tab vaihtaa |

### Outlook (vaihe 6)

Kansio `Torkku` ja kategoria `Torkku 20261005T0600Z`. `LiveGraphClient` esittää ne muulle
koodille Gmail-muotoisina tunnisteina (`Torkku`, `Torkku/20261005T0600Z`), joten herätyslogiikka
on sama.

## 2. Lajittelu

### Tunnisteet

| Tunniste | Lähde |
|---|---|
| `Lajittelu/Uutiskirjeet` | sääntö |
| `Lajittelu/Ilmoitukset` | sääntö |
| `Lajittelu/Kuitit` | sääntö |
| `Lajittelu/Ihmiset` | sääntö |
| `Lajittelu/Vaatii toimenpidettä` | AI (vaihe 7) |
| `Lajittelu/Luokiteltu` | daemon (merkki, piilotettu) |

`Lajittelu/Luokiteltu` on daemonin merkki siitä, että se on luokitellut ketjun. Daemon luo sen
näkyvyydellä `labelHide`/`hide` ja muut lajittelutunnisteet näkyvyydellä `labelShow`/`show` (§0).
Merkki ei ole lajittelunäkymä, sitä ei periytetä eikä mikään osapuoli poista sitä. Gmailin web- ja
puhelinsovellus eivät näytä sitä, mutta IMAP-ohjelmat näyttävät sen `Lajittelu`-kansion
alikansiona (vrt. §1). Älä poista tai siirrä `Lajittelu`-tunnistetta Gmailin webissä: se poistaa
myös alatunnisteet ja merkin, jolloin daemon luokittelee ketjut uudelleen, kun niihin tulee uusi
viesti.

### Kuka kirjoittaa

- **Vain daemon ajaa säännöt** eli asettaa `Lajittelu/*`-tunnisteita ketjuille. Asiakasohjelmat
  näyttävät tunnisteet näkyvinä, ja Matti voi lisätä tai poistaa niitä käsin.
- **Asiakasohjelma saa luoda tunnisteet.** Mac-sovellus luo tilin käynnistyessä puuttuvat
  `Lajittelu/Uutiskirjeet`- ja `Lajittelu/Ilmoitukset`-tunnisteet (näkyvyys `labelShow`/`show`,
  §0:n sääntöjen mukaan) ennen kuin Käsiteltävät-näkymä ladataan, jotta oletushaku (§3) toimii
  ennen daemonia. Ensimmäinen lataus odottaa tarkistusta enintään 3 s; hitaamman tarkistuksen
  ajan haku lähetetään ilman rajausta (§3). Tunnisteet tarkistetaan uudelleen jokaisen
  herätyskierroksen jälkeen. Ketjuille se ei niitä aseta.
- Säännöt ovat daemonin koneella tiedostossa
  `~/Library/Application Support/Mak8rMail/rules.json` (skeema 1; kentät ja oletustiedosto:
  `docs/design/phase2-daemon.md` §7). Jos tiedostoa ei ole, daemon käyttää sisäänrakennettuja
  oletussääntöjä. Virheellistä tiedostoa ei oteta käyttöön: daemon jatkaa viimeisellä kelvollisella
  versiolla ja kertoo virheestä tilassaan (`mak8r-daemon status`). Sääntö saa asettaa vain
  `Lajittelu/`-alkuisen tunnisteen, ei kuitenkaan merkkiä `Lajittelu/Luokiteltu` eikä
  `Lajittelu/Vaatii toimenpidettä` -tunnistetta (vaihe 7).
- Daemon luokittelee vain saapuneita viestejä. `SENT`-, `DRAFT`-, `SPAM`-, `TRASH`- ja
  `CHAT`-viestejä ei luokitella. Lähetetyistä viesteistä päivitetään vain lähetettyjen osoitteiden
  välimuisti (sääntö 4). Daemonin omia muistutusviestejä (otsake `X-Mak8r-Daemon`, §4) ei
  luokitella.

### Oletussäännöt

Ketjun luokittelee sen **ratkaiseva viesti**: uusin (`internalDate`) niistä ketjun uusista
saapuneista viesteistä, jotka ovat tuoreessa luvussa Saapuneissa (`INBOX`). Säännöt katsovat vain
sen otsakkeita ja tunnisteita; ketjun vanhemmat viestit eivät vaikuta. Jos yksikään uusi saapunut
viesti ei ole Saapuneissa (esim. Gmail-suodatin arkistoi sen), ketjua ei luokitella.

Säännöt käydään järjestyksessä, ja ensimmäinen osuma voittaa:

0. Viestillä on käyttäjätunniste, jonka nimi alkaa `kuitit/` (kirjainkoosta riippumatta; Matin
   omat Gmail-suodattimet) → `Kuitit`
1. Viestissä on ei-tyhjä `List-Unsubscribe`- tai `List-Id`-otsake (vain olemassaolo ratkaisee,
   arvoa ei tulkita) → `Uutiskirjeet`
2. Lähettäjän osoitteesta löytyy kuvio `no-reply|noreply|notifications?@` (ei ankkuroitu), tai
   viestissä on `Auto-Submitted`-otsake, jonka arvo (sulkukommentit ja ensimmäisestä `;`:stä
   alkaen poistettuina, pienin kirjaimin) ei ole tyhjä eikä `no` → `Ilmoitukset`
3. Aiheen tai lähettäjän jokin sana vastaa kuittikuviota (kuitti, tilausvahvistus, lasku, receipt,
   invoice) → `Kuitit`. Sana on kirjainjono (`[\p{L}-]+`) sen jälkeen, kun aihe on purettu
   (RFC 2047), normalisoitu (NFC), näkymättömät muotoilumerkit (`\p{Cf}`) on poistettu ja kirjaimet
   pienennetty. Lähettäjän sanat ovat nimi ja osoitteen @-merkkiä edeltävä osa. Kuvion on vastattava
   koko sanaa: `sähkölasku` ja `ostokuitti` osuvat, `kuitenkin`, `kuittaus` ja `laskuri` eivät.
   Tarkat kuviot ovat oletustiedostossa.
4. Lähettäjä on joku, jolle Matti on lähettänyt viestin (lähetettyjen viestien To- ja
   Cc-osoitteiden välimuisti, tilikohtainen, pienin kirjaimin, Matin omat osoitteet pois)
   → `Ihmiset`

Lähettäjän osoite on `From`-otsakkeen ensimmäinen kelvollinen osoite ilman sulkukommenttia, pienin
kirjaimin. `Sender`-, `Reply-To`- ja `Return-Path`-otsakkeita ei käytetä.

Poikkeus: jos ratkaiseva viesti on automaattinen vastaus (`Auto-Submitted: auto-replied`) ja
ketjussa on Matin lähettämä viesti, ketjua ei luokitella nyt, vaan seuraava viesti ratkaisee.

Jos mikään sääntö ei osu, ketjua ei merkitä, ja se arvioidaan uudelleen, kun siihen tulee uusi
saapunut viesti.

### Käsin tehty on aina oikein

- Daemon luokittelee ketjun **kerran**: yksi `threads.modify` lisää säännön tunnisteen ja merkin
  `Lajittelu/Luokiteltu`.
- Ketjua, jolla on merkki, ei luokitella uudelleen. Jos Matti poistaa ketjulta kaikki
  lajittelutunnisteet, merkki jää, eikä daemon lisää tunnistetta takaisin.
- **Periytys ei ole luokittelua.** Kun ketjuun, jolla on jokin `Lajittelu/*`-tunniste, tulee uusi
  saapunut viesti, daemon lukee ketjun tuoreena ja lisää ketjulle (`threads.modify`, vain add) ne
  `Lajittelu/*`-tunnisteet, jotka ketjun jollakin viestillä sillä hetkellä on, sekä merkin, jos se
  puuttuu. `Lajittelu/Vaatii toimenpidettä` -tunnistetta ei periytetä. Jos Matti on vaihtanut
  tunnisteen, uusi viesti saa Matin valitseman. Daemon ei koskaan poista `Lajittelu/*`-tunnistetta
  eikä lähetä tyhjää muutosta.
- Daemon lukee ketjun tuoreena juuri ennen kirjoitusta (`docs/gmail-quota.md` §5).
- Daemonin paikallinen tila on tiedostossa
  `~/Library/Application Support/Mak8rMail/daemon/state-<tili>.json` (`historyId`-vesileima,
  lähetettyjen osoitteiden välimuisti ja kirjautumisen tila). Tiedoston katoaminen ei riko mitään,
  koska luokittelutieto on palvelimella (merkki ja tunnisteet): daemon aloittaa nykyhetkestä ja
  rakentaa välimuistin uudelleen. Katoamisen aikana tulleet viestit luokitellaan, kun ketjuun tulee
  seuraava viesti.
- Kutakin Gmail-tiliä käsittelee vain yksi daemon.

## 3. Inbox zero

- Oletusnäkymä: `in:inbox -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset`. Gmail-haussa
  tunnisteen nimi kirjoitetaan pienin kirjaimin, ja `/` sekä välilyönti korvataan `-`:lla.
- **Puuttuva tunniste tyhjentää haun.** Gmail palauttaa haulle, joka rajaa pois olemattoman
  tunnisteen (`-label:x`), ei mitään, vaikka `in:inbox` palauttaa saapuneet (Matti tarkisti
  5.10.2026). Siksi asiakas luo tunnisteet ensin (§2). Jos luonti ei onnistu (esim. yhteyskatko),
  asiakas jättää vahvistamattomien tunnisteiden `-label:`-rajaukset pois Gmailille lähetetystä
  hausta: ilman tunnistetta millään ketjulla ei voi olla sitä, joten haun merkitys on sama, eikä
  tyhjää "Kaikki käsitelty" -tilaa näytetä väärin. Luontia yritetään uudelleen jokaisen
  herätyskierroksen jälkeen.
- Jokaiselle lajittelutunnisteelle on oma näkymä: `in:inbox label:lajittelu-<nimi>`, esim.
  `label:lajittelu-vaatii-toimenpidettä` (ä-kirjaimen toiminta tarkistettava, ks. alla)
  (oletus: näkymät näyttävät vain käsittelemättömät, arkistoidut eivät jää roikkumaan).
- Rajapinnan haku toimii viestitasolla, ei ketjutasolla: uusi viesti ei itsestään peri ketjun
  `Lajittelu/*`-tunnistetta. Daemon periyttää sen (§2, "Käsin tehty on aina oikein") yleensä
  minuutin kuluessa; sitä ennen luokiteltu ketju voi näkyä hetken oletusnäkymässä. Daemon
  tarkistaa lisäksi 30 minuutin välein Saapuneiden tuoreet viestit, joilta merkki puuttuu, ja
  korjaa ne.
- Kun oletusnäkymä on tyhjä, näytetään rauhallinen tyhjä tila ja päivän arkistoitu/torkutettu-laskuri.
  Laskuri on laitekohtainen, nollautuu Helsingin ajan keskiyöllä eikä synkronoidu.

## 4. Daemon

- Daemon (`Sources/Mak8rDaemon`, ohjelma `mak8r-daemon`) pyörii Mac minillä launchd-agenttina
  `fi.seise.mail.daemon`. Se kirjoittaa vain kansioon
  `~/Library/Application Support/Mak8rMail/daemon/` ja lokeihin `~/Library/Logs/Mak8rMail/`.
  Matti muokkaa tiedostoja `daemon.json` ja `rules.json`.
- Daemonilla on oma Google-kirjautuminen (`mak8r-daemon login <osoite>`), eri kuin sovelluksilla.
  Tokeni on tiedostossa `daemon/tokens/<tili>.json` (tiedosto 0600, kansio 0700), ei Keychainissa.
  Daemon ei koskaan peru (revoke) kirjautumista, koska peruminen mitätöisi myös sovellusten
  kirjautumisen.
- OAuth-sovellus on testitilassa, joten kirjautuminen vanhenee 7 vuorokautta suostumuksesta.
  Daemon lisää Saapuneisiin muistutusviestin 24 ja 3 tuntia ennen vanhenemista (`messages.insert`,
  otsake `X-Mak8r-Daemon`; viestiä ei lähetetä minnekään) ja arkistoi muistutukset, kun Matti on
  kirjautunut uudelleen. Vanhentuneena daemon odottaa tilansa säilyttäen ja jatkaa kirjautumisen
  jälkeen siitä, mihin jäi.
- Toimintatila on tiedostossa `daemon.json`: herätykselle ja lajittelulle kummallekin `off`,
  `shadow` (päätökset vain lokiin, ei kirjoituksia Gmailiin) tai `live`.
- `daemon.json` on vain omistajan luettavissa (0600), eikä mikään kirjoittaja laajenna sen oikeuksia.
  Salaisuuksia (tokeneita, salasanoja, avaimellisia webhook-osoitteita) ei laiteta siihen eikä
  `notify.command`-komentoriville, koska komentorivi näkyy `ps`:ssä kaikille koneen käyttäjille.
  Ilmoitusskripti lukee salaisuutensa itse omasta 0600-tiedostostaan tai Keychainista.
- `mak8r-daemon status` kertoo daemonin tilan; `--json` on koneluettava muoto muille ohjelmille.

## Tarkistettava vaiheen 1 alussa

Nämä varmistetaan oikealla Gmail-tilillä ennen kuin niiden varaan kirjoitetaan koodia. Jos
tulos poikkeaa, päivitä tämä dokumentti ensin.

1. **Torkku-tunnisteen nimi** (alun perin `Snoozed`-nimen varaus). Ratkaistu 3.10.2026: nimi Torkku
   (Matti). Merkki on `Torkku` ja aikatunnisteet `Torkku/<aika>`.
   Tausta: Gmailissa on oma, rajapinnalle näkymätön torkkuominaisuus ja Snoozed-kansio. Kysymys oli,
   hyväksyykö `labels.create` nimen `Snoozed` ja osuuko haku `label:snoozed` Gmailin omiin torkkuihin.
   Tutkimus 3.10.2026: hylkäyksistä ei löytynyt raportteja, ja `Snoozed`-niminen käyttäjätunniste on
   nähty (Exchange-migraatio, Outlook IMAP). Riskit: englanninkielinen Gmail olisi näyttänyt kaksi
   Snoozed-kohtaa, ja olemassa oleva samanniminen tunniste otettaisiin käyttöön. Jälkimmäinen pätee
   myös uuteen nimeen: olemassa oleva `Torkku`-niminen käyttäjätunniste (kirjainkoosta riippumatta,
   esim. `torkku`) otettaisiin käyttöön, ja herättäjä herättäisi kaikki sen ketjut. Tarkista tili
   ennen kuin herättäjä kytketään käyttöön.
2. **Hakusyntaksi tunnisteille, joissa on `/` tai välilyönti.** Gmail-haku kirjoittaa ne usein
   muodossa `label:lajittelu-uutiskirjeet`. Selvitä, toimiiko `label:Lajittelu/Uutiskirjeet`
   sellaisenaan ja miten `Vaatii toimenpidettä` (välilyönti ja ä) haetaan. Koodin omissa hauissa
   (herätys) varmempi vaihtoehto on `threads.list`in `labelIds`-parametri. Upstreamin
   `listThreads` tukee nyt vain `q`-hakua.
   Tutkimus: viivamuoto `label:lajittelu-uutiskirjeet` on Gmailin oma muoto. Koodin omat haut käyttävät
   `labelIds`ia.
3. **Virhekoodit.** `labels.create` olemassa olevalla nimellä (odotus 409) ja `modify` tuntemattomalla
   ID:llä add- ja remove-listassa (odotus 400). Koodi käsittelee 400, 404 ja 409, joten tulos muuttaa
   vain tätä dokumenttia.
4. **`includeSpamTrash`.** `threads.list` `labelIds=<Torkku-ID>&includeSpamTrash=true` palauttaa
   roskakorissa olevan torkutetun ketjun.
5. **Näkyvyys.** `labelHide`/`hide` piilottaa `Torkku/<aika>`-tunnisteet Gmailin web- ja puhelinsovelluksesta.
6. **Ylätason tunnisteen poisto.** Varmista testitunnisteilla (ei oikeilla torkuilla), että `Torkku`-tunnisteen
   poisto Gmailin webissä poistaa myös `Torkku/<aika>`-alatunnisteet ketjuineen (ks. §1).

## Tarkistettava vaiheen 2 alussa

1. Tuleeko lähetetty viesti `history.list`issä `messagesAdded`-tietueena `SENT`-tunnisteella, ja
   luonnos `DRAFT`-tunnisteella? (Ketju luetaan aina tuoreena, joten tulos vaikuttaa vain kulutukseen.)
2. Palauttaako `metadataHeaders=List-Id` otsakkeen, joka on kirjoitettu `List-ID`?
3. Antaako kirjautumisvastaus `refresh_token_expires_in`-kentän? (Lokiin vain kyllä/ei.)
4. Ovatko `kuitit/ostot`- ja `kuitit/tilaukset`-tunnisteet Gmail-suodattimien asettamia, ja
   ohittavatko suodattimet Saapuneet?
5. Löytääkö haku `-label:lajittelu-luokiteltu` piilotetun tunnisteen, ja miten merkki näkyy
   IMAP-ohjelmissa?
6. Vaikuttaako daemonin uusi kirjautuminen Mac-sovelluksen kirjautumiseen? (Odotus: ei.)
