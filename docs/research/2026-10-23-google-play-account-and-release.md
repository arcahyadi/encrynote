# Riset: Akun Play Console Berisiko Ditutup & Syarat Rilis Perdana EnCryNote

Tanggal riset: 2026-10-23 (revisi presisi setelah verifikasi primary-source oleh koordinator). Semua klaim berasal dari halaman resmi Google/Android yang di-fetch langsung, bukan snippet pencarian. Halaman tanpa tanggal pembaruan diperlakukan sebagai "berlaku saat diakses", bukan bukti revisi 2026.

Konteks: "akun dev Play Console mau di nonaktifkan" dibaca sebagai **penutupan karena tidak aktif**, bukan penutupan sukarela. Penutupan sukarela tidak diriset di sini.

## Ringkasan eksekutif

1. Penutupan akun tidak aktif punya **dua tugas yang keduanya wajib**: verifikasi kontak (email + telepon) **dan** membuat/mempublikasikan app atau update. Halaman resmi secara eksplisit menyebut **Internal app sharing (IAS)**, **Internal testing**, dan **Closed testing** sebagai cara memenuhi tugas kedua tanpa rilis publik.
2. **IAS menerima APK maupun AAB**, tetapi IAS bukan track rilis: artefaknya di-re-sign dengan kunci IAS terpisah, tidak muncul di app bundle explorer, dan **tidak bisa dipromosikan** ke track testing/produksi. Jalur publikasi track tetap menuntut AAB untuk app baru.
3. Tidak ada tanggal penutupan universal; tenggat ada di email/Play Console dengan pengingat 60/30/7 hari. Tanpa teks peringatan akun ini, statusnya tidak bisa diklaim aman dan IAS tidak bisa dijanjikan berhasil.
4. "Tidak aktif" berbeda dari enforcement dan dari kegagalan verifikasi identitas/kontak/perangkat; konsekuensinya berbeda.
5. Untuk rilis track: AAB wajib, Play App Signing wajib, target API 36 sejak 31 Agustus 2026 (app ini sudah 36).
6. 16 KB: semua app target 35+ wajib mendukungnya; update diblokir mulai 1 Februari 2027. Pemeriksaan statis APK final lulus, dengan batas cakupan yang jelas (lihat §3.5).
7. Privacy policy wajib di Console **dan** di dalam app; bentuk di dalam app boleh **teks lokal**, tidak harus membuka browser. Data safety wajib untuk app yang tayang di closed/open/production.
8. Android developer verification berlaku 30 September 2026 untuk toko partisipan di Indonesia; app Play harus terdaftar package name (app baru otomatis). Sideload/GitHub belum ditegakkan pada fase ini; global 2027.

## 1. Fakta app (dari review kode/artefak lokal, bukan riset web)

- `applicationId` = `com.example.hello_flutter`, `namespace` sama (`android/app/build.gradle.kts`).
- `versionName` 1.0.0-dev.1 / `versionCode` 1; `minSdk` 24; `targetSdk` mengikuti `flutter.targetSdkVersion` (dilaporkan 36).
- Artefak: APK universal release ditandatangani keystore lokal non-debug (baru). Belum ada AAB.
- APK GitHub prerelease belum diunggah; pemilik memilih backup file signing dulu, backup belum dikonfirmasi.
- Launcher masih template Flutter (hasil inspeksi gambar oleh koordinator) dan belum ada dokumen privacy policy khusus di repo.
- Uji fisik low-end (KDF/picker/lifecycle) belum dijalankan.

## 2. Penutupan akun karena tidak aktif

Sumber: <https://support.google.com/googleplay/android-developer/answer/11605267>

### 2.1 Kriteria "tidak aktif"

**Akun tanpa app**
- Dibuat lebih dari satu tahun lalu, dan
- belum pernah mengirim app untuk direview.

