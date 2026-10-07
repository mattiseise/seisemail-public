# Muutosloki

Forkin omat muutokset vaiheittain (ks. `docs/HANDOFF.md`, kohta 6). Upstreamin muutokset
näkyvät `git log upstream/main`.

## README:n kuvat (7.10.2026)

Matin pyyntö: kuvat forkin ominaisuuksista README:hen, jotta forkin voi näyttää muille.

- README:n alkuun osio "Tämä forkki: seisemail" ja yhdeksän kuvaa (`docs/images/`): Käsiteltävät ja
  kokousmerkit, kokouskutsu, torkkuvalikko, Oma aika, Torkku-näkymä, valinta, tekstin koko, Inbox 0.
- `make screenshots`: oikea sovellus omalla bundle-tunnisteella (`fi.mak8r.mail.screenshots`) ja
  väliaikaisella datakansiolla (`MAK8R_DATA_DIR` → `AppPaths`), keksitty esittelytili `DemoGmail`
  (MailCore, testattu), `ScreenshotDirector` käy näkymät läpi ja piirtää ikkunan 2x-kuviksi.
  Ei verkkoa, ei Keychainia, ei ilmoituksia; ajetaan vain, kun sekä `-screenshots` että
  `MAK8R_DATA_DIR` on annettu.

## Inbox 0 -putki ja oma kalenteri (7.10.2026)

Matin palaute: päivämäärävalitsin oli kankea ja irrallinen muusta sovelluksesta; Inbox 0 Superhumanin
tyyliin ja viikkoputki näkyviin.

- Inbox 0: valokuva reunasta reunaan. Keskellä "INBOX 0 -PUTKI", ohut iso luku ja "VIIKKOA";
  vasemmassa alakulmassa "Inbox 0 – kaikki on käsitelty" ja päivän luvut, oikeassa kuvan tekijä.
  Tekstien takana kevyt tummennus ja varjo, jotta ne erottuvat vaaleistakin kuvista.
- Putki: viikot (ma–su, Helsingin aikaa), joina tilin Saapuneet on nähty tyhjänä ainakin kerran.
  Kuluva viikko ei katkaise putkea ennen kuin se on ohi. Laitekohtainen kuten päivän laskurit
  (`seise-inbox-zero-weeks.json`), alkaa nollasta.
- Oma aika: sovelluksen omalla tyylillä piirretty kalenteri (maanantaista alkaen, viikkonumerot,
  menneet päivät himmeinä, tänään korostettuna, ‹ › kuukaudet) ja kellonaika: kirjoita numeroina
  (8, 14, 830, 1430), ↑↓ 15 minuuttia tai pikavalinnat 8.00 / 12.00 / 16.00 / 20.00. Nuolet
  vaihtavat päivää, numerot menevät suoraan kellonaikaan, ↩ torkuttaa. AppKitin päivämäärävalitsimet
  poistettu; kaikki tila `SnoozeMenuModel`issa (testattu).

## Käyttöliittymän kielenhuolto (7.10.2026)

Matin pyyntö: käyttöliittymän suomi kuntoon (Mac ja iPhone).

- Lukusanat: "3 valittua" (oli "3 valittu"), "1 uusi viesti" ilmoituksessa (oli "1 uutta viestiä").
- Toimintojen nimet verbeiksi: "Lisää tai poista tähti" (oli "Tähti", "Tähti päälle/pois"), "Siirrä
  roskakoriin", "Hae", "Seuraava ketju", "Valitse tai poista valinta", "Näytä tai kätke sivupalkki".
