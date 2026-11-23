# نبض السنة – självständig Instagram-agent (@nabdal_sunnah)

Allt körs i molnet på **GitHub Actions**. Ingen dator behöver vara påslagen.

| Vad | När (svensk tid) | Workflow |
|---|---|---|
| Hadith-bild (verifierad mot sunnah.com) | varje dag 18:00 | `.github/workflows/hadith.yml` |
| Reel 20–30 s från innehållsbanken | varje dag 12:00 och 19:00 | `.github/workflows/reels.yml` |
| Daglig mejlrapport | efter 19:00 | `reels.yml` |
| Reels-produktion (nya länkar → transkribering → klipp → bank) | var 3:e timme | `.github/workflows/produce.yml` |
| Felmejl direkt när något misslyckas + veckovis säkerhetskopia | vid fel / måndagar 04:00 | `.github/workflows/ops.yml` |

Sommar- och vintertid hanteras automatiskt (tidszonen Europe/Stockholm).

## Det enda du behöver göra
Lägg till godkända YouTube-länkar i **`reels/links.txt`** (öppna filen på GitHub → pennan → klistra in → *Commit changes*).
Använd bara videor som du äger eller har tillstånd att återpublicera.

## Databas och lagring (allt i repot, versionshanterat)
| Data | Var |
|---|---|
| Hadith-banken | `hadiths.js` |
| Publicerade hadither | `posted.log` |
| Innehållsbank: analyserade videor + alla klipp och deras status | `reels/bank.json` |
| Publicerade Reels (datum, klipp, media-id, tid, länk) | `reels/published.log` |
| Fel / skickade rapporter | `reels/errors.log`, `reels/report.log` |
| Huvudbrytare | `reels/config.json` → `"publish"` (Reels på/av), `"producer"` (`"cloud"` eller `"mac"`) |
| Färdiga Reels-videor | release **reels-bank** |
| Originalvideor + transkript | release **reels-sources** |
| Säkerhetskopior (26 veckor) | release **backups** |

Varje ändring blir en commit, så hela historiken finns kvar och kan återställas.

## Skydd mot dubbelpublicering
- Endast GitHub publicerar. Datorn har inget publiceringsjobb.
- Varje hadith och varje klipp loggas och publiceras aldrig igen. Varje tid (12:00/19:00) publiceras max en gång per dag.
- `"producer"` i `reels/config.json` bestämmer vem som producerar klipp – bara en åt gången.

## Hemligheter (aldrig i koden)
GitHub → repot → **Settings → Secrets and variables → Actions**:
`IG_ACCESS_TOKEN`, `IG_USER_ID`, `SMTP_USER`, `SMTP_PASS`, `NOTIFY_EMAIL`.
Byter du Instagram-token: uppdatera `IG_ACCESS_TOKEN` där (och i din lokala `config.env` om du har en).

## Utveckla från macOS eller Windows
Inget behöver installeras för att ändra och testa:
1. **I webbläsaren:** öppna repot och tryck `.` (punkt) → en editor (github.dev) öppnas. Ändra, och välj *Commit*.
2. **Testa i molnet:** fliken **Actions** → välj workflow → **Run workflow**:
   - *Reels* → `dry-run` visar nästa klipp och beskrivning utan att publicera.
   - *Reels-produktion* → `test` kör ett självtest och renderar ett testklipp (ladda ner under *Artifacts*).
   - *Daglig hadith-post* → `dry-run`.
3. **Lokalt (valfritt):** installera Git och Ruby (Windows: rubyinstaller.org, macOS: finns redan), klona repot,
   kopiera `config.example.env` till `config.env` och fyll i tokens. `config.env` laddas aldrig upp.
   För videoproduktion lokalt behövs även FFmpeg, Google Chrome, yt-dlp och whisper.cpp.

## Regler som är inbyggda
- Hadither: endast sahih/hasan från `hadiths.js`, ordagrant kontrollerade. Inget genereras fritt. Inga bilder av profeten ﷺ.
- Reels: undertexterna är exakt Koran-text från Tanzil (`reels/data/`, oförändrad). Whisper används bara för att hitta vilka verser
  som reciteras och när. Klipp börjar och slutar alltid på hela verser. Ingen musik. Källa och läsare anges.
- Om Instagram-API:t spärras publiceras inget och felet syns i mejl. Produktionen fortsätter ändå.

## Filer
| Fil | Vad den gör |
|---|---|
| `post.rb`, `template.html`, `render.sh`, `hadiths.js` | Hadith-bilden |
| `reels/reelmaker.rb` | Produktion: länkar → video → transkript → klipp → bank |
| `reels/quran.rb`, `reels/analyze.rb` | Matchar talet mot Koran-texten, väljer 20–30 s med hela verser |
| `reels/render.rb`, `reels/overlay.html` | Redigerar 1080×1920 med undertexter och logga |
| `reels/publish.rb` | Publicering 12:00/19:00 + daglig rapport |
| `reels/alert.rb`, `reels/backup.rb` | Felmejl och säkerhetskopia |
| `install-reelmaker.sh` | Reserv: produktion på en Mac (`./install-reelmaker.sh --remove` stänger av) |