**Akun dengan app**
- Dibuat lebih dari satu tahun lalu,
- semua app yang pernah terbit (live, removed, suspended) total installs seumur hidup < 1.000,
- belum memverifikasi nomor telepon dan email kontak Play Developer, dan
- tidak memakai Play Console dalam 180 hari terakhir.

Butir-butir kelompok kedua dibaca sebagai satu set kondisi. Verifikasi kontak saja mematahkan kelompok kedua, tetapi halaman yang sama tetap meminta **dua** tugas untuk mencegah penutupan.

### 2.2 Apa yang terjadi dan kapan

- Akun ditandai untuk ditutup; email dikirim ke pemilik dan status terlihat di Play Console.
- Email memuat langkah yang harus dilakukan **dan tanggal batasnya**.
- Pengingat dikirim pada **60, 30, dan 7 hari**.
- Jika langkah tidak selesai sampai tanggal itu: akun ditutup dan **biaya registrasi tidak dikembalikan**.

Tidak ada tanggal global. "Deadline-nya kapan" hanya bisa dijawab dari email/Console akun tersebut.

### 2.3 Cara mencegah (dua tugas, keduanya wajib)

1. **Verifikasi detail kontak**: Play Console → **Developer account > Account details** → selesaikan verifikasi email dan nomor telepon → **Save**.
2. **Buat dan publikasikan app, atau publikasikan update app**: buat/siapkan app, lalu unggah app bundle atau APK. Untuk yang belum siap publik, halaman resmi menyebut **Internal app sharing**, **Internal testing**, atau **Closed testing** sebagai cara aman tanpa membuat app tersedia umum.

Catatan dari halaman yang sama:
- Akun **bisa menjadi dorman lagi** dan notifikasi baru akan dikirim.
- Langkah yang harus dilakukan dan tanggalnya **ditentukan oleh email peringatan akun tersebut**, bukan oleh artikel umum. Jika peringatan tetap muncul setelah satu langkah dicoba, itu yang harus di-troubleshoot (dan diteruskan ke support lewat Play Console), bukan diasumsikan selesai.

### 2.4 IAS vs Internal testing vs track rilis

Sumber IAS: <https://support.google.com/googleplay/android-developer/answer/9844679>

IAS adalah alat unggah-cepat terpisah, bukan track:

- Menerima **app bundle maupun APK**.
- Version code tidak perlu baru/unik; artefak debuggable boleh.
- Artefak **tidak muncul di app bundle explorer** dan **tidak bisa dimasukkan ke rilis pada track testing atau produksi**.
- Artefak boleh ditandatangani kunci apa pun dan **otomatis di-re-sign dengan Internal App Sharing key** yang dibuat Google per app.
- Link dibatasi 100 pengguna per link dan kedaluwarsa 60 hari setelah unggah.