- Suodattimet: "Ei lukematon" (oli "Ei: lukematon"), "Ei sisällä: lasku" (oli "Sisältää ei ole:
  lasku"), "Aihe ei sisällä", "Aikavälin ulkopuolella", "Ei liitteitä: PDF"; editorissa "Viesti
  sisältää / ei sisällä"; päivämäärät "Alkupäivä" ja "Loppupäivä" (oli "Alkaen", "Päättyen").
- Torkkukortin vihjerivit kokonaisiksi lauseiksi ("Nuolet vaihtavat päivää · Tab siirtää
  kellonaikaan · ↩ torkuttaa · Esc palaa listaan").
- Ilmoitukset: "Toiminto epäonnistui 1 ketjussa (yhteensä 3)" (oli "1/3 epäonnistui"), "Gmail
  rajoittaa pyyntöjä. Yritä uudelleen minuutin päästä.", "Merkitseminen epäonnistui", "Kumotaan
  luetuksi merkitseminen…", "Valinta muuttui, joten viestejä ei torkutettu".
- Kesken jääneet luonnokset: "Viesti jäi kesken edellisellä kerralla" (oli "tallentamaton luonnos").
- Etäkuvat: "Näytä aina kuvat lähettäjältä …" (oli "Salli aina lähettäjältä …").
- Asetukset: macOS:n oikeat nimet (Näppäinoikotiet… → Appien oikotiet), "2 sekunnin kuluttua",
  "Lähetyksen perumisaika", "Käynnistä sisäänkirjautumisen yhteydessä", pilkut ja lauserakenteet.
- Peruutuspainikkeet yhtenäisesti "Peruuta" (oli osin "Peru"); "Kumoa" jää ⌘Z:lle.
- Ennallaan: Gmail-tunnisteiden nimet (`Lajittelu/…`, `Torkku`), koska niiden muuttaminen
  katkaisisi olemassa olevat tunnisteet, ja Teams-kutsujen tunnistusfraasit.
- Daemon (yhdistämisen jälkeen): kirjautumisohjeet, `status`, komentojen vastaukset,
  ilmoitukset ja Saapuneisiin tuleva muistutus ("ajamaan taustalla", "vanheni …", "jatkaa
  tilillä …", sääntöjen nimet lainausmerkeissä). Lokirivit ennallaan.

## Torkun pikavalinnat ja kalenteri (7.10.2026)

Matin toive: uudet pikavalinnat ja päivämäärävalitsin, kun pikavalinnat eivät riitä.

- Pikavalinnat: 1 Tänään illalla (klo 20), 2 Huomenna (klo 8), 3 Ensi viikolla (seuraava maanantai
  klo 8), 4 Ensi kuussa (seuraavan kuun 1. päivä klo 8), 5 Oma aika. "Tänään myöhemmin" (+3 h),
  "Maanantaina" ja `NextWeekRule`-asetus poistettu.
- Klo 20 jälkeen "Tänään illalla" näkyy himmeänä ("Ei enää tänään") eikä ole valittavissa; numerot
  pysyvät samoina, ja nuolinäppäimet ohittavat rivin.
- Oma aika: kalenteri (maanantaista alkava, suomeksi) ja kellonaikakenttä. Kalenterilla on
  näppäimistö ensin: nuolet vaihtavat päivää ja kellonaika säilyy, myös kesäajan vaihteen yli. Tab
  vaihtaa kalenterin ja kellonajan välillä (oma käsittely, toimii ilman macOS:n täyttä
  näppäimistönavigointia), ↩ torkuttaa.
- Yhteinen testitaulukko `snooze_preset_cases.json` (44 tapausta) laskettu uudelleen Pythonin
  zoneinfolla; huomenna- ja maanantaitapausten arvot ennallaan.

## Inbox 0 -valokuvat (7.10.2026)

Matin toive: generoidun kuvan tilalle vaihtuvat luontovalokuvat, jotka toimivat myös ilman verkkoa.

- Päivän kuva: Wikimedia Commonsin päivän kuva (`api.wikimedia.org` featured-syöte, suomenkielinen
  Wikipedia), haetaan kerran Helsingin vuorokaudessa, 1920 px pikkukuva, välimuisti viikon
  (`~/Library/Caches/Mak8rMail/inbox0`). Syöte on epäluotettavaa: kelpaa vain https-JPEG
  Wikimedian omilta palvelimilta, vaakakuva (≥ 1,2:1), enintään 8 Mt ja lisenssi mukana. Muuten,
  verkotta tai asetuksen ollessa pois päältä näytetään pakettiin kuuluva kuva.
- Pakettikuvat (`Resources/InboxZero`, 8 kpl, 5,1 Mt): revontulet Mývatnilla, Ylläs, ruska
  Tenojoella, ilves, porot, Tukholman Slussen, Geirangerinvuono ja Klöntalersee. Kaikki Wikimedia
  Commonsin suosituimpia kuvia, CC BY-SA tai CC0; tekijät ja lähteet `credits.json`issa.
  Pakettikuvat vaihtuvat päivittäin vuorotellen.
- Kuvan kulmassa oma lappu: "Kuva: tekijä · lisenssi", linkit tiedostosivulle ja lisenssiin
  (CC BY-SA vaatii; muutosmerkintä "pienennetty 1920 px leveäksi" näkyy vihjeessä).
- Asetukset → Yleiset → Inbox 0: "Päivän kuva Wikimedia Commonsista" (oletus päällä).
- Generoitu `DailyArt` + `InboxZeroArt` poistettu.

## Inbox 0 -kuva ja torkkumäärät (7.10.2026)

Matin toiveet: päivittäin vaihtuva Inbox 0 -taustakuva ja torkutettujen määrä näkyviin.

- Inbox 0: päivän kuva (`DailyArt`, Helsingin vuorokausi) Sinihetki-väreissä: tunturit, saaristo,
  revontulet, kuunsilta tai lumiset kummut, tumma ja vaalea versio. Sama kuva ei toistu kahtena
  päivänä peräkkäin. Teksti on omalla kortillaan, ei kuvan päällä. Generoitu, ei verkkoa eikä
  lisenssejä; SplitMix64-satunnaisuus, jotta Windows-portti voi piirtää saman kuvan.
- Torkkumäärä: `Torkku`-tunnisteen ketjujen kokonaismäärä (`labels.get` `threadsTotal`, 1 yksikkö) ja
  seuraava herätys aikatunnisteista (1 yksikkö per tarkistettu tunniste). Näkyy sivupalkin
  Torkku-kohdassa (kaikki torkutetut, ei vain lukemattomat), Inbox 0 -kortissa ("4 torkussa · seuraava
  herää ma 8.00") ja valikkopalkissa (kuu ja määrä kuvakkeessa, valikossa rivi, joka avaa Torkun).
  Päivittyy käynnistyksessä, torkutuksen jälkeen ja minuuttipäivityksessä.
## Vaihe 2: Mac mini -daemon (yhdistetty mainiin 7.10.2026, ei vielä asennettu)

Suunnitelma: `docs/design/phase2-daemon.md`.

- Uusi ohjelma `mak8r-daemon` (kohteet `DaemonCore` ja `Mak8rDaemon`) ja launchd-agentti
  `fi.seise.mail.daemon`: `make daemon-install`, `daemon-uninstall`, `daemon-restart`,
  `daemon-status`, `daemon-logs`, `daemon-login EMAIL=…`. Komennot `login`, `logout`, `status`,
  `mode`, `rules check`, `review`, `explain`, `backfill`, `once`. Loki
  `~/Library/Logs/Mak8rMail/daemon.log` (kierrätys 5 Mt × 3), päätökset `decisions.jsonl`.
- Torkut heräävät minuutin tarkkuudella ilman avointa sovellusta. Vain daemon siivoaa menneet
  aikatunnisteet, ja vain kun sen kello vastaa Gmailin kelloa.
- Lajittelu `history.list`illä minuutin välein, säännöt `rules.json`ista (skeema 1, oletukset
  `docs/conventions.md` §2). Luokiteltu ketju saa piilotetun merkin `Lajittelu/Luokiteltu`, uudet
  viestit perivät ketjun lajittelutunnisteet, eikä daemon koskaan poista Matin muutoksia.
  Korjauskierros 30 minuutin välein.
- Varjotila: ensimmäinen asennus lajittelee vain lokiin (`mak8r-daemon review`), kunnes
  `mode sorting live`.
- Kirjautuminen: tokeni 0600-tiedostossa Keychainin sijaan. Muistutus Saapuneisiin 24 ja 3 tuntia
  ennen 7 päivän vanhenemista; vanhentuneena tila säilyy ja daemon jatkaa uuden kirjautumisen
  jälkeen. Puhelimelta kirjautuminen `login --no-browser` + `login --callback`.
- MailCore: `GmailSyncAPI` (history, profile, otsakkeet, viestilista, insert), `TokenSet`in
  suostumusaika ja vanhenemisaika, `login_hint`, kirjautumisen lupatarkistus, `client_secret`
  lähetetään kerran, `messages.insert` hinnastoon (25), `LoopbackReceiver` ei jää jumiin.
- Turvatila: lajittelu menee pois, jos daemon käynnistyy viidesti 10 minuutissa ilman hallittua
  pysäytystä (kaatuminen tai `kill -9`). Hallittu pysäytys (SIGTERM) ei kerrytä laskuria, ja tila
  poistuu itsestään 30 minuutin vakaan ajon jälkeen; `status` kertoo milloin.
- `status` näyttää tilikohtaisesti, milloin lajittelu alkoi varjotilassa ja live-tilassa
  (`--json`: `shadowSince`, `liveSince`), ja varjojakson `backfill --since` -päivän.
- `daemon.json` kirjoitetaan aina 0600, eikä sen oikeuksia koskaan laajenneta. Salaisuudet eivät
  kuulu siihen eivätkä `notify.command`-komentoriville.
- Sopimus: `docs/conventions.md` §0–4, `docs/gmail-quota.md`, `docs/HANDOFF.md` §6, `README.md`.

## Vaihe 1 valmis (5.10.2026)

- Matti testasi torkutuksen buildilla 73 (`h`-kortti, Torkku- ja Käsiteltävät-näkymät), ja
  `phase1-snooze-core` yhdistettiin `main`iin.
- Vaiheen 2 edellytykset muuttuivat (Matti 5.10.2026): OAuth-sovellus jää testitilaan omaan
  käyttöön (ei tietosuojaselostetta eikä julkaisua), joten kirjautuminen vanhenee 7 päivän välein ja
  daemon hoitaa sen. Apple Development -varmennetta ei tarvita: daemonin tokeni on 0600-tiedostossa.

## Vaihe 1 kiintiökorjauksen päälle (5.10.2026)

`main` (palautekorjaukset ja Gmail-kiintiö) yhdistetty `phase1-snooze-core`-haaraan.

- Torkutus ja joukkotoiminnot yhdessä: monen ketjun torkutus on edelleen yksi ⌘Z-askel, ja
  torkutetut rivit pysyvät poissa listalta myös silloin, kun Gmailin haku näyttää ne vielä
  hetken (sama 10 s:n armonaika kuin joukkoarkistoinnissa). Kumottu torkku palaa listalle.
- Päivän laskuri: joukkoarkistointi lasketaan, kun Gmail on vahvistanut sen, ja vain vahvistetut
  Saapuneista poistuneet ketjut. Kesken ajon kumottu joukko ei näy laskurissa, eikä epäonnistunut
  joukko enää pienennä toisen toiminnon lukua.
- `-in:inbox`-haku näyttää juuri arkistoidut ketjut heti; `label:inbox` piilottaa ne kuten
  `in:inbox`.
- Herätys ja kiintiö (`docs/design/gmail-quota.md` §10, P1-1…P1-6): kiintiöajastimen
  `rateLimited` keskeyttää herätyskierroksen ja seuraava yritys on 60 s päästä. Herättäjä lukee
  torkutettujen ketjujen tunnisteet lukuvälimuistin kautta ja hakee tuoreet tunnisteet vain
  ennen muutosta; torkuttaminen lukee aina tuoreena. Tähdellä- ja Torkku-näkymän lukumäärä
  haetaan tunnisteesta (1 yksikkö haun 10:n sijaan). Kiintiösopimus: `docs/gmail-quota.md`
  (linkki myös `docs/conventions.md` §0:ssa).
- Testit: loputkin seinäkelloviiveisiin nojaavat torkku-, herätys- ja listatestit tahdistettu
  porteilla.
- **Käsiteltävät-korjaus.** Gmail palauttaa haulle `in:inbox -label:lajittelu-uutiskirjeet
  -label:lajittelu-ilmoitukset` ei mitään, jos tunnisteita ei ole (Matti tarkisti 5.10.2026), joten
  näkymä näytti "Kaikki käsitelty" täydelläkin postilaatikolla. Mac-sovellus luo nyt tilin
  käynnistyessä puuttuvat `Lajittelu/Uutiskirjeet`- ja `Lajittelu/Ilmoitukset`-tunnisteet
  (näkyvinä) ennen ensimmäistä latausta; kerran, `labels.list` + `labels.create` puuttuvaa kohden.
  Ketjuille niitä asettaa edelleen vain daemon. Jos luonti epäonnistuu, Gmailille lähetetään haku
  ilman puuttuvien tunnisteiden rajausta (käytännössä `in:inbox`, jolla on sama merkitys), ja
  luontia yritetään uudelleen herätyskierroksen jälkeen. `docs/conventions.md` §2–3. Aiempaa
  ohjetta tarkistaa haku käsin ennen ensimmäistä käynnistystä ei enää tarvita.
- **Katselmoinnin korjaukset.** Monen ketjun torkutus noudattaa joukkotoimintojen sääntöjä: ⌘Z
  kumoaa torkutuksen myös kesken ajon (eikä enää vanhempaa toimintoa), ja kun Gmail rajoittaa
  pyyntöjä yhä määräajan jälkeen, aloittamattomia ketjuja ei lähetetä vaan ne palaavat heti
  listalle ("x/y epäonnistui"). Kumottu torkutus palauttaa rivit vain siihen näkymään, josta ne
  lähtivät. Tunnisteiden tarkistus pitää ensimmäistä latausta enintään 3 s; hitaampi tarkistus
  (kiintiö, verkko) lataa listan ensin ilman rajausta ja päivittää sen, kun tarkistus valmistuu.
  `labels.list` yritetään käynnistyksessä vain kerran. Tunnisteet tarkistetaan jokaisen
  herätyskierroksen jälkeen, joten Gmailissa poistettu lajittelutunniste luodaan uudelleen.
  Arkistointi päättää rivin poistumisen samalla säännöllä kuin torkutus (`-in:inbox` ei
  poista, `label:inbox` poistaa). Torkutuskortti seuraa tekstin kokoa.

## Vaihe 1: Mac-käyttöliittymä

Suunnitelma: `docs/design/phase1-mac-ui.md` (osa 3). iPhone-sovellus ennallaan.

**Ennen ensimmäistä käynnistystä.** Tarkista Gmail webissä (Asetukset → Tunnisteet), ettei tilillä
ole Torkku-nimistä tunnistetta millään kirjainkoolla. Jos on, älä käynnistä tätä versiota:
herättäjä ottaisi tunnisteen käyttöön ja herättäisi heti kaikki sen ketjut. Herättäjän saa pois
päältä komennolla `defaults write fi.mak8r.mail seiseWakerDisabled -bool YES` (tulee voimaan
seuraavassa käynnistyksessä); torkuttaminen toimii silti. ~~Tarkista myös, että haku
`in:inbox -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset` antaa saman tuloksen kuin
`in:inbox` (suunnitelma §9, kohdat 0 ja 1).~~ Ei enää tarpeen: sovellus luo tunnisteet itse (ks.
"Vaihe 1 kiintiökorjauksen päälle").

- **Torkutus `h`:lla.** Kortti listan päällä: Tänään myöhemmin, Huomenna, Maanantaina, (Ensi
  viikolla) ja Oma aika…, ajat Helsingin aikaa (”su 4.10. klo 8.00”). Numerot 1–n valitsevat,
  ↑↓/j/k ja ↩ toimivat, esc sulkee. Oma aika avaa päivämäärä- ja aikakentän. Kortin ollessa auki
  muut yhden näppäimen pikanäppäimet eivät tee listalle mitään. Kortti sulkeutuu, kun kohdistus
  siirtyy hakukenttään tai uuteen viestiin (klikkaus, ⌘F, ⌘N), ja kun kirjautumisnäkymä korvaa
  listan. Sama toiminto valikkorivillä
  (Viesti → Torkuta…) ja rivin oikean napin valikossa. Kohde tarkistetaan uudelleen ennen
  torkutusta; ⌘Z kumoaa.
- **Herätys asiakkaassa.** Käynnistyksessä ja 5 minuutin välein (yhteysvirheen jälkeen 60 s)
  `SnoozeWaker` ilman siivousta: asiakas ei poista tunnisteita. Käynnistyksessä herätetyistä
  ketjuista ei tule ilmoitusta. Vanhentuneen kirjautumisen tilit ohitetaan.
- **Näkymät.** Uudet näkymät ”Käsiteltävät” (ensimmäisenä, avautuu oletuksena) ja ”Torkku”
  (viimeisenä) lisätään kerran tiliä kohden; ne ovat tavallisia muokattavia näkymiä. Inbox ja muut
  näkymät ennallaan. ⌥-numerot siirtyvät yhdellä. ”Palauta oletukset” sisältää molemmat.
- **Herätysaika riveillä.** Torkutetulla rivillä kuu ja ”herää ma 8.00”.
- **Tyhjät tilat.** Käsiteltävät tyhjänä: ”Kaikki käsitelty” ja päivän laskuri (”Tänään: 12
  arkistoitua · 3 torkutettua”). Omat tilat tyhjälle Torkku-näkymälle, yhteyskatkolle ja
  epäonnistuneelle lataukselle (”Yritä uudelleen”). Ennen tätä epäonnistunut lataus näytti tyhjältä
  listalta.
- **Päivän laskuri.** Laitekohtainen (`seise-today.json`), ei synkronoidu, nollautuu Helsingin
  keskiyöllä. Laskee vain Saapuneista poistuneet ketjut; ⌘Z pienentää sitä.
- **Ilmoituksen napautus** (Mac) avaa ketjun nykyisessä näkymässä, jos se näkyy siinä.
- **Pikanäppäin.** `h` = Torkuta lisätään asetuksiin kerran, jos `h` on vapaa eikä torkutukselle ole
  muuta näppäintä. Merkintä `seise-migrations.json`issa, joten poistettu sidonta pysyy poissa.
- MailCore: 11 uutta tiedostoa (aika- ja tekstimuotoilu, valikkomalli, herätyssilmukka, laskuri,
  tyhjät tilat, migraatiot), 196 uutta testiä, 673/673 testiä. Upstream-muutokset rajattu
  suunnitelman kohtiin §4–§5.

Avoimet kysymykset (suunnitelma §12) on rakennettu oletuksilla:

1. Oletusnäkymä ”Käsiteltävät”, kuvake `tray.full`, ensimmäisenä (⌥1).
2. Torkku on muokattava näkymä, ei kiinteä kansio; lukematon-luku on torkutettujen lukemattomien määrä.
3. Käynnistyksessä herätetyt ketjut eivät ilmoita, sovelluksen ollessa auki herätetyt ilmoittavat.
4. Herätys käynnistyksessä ja 5 min välein (`followsNextWake = false`); ketju herää enintään noin 5 min myöhässä.
5. ”Ensi viikolla” = sama kuin Maanantaina (piilotettu valikosta).
6. Laskuri on yksi laitekohtainen summa, ⌘Z pienentää, vain Saapuneista poistuneet lasketaan.
7. Onnistumisilmoitus ”Torkutettu – herää …” pidetään.
8. Herätysaika näkyy kaikissa näkymissä, joissa ketjulla on Torkku-tunniste.
9. Jos `-label:`-haku ei toimi: Käsiteltävien haun voi vaihtaa asetuksissa, ei koodimuutosta.
10. Torkku-näkymä Gmailin päivämääräjärjestyksessä.
11. Ei ”herätä nyt” -toimintoa vaiheessa 1.
12. ”Tänään myöhemmin” klo 21 jälkeen ja minuuttien pyöristys ennallaan (ydinsuunnitelma §9).

Matin päätökset 4.10.2026 (suunnitelma §12):

13. Luvun jälkeinen partisiippi on partitiivissa, kun luku ei ole 1 (”Torkuta · 3 valittua”,
    ”3 torkutettua – herää …”, ”Tänään: 12 arkistoitua · 3 torkutettua”); luvulla 1 nominatiivi
    (”1 arkistoitu”).
14. Riveillä, joiden herätys on vähintään viikon päässä, aikaan lisätään ”klo” (”herää 10.10. klo 8.00”).
15. Käsiteltävät- tai Torkku-näkymäksi lasketaan myös näkymä, jonka haku vastaa niiden hakua (esim.
    monistettu näkymä). Se saa ”Kaikki käsitelty” -tilan laskureineen tai ”Ei torkutettuja viestejä”.

Uusi avoin kysymys (suunnitelma §12, Q16): työkalupalkin upstream-teksti on yhä ”3 valittu”, joten
torkutuskortin ”Torkuta · 3 valittua” näkyy samassa näkymässä eri muodossa. Ilmoitetaanko upstreamiin
vai hyväksytäänkö ero?

682/682 testiä.

## Vaihe 1: Snooze-ydin (MailCore)

- Uusi `GmailLabelsAPI` (tunnisteiden listaus/luonti/poisto, ketjujen listaus tunniste-ID:llä, ketjun
  tunnisteet). `LiveGmailClient` toteuttaa sen omassa tiedostossaan; `GmailAPI` ennallaan.
- `LabelDirectory`: tilikohtainen nimi→ID-välimuisti (conventions §0).
- Snooze-moduuli: aikatunnisteen koodaus, Helsingin pikavalinnat, torkutus ja kumoaminen
  (`SnoozeService`), herätys ja siivous (`SnoozeWaker`).
- `MailStore.snooze(until:using:)`: optimistinen, kumottavissa.
- Inbox zero -hakuvakiot (`InboxZero`), ei vielä näkymissä.
- Upstream-tiedostot: `LiveGmailClient`in kolme apufunktiota `private` → `internal`; `MailStore`en
  yksi kumoamistapaus ja yleinen `relabel`-koukku tiedoston loppuun.
- `docs/conventions.md` v2: nimihaku kirjainkoosta riippumatta, luonnin 409/400, modifyn
  400/404-uudelleenyritys, näkyvyydet, herätyksen listaus (`labelIds`, `includeSpamTrash`), sääntö 0,
  siivous vain erääntyneille, aikojen DST-säännöt, hakujen viivamuoto.
- Katselmointi (4 näkökulmaa, havainnot todennettu kahdesti): korjattu URLSession-peruutuksen
  käsittely herätyksessä ja refreshin aikana takaisin ilmestyvä torkutettu rivi; 7 testiaukkoa
  suljettu (mm. uudelleenyritysrajat, 404-haara, kierroksen keskeytys). 474/474 testiä.
- Avoimet päätökset Matille: `docs/design/phase1-snooze-core.md` §9 ja §9.1.
- Matin päätökset 3.10.2026: torkun tunnisteet ovat `Torkku` ja `Torkku/<aika>` (`Snoozed`/`Snooze/`
  korvattu, merkki on myös aikatunnisteiden näyttövanhempi), ja aikatunnisteita siivoaa vain Mac minin
  daemon (`SnoozeWaker.Options.cleansUp`, oletus `false`); asiakasohjelmat eivät poista tunnisteita.
  Kirjattu `docs/conventions.md` §1:een ja suunnitteludokumentin §9.2:een.

## Palautekorjaukset (4.10.2026)

Matin ensimmäisen testikierroksen palaute, suunnitelma `docs/design/feedback-2026-10-04.md`.

- Valitse kaikki -ympyrä listan otsikossa (tyhjä / osittain / kaikki, sama kuin ⌘A).
- Oma forkki: upstreamia ei seurata. Sovellus asennetaan `make install`illa Ohjelmat-kansioon,
  ja Tietoja-ikkunan build-numero on commitien määrä.
- Ääkköset: UTF-8-runko ei enää putoa kokonaan Latin-1:een yhden virheellisen tavun takia,
  väärin merkitty UTF-8 luetaan UTF-8:na (vain länsieurooppalaisille merkistöille), katkenneet
  RFC 2047 -sanat yhdistetään, vastausten ja välitysten vastaanottajat näkyvät luettavina,
  lähtevät otsikot ja liitenimet koodataan standardin mukaan (≤ 78 merkkiä, `filename*`, NFC)
  ja kaikki Latin-1- ja typografiset HTML-merkit puretaan.
- Tekstin koko: Asetukset → Tekstin koko sekä ⌘+ / ⌘− / ⌘0 (lista, lukuruutu, kirjoitus,
  sivupalkki), laitekohtainen.
- Kokouslinkit (toimitus A): Teams-, Zoom- ja Meet-linkit tunnistetaan (myös Safe Links ja
  Proofpoint purettuina, vain sallitut osoitteet), lukuruudussa "Liity …-kokoukseen" ja
  "Kopioi kokouslinkki", listassa merkki esikatselusta tunnistetuille kutsuille.
- Kokouslinkit (toimitus B): listan merkki kaikille Teams-, Zoom- ja Meet-kutsuille Gmail-haulla
  ("Join the meeting now", "Liity kokoukseen nyt", "zoom.us/j", "meet.google.com"; Matti tarkisti
  haut 4.10.2026). Enintään yksi haku minuutissa (30 yksikköä) ja vain kun listaan tulee uusia
  rivejä; 403/429 tai kiintiöajastimen `rateLimited` → 2 min tauko. Ei tunnisteita.
- Testit: joukkotoimintojen ja kokoushakujen ajoitusherkät testit tahdistettu porteilla
  (`CallGate`) seinäkelloviiveiden sijaan; koko sarja vakaa myös kuormassa.

## Korjaus: Gmail-kiintiö (4.10.2026)

- Syy: uusi Google-projekti sai 6 000 yksikköä minuutissa käyttäjää kohden, `threads.get` maksaa
  40 ja jokainen sivun lataus ja minuuttipäivitys haki kaikki 50 riviä uudelleen. Pari latausta
  täytti ikkunan, ja sen jälkeen kaikki kutsut, myös arkistoinnit, saivat 403-virheen ilman
  uudelleenyritystä.
- Kiintiö nostettu 15 000:een (Matti 4.10.2026), `perUserLimit = 15_000`.
- Jokaisella tilillä on oma kuljetuspino: lukuvälimuisti (`historyId`, ei kuluta kiintiötä) →
  kiintiöajastin (liukuva ikkuna, 70 % kokonaisosuus, taustalle 50 %, yhteinen odotus,
  koepyyntö, enintään 7 yritystä / 90 s) → URLSession. Uusi virhe `GmailError.rateLimited` ja
  ilmoitus "Gmail rajoittaa pyyntöjä, yritä minuutin päästä."
- Minuuttipäivitys ilman muutoksia maksaa noin 52 yksikköä aiemman noin 2 850:n sijaan.
- Näkymän lukumäärä säilyy, jos sen haku epäonnistuu.
- Joukkotoiminnot (arkistointi, luettu/lukematon, tähti) yhdellä `messages.batchModify`-kutsulla
  1 000 viestiä kohden; roskakori `threads.trash`illa. Tila listan alla ("Arkistoidaan 140
  ketjua…" → "Arkistoitu 140 ketjua"), ⌘Z kumoaa koko joukon myös kesken ajon.
- Asiakkaiden yhteinen sopimus: `docs/gmail-quota.md`.
- Liitteet: levyvälimuisti viesti- ja osakohtaisesti (uudelleenavaus ei kuluta kiintiötä),
  turvalliset tiedostonimet (NFC, pääte MIME-tyypistä, oma kansio jokaiselle osalle) ja oma
  suomenkielinen ilmoitus jokaiselle virhetyypille hiljaisten paluiden sijaan. Viesti, joka on
  pelkkä liite, saa osatunnisteen `root`, joten sen linkki toimii.

## Vaihe 0: Fork ja ympäristö (valmis 4.10.2026)

- Fork `slemppa/mak8r-mail-public` (`ee5c5a2`) → `mattiseise/seisemail` (yksityinen).
  `upstream`-remotelle push estetty.
- Lisätty `CLAUDE.md`, `docs/HANDOFF.md`, `docs/conventions.md` (v1: snooze, lajittelu,
  inbox zero ja kaksi vaiheen 1 alussa tarkistettavaa Gmail-oletusta).
- Google Cloud -projekti `seisemail`: Gmail API, `gmail.modify`, Desktop-client `seisemail-mac`.
  Testitilassa (Matti testikäyttäjänä, kirjautuminen vanhenee 7 päivän välein): tuotantoon
  julkaisu vaatii kotisivun ja tietosuojaselosteen, tehdään seise.orgiin ennen vaihetta 2.
  4.10.2026 Matti lukee Gmailiaan forkatulla sovelluksella (`make run`).
- Ympäristö: Mac mini M4 / 16 GB, macOS 27.0. Komentorivityökalujen Swift 6.3.2 ei riitä:
  testit kaatuvat (`no such module 'Testing'`) ja release-käännös kaataa kääntäjän → Xcode 27
  asennetaan. Apple Development -varmenne puuttuu vielä.
- Avoin kysymys 1 vastattu: Mac minissä on 16 GB muistia (vaihe 7: noin 8B-malli, muisti
  jaetaan muiden Ollama-käyttäjien kanssa).