Konsekuensi:
- APK yang sudah ada **tidak "tidak berguna di dalam Play"**: ia bisa dipakai untuk IAS.
- Namun APK itu tidak bisa menjadi rilis track. Untuk closed/open/production, app baru tetap wajib AAB (<https://support.google.com/googleplay/android-developer/answer/9844279>).
- Karena di-re-sign dengan kunci IAS, APK IAS bukan bukti tanda tangan rilis dan tidak menggantikan uji artefak yang benar-benar dikirim Play.

### 2.5 Konsekuensi penutupan

- Akun ditutup; biaya registrasi tidak kembali.
- Laporan, statistik, dan insight di Play Console tidak tersedia **kecuali akun di-reinstate** (<https://support.google.com/googleplay/android-developer/answer/9899234>, bagian "Dormant Accounts").
- Penutupan akun dorman **tidak menghalangi** pembuatan akun baru di masa depan (halaman yang sama).
- Halaman dorman tidak menyatakan apakah app yang sudah terbit ikut dihapus. Jangan mengklaim salah satunya.

### 2.6 Bedanya dengan enforcement dan verifikasi

| Hal | Pemicu | Akibat | Sumber |
|---|---|---|---|
| Dorman/tidak aktif | Kriteria §2.1 | Akun ditutup, fee hangus, boleh buat akun baru | 11605267, 9899234 |
| Enforcement | Pelanggaran kebijakan/DDA | App dihapus; terminasi memutus publikasi dan **akun terkait ikut disuspend permanen**; akun baru ikut diterminasi tanpa refund | 9899234 |
| Verifikasi gagal | Identitas/kontak/perangkat tidak selesai | Kehadiran developer dan app bisa dihapus; tidak bisa republish sampai terverifikasi | 10841920, 10788890 |

### 2.7 Yang harus dipasok pemilik akun

- Teks/SS peringatan sebenarnya (redacted), menentukan dorman, enforcement, atau verifikasi.
- Tipe akun: Personal atau Organization.
- Tanggal pembuatan akun (sebelum/sesudah 13 November 2023).
- Tanggal batas yang tertulis di email/Console.
- Apakah ada app yang pernah live dan berapa total installs.

## 3. Syarat publikasi pertama

### 3.1 Format: track vs IAS

- Track (internal/closed/open/production): app baru wajib **AAB** sejak Agustus 2021 (<https://support.google.com/googleplay/android-developer/answer/9844279>, <https://developer.android.com/guide/app-bundle>).
- IAS: **AAB atau APK** diterima, dengan konsekuensi §2.4 (<https://support.google.com/googleplay/android-developer/answer/9844679>).
- APK tetap relevan untuk distribusi di luar Play dan untuk pengujian lokal.

### 3.2 Play App Signing dan implikasi GitHub vs Play

Sumber: <https://support.google.com/googleplay/android-developer/answer/9842756>, <https://developer.android.com/google/play/app-updates>

- Dua kunci: **upload key** (dipegang developer, RSA ≥2048, menandatangani AAB yang diunggah) dan **app signing key** (dipakai menandatangani APK yang dikirim ke pengguna).
- App baru otomatis memakai penandatanganan hybrid "quantum-ready" dengan kunci buatan Google. Opsi memakai kunci sendiri tersedia **sebelum ada rilis yang di-rollout ke open testing atau production**.
- **Upload key** yang hilang/bocor **bisa di-reset** lewat Play Console.
- **App signing key yang diimpor ke Play App Signing tetap dipegang Google sebagai salinan.** Kehilangan K lokal dalam skenario itu **bukan** otomatis kehilangan kemampuan update di Play; yang hilang adalah kemampuan menandatangani APK GitHub secara mandiri dengan K. Alternatifnya: unduh **signed universal APK** dari Play Console (ditandatangani app signing key Play) untuk distribusi di luar Play.
- Yang benar-benar tidak bisa dipulihkan adalah kunci yang dikelola sendiri **tanpa** Play App Signing lalu hilang. Jangan mencampur dua skenario ini.
- Android hanya menerima update jika `applicationId` sama **dan** sertifikat sama (atau ada proof-of-rotation). Sertifikat berbeda → harus uninstall dulu.

Catatan penting soal perpindahan kanal: uninstall menghapus data app, tetapi EnCryNote punya ekspor catatan. Dengan ekspor lebih dulu, kehilangan catatan **tidak otomatis**; yang hilang adalah kenyamanan dan data yang tidak sempat diekspor. Tetap dokumentasikan bahwa pindah kanal = reinstall.

Opsi yang perlu dipilih sadar sebelum rilis Play pertama:
1. Pakai K sebagai app signing key Play (harus sebelum rollout open testing/production). Backup K tetap wajib.
2. Biarkan Google memegang app signing key, lalu distribusikan **signed universal APK dari Play Console** di GitHub.
3. Dua kanal dengan kunci berbeda; dokumentasikan reinstall + ekspor.

### 3.3 Akun personal yang dibuat setelah 13 November 2023

Sumber: <https://support.google.com/googleplay/android-developer/answer/14151465>

Angka **saat ini**: closed test dengan **minimal 12 tester** yang **opt-in terus-menerus minimal 14 hari**; hitungan harus berurutan (opt-out lalu opt-in mengulang). Setelah itu ajukan **production access** lewat Dashboard (review biasanya ≤7 hari). **Open testing baru tersedia setelah production access.** Internal testing tidak memenuhi syarat ini; IAS juga bukan closed test.

Berlaku hanya untuk akun **personal** yang dibuat setelah tanggal itu. Akun Organization tidak terkena syarat ini, tetapi wajib D-U-N-S dan verifikasi organization.

### 3.4 Target API level

Sumber: <https://support.google.com/googleplay/android-developer/answer/11926878>

- Sejak **31 Agustus 2026**: app baru dan update harus target **Android 16 (API 36)** atau lebih tinggi.
- Halaman itu menyebut perpanjangan ke **1 November 2026** dalam konteks app existing yang belum patuh. Halaman tersebut **tidak** menetapkan secara eksplisit apakah app baru bisa memakai perpanjangan; jangan mengklaim salah satunya.
- Ketersediaan app existing dibahas terpisah dari syarat submit/update: app existing harus target **API 35** agar tetap tersedia bagi pengguna baru di perangkat yang OS-nya lebih baru dari target app. App yang target-nya **API 34 atau lebih rendah** (untuk mobile) hanya tersedia di perangkat dengan OS sama atau lebih rendah dari target API app, sehingga berhenti muncul bagi pengguna baru di OS yang lebih tinggi.

Status EnCryNote: target 36 → memenuhi syarat yang berlaku saat ini. Verifikasi nilai pada AAB final, jangan hanya konfigurasi.

### 3.5 16 KB native library page alignment

Sumber: <https://developer.android.com/guide/practices/page-sizes> (diperbarui 2026-10-16)

Kata-kata sumber: "all apps targeting Android 15 (API level 35) and higher must support 16 KB memory page sizes on 64-bit devices on Google Play" dan "Starting February 1, 2027, if your app updates don't support 16 KB memory page sizes, you won't be able to release these updates."

Yang bisa dan tidak bisa disimpulkan:
- Kewajiban dukungan 16 KB berlaku untuk **semua** app target 35+, bukan hanya update.
- Sumber hanya menyatakan sanksi tanggal untuk **update** (1 Februari 2027). Sumber **tidak** menyatakan app baru hari ini otomatis aman/dikecualikan, dan **tidak** menyatakan app baru diblokir hari ini. Jangan membuat inferensi ke arah mana pun.
- Pengecualian "permanently private apps" (app yang dibatasi untuk pengguna di organisasi tertentu dan hanya didistribusikan internal) disebut pada kebijakan **Target API level** (<https://support.google.com/googleplay/android-developer/answer/11926878>), bukan pada halaman 16 KB. Halaman page-sizes yang di-fetch tidak memuat pengecualian tersebut untuk 16 KB.

Pemeriksaan statis yang sudah dilakukan (koordinator, artefak lokal):
- APK final SHA-256 `b72473c70fdd52cf8eb67780b67faed44960ff7e769cff267a2551a680e5ca94`, build commit `57c1dd56366eb612455e267c3f4b7f58326adf53`.
- Enam `.so` 64-bit (`arm64-v8a`, `x86_64`: `libapp.so`, `libdartjni.so`, `libflutter.so`) memiliki PT_LOAD align ≥ 16 KB (16384/65536).
- `zipalign -c -P 16 -v 4` exit 0, "Verification successful".
- Log/JSON: `.superpowers/sdd/google-play-research-20261023/local-apk-alignment.json`, `zipalign-16k.log`.

Batas cakupan: **statis saja**. Belum ada uji runtime di perangkat/emulator 16 KB, belum ada pemeriksaan RELRO, dan belum ada bukti untuk APK yang dihasilkan Play dari AAB. Play Console juga punya peringatan kompatibilitasnya sendiri; status final tetap ditentukan di sana.

### 3.6 Privacy policy dan Data safety

Sumber: <https://support.google.com/googleplay/android-developer/answer/10144311>, <https://support.google.com/googleplay/android-developer/answer/9859455>, <https://support.google.com/googleplay/android-developer/answer/10787469>

Privacy policy:
- **Semua app wajib** punya privacy policy; kalimat resmi: "Apps that do not access any personal and sensitive user data must still submit a privacy policy."
- Di Play Console: wajib URL publik, aktif, tidak di-geofence, **bukan PDF**, tidak bisa diedit.
- Di dalam app: sumber menyebut "a privacy policy link **or text** within the app itself". Untuk app offline, **teks kebijakan lokal di dalam app sudah memenuhi**; tidak perlu membuka browser atau menambah dependensi jaringan.
- Isi minimal: info developer + kontak privasi, jenis data, pihak penerima, cara pengamanan, retensi/penghapusan, dan label jelas sebagai privacy policy.
- Kebijakan penghapusan akun hanya relevan jika app punya akun. EnCryNote tanpa akun tidak terkena ini, tetapi keputusan "tanpa akun" harus konsisten.

Data safety:
- Wajib untuk app yang tayang di **closed, open, atau production**. App yang **hanya** aktif di internal testing dikecualikan.
- "Collect" = data dikirim **keluar perangkat**; pemrosesan yang hanya di perangkat tidak perlu dideklarasikan.
- App tanpa koleksi data tetap mengisi form dan tetap butuh privacy policy; isinya boleh "tidak ada data dikumpulkan/dibagikan".

### 3.7 Deklarasi App content lain

Sumber: <https://support.google.com/googleplay/android-developer/answer/9859455>

Ads; target audience & content; content ratings (app "Unrated" bisa dihapus); sign-in details (hanya jika dibatasi login); News/Magazine; COVID-19; permissions declaration (hanya izin sensitif); registrasi package name (§3.8).

### 3.8 Verifikasi akun, perangkat, dan registrasi package name

Sumber: <https://support.google.com/googleplay/android-developer/answer/10841920>, <https://support.google.com/googleplay/android-developer/answer/14316361>, <https://support.google.com/googleplay/android-developer/answer/16984799>, <https://developer.android.com/developer-verification>

- **Identitas**: personal = dokumen identitas pemerintah; organization = D-U-N-S + dokumen organisasi. Harus selesai sebelum submit app.
- **Kontak**: email dan nomor telepon developer serta kontak internal harus diverifikasi. Untuk akun personal, verifikasi nomor telepon baru bisa setelah verifikasi identitas dan perangkat.
- **Perangkat**: akun personal baru wajib verifikasi akses perangkat Android fisik non-root (minimal Android 10) lewat aplikasi Play Console mobile.
- **Registrasi package name**: efektif **30 September 2026**, semua paket Play harus terdaftar; app baru otomatis didaftarkan saat dibuat. Paket tak terdaftar per tanggal itu dihapus dari Play.
- **Android developer verification (Indonesia)**: mulai **30 September 2026** untuk instalasi dari toko partisipan di Brazil, Indonesia, Singapore, Thailand pada perangkat certified Android 7+. FAQ menyatakan sideload/unduhan langsung **belum** ditegakkan pada fase ini; global **2027**. ADB tidak terpengaruh.

## 4. Checklist blocker dan unknown

| Item | Status | Dampak | Aksi |
|---|---|---|---|
| Teks peringatan + jenis (dorman/enforcement/verifikasi) | **Unknown** | Menentukan seluruh jalur | Minta SS redacted + tipe akun + tanggal dibuat + deadline |
| Tipe akun (Personal/Organization) | **Unknown** | Menentukan syarat 12 tester & dokumen | Cek Settings > Developer account |
| Verifikasi email + telepon kontak | **Unknown** (Console tidak diakses) | Syarat wajib anti-closure | Selesaikan di Account details |
| Registrasi package name Play | Otomatis untuk app baru | Paket tak terdaftar dihapus setelah 30 Sep 2026 | Cek halaman Android developer verification |
| Format rilis track | **Belum ada AAB** | APK tidak diterima untuk track app baru | Build AAB bertanda tangan upload key |
| Jalur IAS untuk APK yang ada | **Tersedia secara mekanisme** | Bisa memenuhi tugas aktivitas tanpa rilis publik | Jangan diasumsikan berhasil untuk akun ini; uji terhadap peringatan nyata |
| `com.example.hello_flutter` | **Risiko** | Nama paket permanen setelah unggah; tidak ada dokumentasi resmi saat ini yang menyatakan penolakan | Uji upload lebih awal; ganti `applicationId` sebelum unggah pertama bila perlu |
| Kunci signing | **Backup belum dikonfirmasi** | Kehilangan upload key = reset; kehilangan K lokal = tidak bisa tanda tangan GitHub mandiri | Konfirmasi backup offline |
| Keputusan kunci Play vs GitHub | **Belum diputuskan** | Pindah kanal = reinstall (data bisa diekspor dulu) | Pilih §3.2 opsi 1/2/3 |
| Target API 36 | Terpenuhi (klaim konfigurasi) | Tidak ada | Verifikasi di AAB final |
| 16 KB alignment (statis) | **Lulus statis** pada APK final SHA `b724…e5ca94` | Kewajiban tetap berlaku; sanksi update 1 Feb 2027 | Ulangi pada APK hasil AAB; uji runtime 16 KB |
| Privacy policy | **Unknown di Console**; belum ada dokumen khusus di repo | Wajib bahkan tanpa data | Siapkan URL publik + teks lokal in-app |
| Data safety | **Unknown di Console** | Wajib untuk closed/open/production | Isi "no data collected" bila benar |
| Content rating, ads, target audience | **Unknown di Console** | Review tertahan / Unrated bisa dihapus | Isi di App content |
| 12 tester × 14 hari (jika personal pasca 13 Nov 2023) | **Belum ada** | Tidak bisa production access | Rekrut 12 tester, jalankan closed test |
| Store assets (ikon, screenshot, feature graphic) | **Belum ada**; launcher masih template Flutter | Listing tidak layak / review berisiko | Siapkan aset nyata (belum dibuat) |
| Uji fisik low-end (KDF/picker/lifecycle) | **Belum dijalankan** | Kualitas rilis tidak terbukti | Jalankan sebelum closed test |
| APK GitHub prerelease | Belum diunggah | Tidak terkait Play | Selesaikan backup dulu |

## 5. Langkah segera vs kesiapan produksi

**A. Menghentikan penutupan akun (terpisah dari kesiapan rilis)**
1. Buka Play Console → **Account details** → verifikasi email dan nomor telepon → Save.
2. Selesaikan verifikasi identitas dan perangkat bila belum (prasyarat nomor telepon untuk akun personal).
3. Buat app di Play Console (sekaligus memicu registrasi package name otomatis).
4. Penuhi tugas aktivitas memakai jalur yang **disebut halaman resmi**: IAS (APK/AAB apa pun), atau Internal testing/Closed testing (butuh AAB untuk track). *Saran, bukan syarat Google:* rollout ke Internal testing dengan minimal satu tester memberi bukti rilis yang lebih jelas daripada artefak IAS yang tidak bisa dipromosikan.
5. Konfirmasi peringatan hilang dari Home/Console; simpan bukti (tanggal, screenshot). Jika tetap muncul, troubleshoot terhadap isi email peringatan dan hubungi support lewat Play Console.
6. Akun bisa dorman lagi; tidak ada interval resmi yang dijamin selain kriteria §2.1.

**B. Kesiapan produksi (setelah A, jangan dicampur)**
1. Putuskan jalur signing (§3.2) dan backup kunci.
2. Siapkan privacy policy URL + teks in-app; isi Data safety, ads, target audience, content rating.
3. Siapkan store assets nyata (ikon, screenshot, feature graphic); launcher template belum memadai.
4. Jalankan uji fisik low-end; perbaiki temuan.
5. Jika akun personal pasca 13 Nov 2023: closed test 12 tester × 14 hari, lalu ajukan production access.
6. Verifikasi target API 36 dan 16 KB pada APK hasil AAB; jalankan uji runtime 16 KB bila memungkinkan.
7. Naikkan `versionCode` setiap unggahan.

## 6. Ketidakpastian

- Tidak ada verifikasi bahwa akun ini dorman, atau bahwa IAS/upload minimal akan diterima. Halaman resmi menyebut langkahnya; keputusan tetap di Google.
- Tidak ada tanggal penutupan yang bisa dikutip tanpa email akun.
- Tidak dikonfirmasi apakah penutupan dorman menghapus app yang sudah terbit.
- Tidak dikonfirmasi apakah IAS/Internal testing selalu menutup peringatan untuk akun yang belum pernah submit review; halaman resmi tetap menyebutnya sebagai jalur yang sah, jadi perbedaan (jika ada) harus diselesaikan lewat peringatan/support akun tersebut.
- Tidak ada halaman resmi saat ini yang menyatakan `com.example` ditolak; ini risiko operasional.
- 16 KB: lulus statis pada APK final; belum ada bukti runtime, RELRO, atau APK hasil AAB.
- Halaman 11605267 tidak menampilkan tanggal pembaruan.
- Belum diriset: penutupan sukarela, banding dorman, biaya/pajak Indonesia.

## 7. Sumber resmi

- Penutupan akun tidak aktif: <https://support.google.com/googleplay/android-developer/answer/11605267>
- Enforcement & dormant accounts: <https://support.google.com/googleplay/android-developer/answer/9899234>
- Mulai dengan Play Console: <https://support.google.com/googleplay/android-developer/answer/6112435>
- IAS (APK/AAB, re-sign, tidak promotable): <https://support.google.com/googleplay/android-developer/answer/9844679>
- Setup testing track: <https://support.google.com/googleplay/android-developer/answer/9845334>
- Syarat testing akun personal baru: <https://support.google.com/googleplay/android-developer/answer/14151465>
- Verifikasi perangkat: <https://support.google.com/googleplay/android-developer/answer/14316361>
- Verifikasi identitas/kontak: <https://support.google.com/googleplay/android-developer/answer/10841920>
- Tipe akun: <https://support.google.com/googleplay/android-developer/answer/13634885>
- Play Console Requirements: <https://support.google.com/googleplay/android-developer/answer/10788890>
- AAB wajib untuk track: <https://support.google.com/googleplay/android-developer/answer/9844279>
- Tentang App Bundle: <https://developer.android.com/guide/app-bundle>
- Play App Signing: <https://support.google.com/googleplay/android-developer/answer/9842756>
- Cara update app & tanda tangan: <https://developer.android.com/google/play/app-updates>
- Target API: <https://support.google.com/googleplay/android-developer/answer/11926878>
- 16 KB page size: <https://developer.android.com/guide/practices/page-sizes>
- Prepare for review (App content): <https://support.google.com/googleplay/android-developer/answer/9859455>
- User Data policy: <https://support.google.com/googleplay/android-developer/answer/10144311>
- Data safety: <https://support.google.com/googleplay/android-developer/answer/10787469>
- Buat & setup app: <https://support.google.com/googleplay/android-developer/answer/9859152>
- Registrasi package name Play: <https://support.google.com/googleplay/android-developer/answer/16984799>
- Registrasi package name non-Play: <https://support.google.com/googleplay/android-developer/answer/16761053>
- Android developer verification: <https://developer.android.com/developer-verification>
- Jalur Play Console: <https://developer.android.com/developer-verification/guides/google-play-console>
- FAQ verifikasi (Indonesia, sideload): <https://developer.android.com/developer-verification/guides/faq>
- Aturan applicationId: <https://developer.android.com/build/configure-app-module>
