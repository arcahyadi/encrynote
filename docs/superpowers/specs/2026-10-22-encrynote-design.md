# EnCryNote: Desain versi pertama

Status: desain disetujui pengguna pada 2026-10-22 untuk dilanjutkan ke penyusunan rencana. Persetujuan ini bukan izin mulai coding; rencana implementasi dan cara pengerjaannya masih harus disetujui. Review yang sudah dilakukan hanya pada desain, bukan verifikasi keamanan runtime.

## Tujuan dan batas pekerjaan

EnCryNote adalah aplikasi catatan Markdown pribadi yang sepenuhnya offline. Catatan tersimpan terenkripsi secara default. Pengguna memindahkan catatan antarperangkat melalui file ekspor terenkripsi, tanpa akun, server, atau cloud.

Gunakan proyek Flutter yang sudah ada di folder ini. Pekerjaan agent, dokumen, dan perubahan proyek harus tetap di dalam `/Users/arcahyadi/Works/Code/hello_flutter`. Ini tidak berarti aplikasi yang kelak dipasang harus menyimpan catatan di folder kode: data pengguna aplikasi memakai direktori privat aplikasi pada masing-masing OS.

Dokumen ini adalah spesifikasi, bukan rencana implementasi. Jangan menulis kode aplikasi, memasang dependency, atau membuat platform baru sebelum pengguna menyetujui desain lengkap ini. Setelah persetujuan, buat rencana implementasi terlebih dahulu.

## Kesepakatan pengguna

- Nama aplikasi: **EnCryNote**.
- Target awal: **Android dan macOS**. iOS nanti, tidak dikerjakan pada versi ini.
- Full offline dan encrypted; tidak ada akun atau cloud.
- Setup awal meminta password minimal **8 karakter**, lalu **3 pertanyaan dan 3 jawaban yang dibuat sendiri oleh pengguna**. Isi pertanyaan dan jawaban bebas ditentukan pengguna.
- Recovery password aplikasi hanya melalui ketiga jawaban tersebut.
- Ekspor meminta **password khusus file ekspor**, terpisah dari password aplikasi.
- File ekspor **tidak boleh** dipulihkan lewat pertanyaan recovery.
- Impor menerima file ekspor EnCryNote dan file Markdown `.md` biasa, tanpa header, metadata, atau format tambahan yang diwajibkan.
- Editor berupa penulisan sumber Markdown dengan tombol **Write** dan **Preview**, bukan editor yang langsung memformat saat mengetik.
- Auto-lock berada di Settings, dengan pilihan tepat: **Immediately**, **1 minute**, **5 minutes**, **10 minutes**. Tidak ada Never atau durasi kustom.
- Durasi 1/5/10 menit dihitung sejak aktivitas terakhir di aplikasi. Khusus Immediately, aplikasi terkunci saat ditinggalkan atau kehilangan fokus, bukan setelah 0 detik saat sedang dipakai.
- Seluruh UI awal berbahasa **English**. Bahasa lain nanti dapat ditambahkan komunitas.
- Full open source dengan lisensi **MIT**.
- Tidak ada fitur tambahan yang diwajibkan untuk versi pertama.
- Pengguna menyetujui susunan mockup editor: daftar di samping editor pada layar lebar; daftar dan editor terpisah pada Android/layar sempit. Mockup baca-saja itu bukan kode produk atau bukti implementasi enkripsi.

## Keputusan usulan pembuat

Bagian ini berasal dari usulan pembuat, bukan permintaan awal pengguna. Default berikut telah disetujui bersama dokumen desain ini:

1. Password ekspor juga minimal 8 karakter. Setup dan ekspor meminta konfirmasi password untuk mengurangi salah ketik.
2. Recovery yang berhasil meminta password aplikasi baru; tidak pernah menampilkan password lama. Ketiga jawaban harus benar semuanya.
3. Default auto-lock adalah **1 minute**. Setiap cold start tetap meminta password, tanpa mengingat sesi terbuka dari proses sebelumnya.
4. Ekspor mencakup seluruh catatan. Impor menambahkan catatan, tidak mengganti atau menghapus catatan yang sudah ada. Duplikat diperbolehkan, tanpa deduplikasi otomatis.
5. Pada perangkat baru, pengguna melakukan setup password dan tiga pertanyaan milik perangkat tersebut, kemudian mengimpor catatan memakai password ekspor. Password dan recovery perangkat asal tidak dibawa lewat ekspor.
6. Catatan disimpan otomatis. Menghapus satu catatan membutuhkan konfirmasi. Tidak ada reset seluruh data pada versi ini.
7. Teks pertanyaan recovery harus dapat dibaca saat aplikasi terkunci. Karena itu, **teks pertanyaan dan metadata kriptografi berada di header yang tidak dirahasiakan**; jawaban tidak disimpan terbuka. Judul, isi, dan metadata catatan tetap terenkripsi. UI setup perlu menjelaskan agar rahasia ditempatkan di jawaban, bukan di teks pertanyaan.
8. UI memakai Material dan font sistem, mengikuti struktur Flutter yang ada. Sumber Markdown memakai monospace. Nama aplikasi berupa teks; tidak membuat logo baru. Aplikasi mengikuti tema terang/gelap OS, tanpa menambah pengaturan tema tersendiri.

## Ruang lingkup produk

### Catatan dan editor

- Membuat, membuka, mengedit, menyimpan otomatis, dan menghapus catatan setelah konfirmasi.
- Daftar catatan sederhana, urutan pembaruan terbaru di atas.
- Catatan memiliki ID lokal, judul, sumber Markdown, waktu dibuat, dan waktu diubah. Seluruh field ini termasuk payload terenkripsi.
- Write menampilkan sumber Markdown; Preview merender sumber tersebut. Berpindah tampilan tidak mengubah sumber.
- Gunakan parser Markdown yang sudah tersedia sebagai library, bukan parser buatan sendiri. Dukung Markdown biasa tanpa mewajibkan front matter atau ekstensi khusus.
- Jangan mengambil gambar, font, stylesheet, atau konten dari jaringan saat Preview. Gambar eksternal tidak dimuat; tampilkan keterangan bahwa gambar tidak tersedia. Lampiran lokal bukan bagian versi ini.
- Tautan pada Preview ditampilkan sebagai teks yang dapat diseleksi, bukan kontrol mati atau pemicu koneksi jaringan otomatis.
- Tampilan kosong menjelaskan cara membuat atau mengimpor catatan. Loading dan error memiliki keterangan tindakan yang jelas.

### Yang tidak termasuk

Cloud/sync, akun, web app, iOS, Linux, Windows, kolaborasi, AI, folder, tag, pencarian, lampiran, rich-text/live formatting, ekspor plaintext, biometrik, pertanyaan recovery bawaan, recovery email, dan recovery key tambahan tidak dikerjakan.

## Setup, unlock, dan recovery

1. Instalasi baru meminta password dan konfirmasinya, lalu tepat tiga pertanyaan dan tiga jawaban non-kosong.
2. Tidak membatasi isi pertanyaan atau mewajibkan kategori tertentu. Jangan menambah batas panjang minimal jawaban selain tidak kosong.
3. Password peka huruf besar/kecil, tidak dipotong spasinya, dan minimal 8 karakter yang terlihat oleh pengguna. Validasi harus konsisten pada kedua platform dan mendukung Unicode.
4. Untuk jawaban recovery, pangkas spasi di awal/akhir saja; pertahankan kapitalisasi dan spasi di tengah. Jelaskan aturan ini saat setup dan recovery.
5. Ketiga jawaban diproses bersama dalam urutan pertanyaannya, memakai representasi yang tidak ambigu, bukan penggabungan string tanpa pemisah. Jangan menyimpan hash terpisah tiap jawaban atau memberi tahu jawaban mana yang benar.
6. Setup baru dianggap selesai setelah penyimpanan vault terenkripsi berhasil. Kegagalan atau pembatalan tidak meninggalkan status setup selesai tanpa vault yang dapat dibuka.
7. Unlock memakai password aplikasi. Layar terkunci tidak menampilkan judul, cuplikan, atau isi catatan.
8. Recovery menampilkan tiga pertanyaan pengguna. Setelah semuanya benar, pengguna membuat dan mengonfirmasi password aplikasi baru, tanpa kehilangan catatan. Password lama tidak dapat dipakai sesudah perubahan berhasil disimpan.
9. Tidak ada jalur recovery lain. Jika password dan salah satu jawaban yang diperlukan tidak diketahui, aplikasi tidak dapat memulihkan akses.

Jawaban yang dapat ditebak mengurangi keamanan recovery. Ini diterima sebagai batas desain yang dipilih pengguna, bukan alasan untuk mengganti recovery dengan mekanisme lain.

## Penyimpanan dan kriptografi

### Bentuk sederhana yang dipilih

Simpan satu vault berversi di direktori privat aplikasi. Payload berisi kumpulan catatan dan preferensi yang perlu disimpan. Seluruh payload dienkripsi, bukan hanya kolom isi. Tidak ada database pencarian atau indeks judul plaintext.

Alasan: fitur awal hanya membutuhkan daftar dan editor. Vault terenkripsi tunggal menghindari database atau lapisan sinkronisasi yang belum diperlukan. Kekurangannya, penyimpanan ulang mengenkripsi seluruh snapshot; jangan mengklaim cocok untuk vault besar tanpa pengukuran.

### Dua jalur membuka vault lokal

- Buat data-encryption key acak dari sumber acak kriptografis saat setup.
- Usulan algoritma: **AES-256-GCM** untuk authenticated encryption dan **Argon2id** untuk derivasi key dari password maupun gabungan jawaban recovery.
- Data key dibungkus secara terpisah oleh key hasil password dan key hasil ketiga jawaban. Setiap derivasi memakai salt acak sendiri dan konteks penggunaan yang berbeda.
- Jangan menyimpan password, jawaban, atau data key dalam plaintext di file, preferensi OS, log, atau cache. Tidak menyimpan key unlock permanen untuk membuka aplikasi tanpa password.
- Simpan format/version, identitas vault, parameter KDF, salt, nonce, tag autentikasi, wrapped keys, dan teks pertanyaan yang dibutuhkan recovery. Autentikasi konteks header yang relevan agar perubahan header tidak diterima diam-diam.
- AES-GCM memakai nonce 96-bit baru setiap enkripsi dengan key yang sama, tag autentikasi 128-bit, dan data key 256-bit. Jangan memakai nonce tetap atau memakai ulang nonce saat menulis snapshot.
- Library, versi, parameter Argon2id, dan batas resource harus diverifikasi dari dokumentasi resmi serta diukur pada Android dan macOS sebelum implementasi ditetapkan. Jangan mengganti suite kriptografi diam-diam jika dukungan platform tidak sesuai.
- Parser menolak versi/suite yang tidak didukung, panjang field yang salah, ukuran payload berlebihan, dan parameter KDF di luar batas sebelum melakukan alokasi/derivasi yang mahal.
- Pembaca dan penulis memakai batas format/resource yang sama untuk setiap versi, konsisten antara Android dan macOS. Sebelum menerima perubahan atau batch impor, validasi ukuran keseluruhan snapshot beserta envelope hasilnya, bukan hanya ukuran setiap file masukan. Penulis tidak boleh menghasilkan vault/ekspor yang kemudian ditolak pembacanya sendiri. Jika batas terlampaui, pertahankan snapshot sebelumnya dan tampilkan error tanpa memotong isi.

### Integritas dan kehilangan data

- Tidak menulis plaintext ke file sementara. Enkripsi snapshot terlebih dahulu, tulis ke file sementara di direktori yang sama, lalu lakukan penggantian atomik; kegagalan harus mempertahankan vault lama yang valid. Atomik tidak sama dengan tahan crash: flush ciphertext sebelum penggantian dan sinkronkan metadata penggantian/direktori sesuai kemampuan OS/filesystem. Tentukan commit point yang eksplisit, dan pertahankan generasi ciphertext sebelumnya sampai penggantian baru dinyatakan durable atau bisa dipulihkan.
- Serialisasikan seluruh perubahan vault, termasuk autosave, impor, preferensi, recovery password, dan retry, dalam satu urutan commit dengan revisi. Tolak hasil async atau retry yang sudah disusul revisi lain; penyelesaian callback lama tidak boleh menimpa data, credential, atau state UI baru. Jangan menampilkan status tersimpan atau password berhasil diganti sebelum commit point tercapai.
- Jika disk penuh, izin ditolak, dekripsi gagal, atau file korup: tampilkan error yang jelas, jangan membuat vault kosong atau menimpa data secara otomatis.
- Saat lock, segera redaksi UI dan hentikan tindakan pada catatan. Selesaikan penyegelan edit yang tertunda sebelum membuang key; setelah tersegel, hanya ciphertext yang boleh menunggu retry penulisan. Kegagalan penyegelan/penyimpanan tidak boleh membuang perubahan diam-diam.
- Jika ada snapshot catatan terbaru yang sudah tersegel tetapi gagal ditulis, snapshot itu tetap otoritatif selama proses masih hidup. Blokir edit, impor, ekspor, dan perubahan credential sampai penyimpanan direkonsiliasi; jangan membuka cabang edit baru dari versi disk yang lebih lama. Saat unlock atau recovery, autentikasi memakai credential yang terakhir berhasil di-commit, gunakan key untuk memvalidasi snapshot tertunda, dan selesaikan commit snapshot tersebut sebelum mengizinkan mutasi lanjutan.
- Perubahan password baru diaktifkan setelah commit credential berhasil. Rekonsiliasi edit tertunda lebih dahulu; percobaan perubahan password yang gagal tidak boleh meninggalkan retry envelope credential lama yang bisa memulihkan password lama setelah perubahan berikutnya berhasil. Retry tidak boleh membawa wrapper yang kedaluwarsa ke commit baru.
- Penggantian yang terputus harus dapat memuat generasi ciphertext terakhir yang valid, bukan memulai vault kosong. Uji tiap tahap tulis/flush/ganti/pembersihan. Nyatakan batas platform secara jujur: perubahan yang belum berhasil disimpan, khususnya saat disk gagal dan proses kemudian dimatikan, tidak dijamin selamat; jangan mengklaim perlindungan absolut terhadap setiap power loss atau kerusakan storage.
- Buang referensi key, jawaban, password, dan isi catatan dari state/controller ketika tidak lagi diperlukan. Dart/OS tidak menjamin penghapusan fisik seluruh salinan memori; jangan mengklaim zeroization sempurna.
- Lindungi tampilan saat aplikasi berada di background agar snapshot pemilih aplikasi tidak memperlihatkan catatan; verifikasi perilakunya pada platform native.

## Ekspor dan impor

### Ekspor EnCryNote

1. Pengguna yang sudah unlock memilih Export notes, memasukkan password ekspor baru dan konfirmasinya.
2. Buat envelope ekspor tersendiri dengan penanda jenis dan versi. Usulan ekstensi file: `.encrynote`.
3. Payload hanya berisi catatan dan metadata catatan. Enkripsi dengan key dari password ekspor serta salt/nonce baru. Header publik hanya berisi informasi kriptografi minimum dan format/version.
4. **Jangan menyalin vault lokal ke ekspor. Jangan memasukkan data key lokal, password wrapper lokal, recovery wrapper, pertanyaan, jawaban, atau material recovery lokal, termasuk di dalam payload ekspor.** Dengan demikian, ketiga jawaban aplikasi tidak menyediakan jalur membuka ekspor.
5. File disimpan melalui pemilih lokasi native. Tidak ada file sementara berisi Markdown atau password terbuka. Membatalkan ekspor tidak mengubah catatan asal.
6. Lupa password ekspor berarti file itu tidak dapat dibuka. Jika aplikasi asal masih bisa diakses, pengguna dapat membuat ekspor baru; ini bukan pemulihan file ekspor lama.

### Impor file ekspor

- Memerlukan sesi aplikasi yang sudah unlock dan password ekspor yang benar.
- Validasi envelope, parameter KDF, tag autentikasi, ukuran, dan schema sebelum menambahkan catatan apa pun.
- Dekripsi di memori, berikan ID lokal baru untuk catatan yang ditambahkan, lalu simpan ulang memakai enkripsi vault perangkat tujuan.
- Operasi menyimpan seluruh batch secara atomik atau gagal tanpa mengubah vault. Password salah, file rusak, pembatalan, atau save gagal tidak menghapus catatan lama.
- Password aplikasi dan tiga pertanyaan perangkat tujuan tetap milik setup perangkat tujuan.

### Impor Markdown biasa

- Terima file `.md` UTF-8 biasa, termasuk BOM UTF-8 opsional. Tidak perlu format EnCryNote, front matter, password impor, atau metadata khusus.
- Gunakan nama file tanpa ekstensi sebagai judul awal; fallback English: Untitled. Pertahankan isi Markdown; jangan mengambil file lain atau jaringan dari referensi di dalamnya.
- Setelah dibaca, simpan salinannya sebagai catatan terenkripsi. Jangan mengubah atau menghapus file sumber. Jelaskan bahwa file `.md` asli di luar aplikasi tetap plaintext.
- Impor menambahkan catatan; judul/nama file yang sama tidak berarti izin menimpa catatan lain.

### Dialog native dan auto-lock

Pemilih file/lokasi OS tidak boleh menjadi celah agar aplikasi tetap unlock. Untuk ekspor, siapkan ciphertext sebelum membuka dialog lokasi sehingga proses menyimpan ciphertext tidak memerlukan key vault tetap terbuka. Untuk impor, jika kehilangan fokus memicu lock, minta unlock setelah kembali sebelum melanjutkan dekripsi atau perubahan vault. Jangan membuka kembali vault secara otomatis atau menonaktifkan lock selama dialog native.

## Aktivitas dan penguncian

- Aktivitas yang dihitung adalah interaksi pengguna di dalam aplikasi, termasuk mengetik, klik/tap, scrolling, dan navigasi keyboard. Autosave, render, atau pekerjaan background bukan aktivitas pengguna.
- Untuk 1/5/10 menit, simpan tenggat berdasarkan aktivitas terakhir. Background tidak menghentikan hitungannya.
- Saat resume, periksa tenggat sebelum menampilkan catatan atau menerima input yang dapat me-reset timer. Jangan mengandalkan timer background yang mungkin ditunda OS.
- Immediately mengunci ketika aplikasi kehilangan fokus/ditinggalkan. Interaksi dengan dialog Flutter di dalam aplikasi tidak dianggap meninggalkan aplikasi.
- Cold start selalu terkunci. Preferensi auto-lock tidak berarti key boleh disimpan untuk melanjutkan sesi dari proses yang mati.
- Opsi Settings dan labelnya harus tepat sesuai kesepakatan, tanpa tambahan Never atau durasi bebas.

## Offline, bahasa, dan open source

- Tidak ada API, telemetry, analytics, pemeriksaan update, akun, cloud backup buatan aplikasi, atau aset jaringan. Semua fungsi inti harus bekerja tanpa koneksi.
- Release Android tidak memerlukan permission INTERNET. Release macOS tidak memerlukan entitlement network client/server. Izin debug Flutter yang diperlukan hot reload/VM service adalah tooling pengembangan, bukan fitur jaringan produk.
- Cegah backup otomatis vault oleh aplikasi/konfigurasi Android jika platform mengizinkan. Backup yang dikendalikan OS atau pengguna bukan jaminan yang dapat dihapus aplikasi; salinan vault harus tetap ciphertext.
- UI English menjadi sumber string dalam ARB memakai mekanisme localization Flutter. Jangan menanam string UI di widget. Gunakan placeholder terlokalisasi untuk pesan dinamis.
- Versi awal hanya mengiklankan locale English. Kontribusi locale baru melalui ARB dan petunjuk pengujian di CONTRIBUTING; tidak membuat sistem plugin bahasa atau editor terjemahan di aplikasi.
- Source code aplikasi memakai lisensi MIT, disertai LICENSE dan keterangan kontribusi. Periksa kompatibilitas lisensi dependency; MIT untuk kode aplikasi tidak mengubah lisensi dependency.
- Tidak membuat repository remote, mengunggah kode, menandatangani release, atau menerbitkan aplikasi tanpa permintaan terpisah.

## Arah antarmuka

- Nama yang ditampilkan: EnCryNote. Tidak membuat identitas visual atau gambar orang fiktif.
- Permukaan utama: setup, unlock/recovery, daftar catatan, editor Write/Preview, impor/ekspor, dan Settings auto-lock.
- Desktop: daftar catatan di samping editor. Android/layar sempit: daftar dan editor menjadi tampilan terpisah dengan navigasi kembali yang jelas.
- Layout editor mengikuti mockup yang disetujui. Tema ungu berasal dari `Colors.deepPurple` yang sudah ada, bukan persetujuan branding final. Arah awal: ENERGY 1 / RHYTHM 1 / MOTION 1, berorientasi tugas menulis/membaca.
- Seluruh tombol mempunyai aksi nyata; kontrol yang belum dibangun tidak ditampilkan sebagai fitur bekerja. Keadaan kosong, proses berlangsung, error, password salah, dan save gagal harus diperhitungkan.
- Keyboard, fokus yang terlihat, target sentuh, kontras, skala teks, dan keyboard layar Android merupakan bagian penerimaan, bukan tambahan belakangan.

## Area proyek yang perlu dijangkau saat implementasi

- `lib/`: ganti counter dengan alur EnCryNote, logika vault/kriptografi, editor, transfer, lock, dan localization. Pisahkan UI dari operasi kriptografi/penyimpanan yang perlu dites, tanpa menambahkan framework arsitektur yang tidak dibutuhkan.
- `test/`: ganti smoke test counter dan tambahkan pemeriksaan kriptografi, transfer, recovery, penyimpanan, timer, dan widget.
- `pubspec.yaml`, lockfile, konfigurasi localization, dan ARB: dependency minimum yang diperlukan; tidak mengimplementasikan primitif kriptografi sendiri.
- `android/`: nama tampilan, konfigurasi backup, akses file native dan lifecycle; pertahankan konfigurasi debug Flutter yang diperlukan.
- `macos/`: nama produk/jendela dan akses file pilihan pengguna dalam sandbox. Release entitlements saat ini hanya mengaktifkan sandbox; file picker perlu entitlement yang sesuai, bukan mematikan sandbox.
- `README.md`, `CONTRIBUTING.md`, dan `LICENSE`: cara menjalankan, batas keamanan, format/versi ekspor, kontribusi terjemahan, dan lisensi MIT.
- Jangan mengedit artefak `build/`, `.dart_tool/`, atau konfigurasi IDE untuk mengganti kode sumber. Jangan membuat folder iOS sekarang.

## Kriteria penerimaan

1. Instalasi baru tidak dapat melewati setup password minimal 8 karakter dan tepat tiga pertanyaan/jawaban buatan pengguna.
2. Password aplikasi dan gabungan jawaban recovery masing-masing bisa membuka vault melalui jalurnya sendiri. Jawaban yang kurang/salah gagal tanpa membocorkan jawaban mana yang benar.
3. Recovery mengganti password tanpa kehilangan catatan. Tidak ada password/isi/judul/jawaban plaintext pada file data, cache aplikasi, atau log.
4. Ekspor dari Android dapat diimpor di macOS dan sebaliknya. Hanya jalur key dari password ekspor yang membukanya, tanpa fallback password aplikasi atau recovery lokal. Pengguna boleh memilih string password ekspor yang sama dengan password aplikasi; kesamaan nilai bukan jalur recovery tambahan.
5. Pemeriksaan struktur ekspor memastikan tidak ada material wrapper/recovery vault lokal. Perubahan byte ciphertext/header terautentikasi ditolak, tanpa overwrite data.
6. File `.md` biasa bisa diimpor tanpa metadata tambahan; Unicode dan sumber Markdown dipertahankan, file asli tetap tidak berubah, dan duplikat tidak menimpa catatan.
7. Batch impor, autosave berurutan, disk penuh, pembatalan dialog, serta kegagalan penggantian file diuji agar tidak menimpa data lama atau mengaku berhasil sebelum tersimpan.
8. Write/Preview menggunakan sumber yang sama. Merender referensi gambar/tautan eksternal tidak membuat koneksi jaringan atau membaca file arbitrer.
9. Auto-lock diuji dengan clock yang dapat dikontrol: interaksi me-reset durasi; background tidak; resume setelah kedaluwarsa tidak menampilkan isi atau membuka sesi kembali. Immediately dan dialog native diuji pada kedua platform.
10. Aplikasi bekerja dengan jaringan diblokir. UI English berasal dari localization; langkah menambah locale komunitas terdokumentasi.
11. Jalankan format/analyzer, unit/widget tests, build Android/macOS, dan pemeriksaan native yang tersedia. Laporkan pemeriksaan yang tidak bisa dijalankan; jangan menyebut desain/prototipe sebagai bukti keamanan produk.
12. Uji batas ukuran dengan round-trip: snapshot/ekspor yang diterima penulis harus dapat dibaca pada kedua platform; penambahan catatan yang melampaui batas keseluruhan harus gagal tanpa merusak snapshot sebelumnya.
13. Uji gagal-simpan lalu lock, unlock/recovery, dan retry, termasuk callback yang selesai terlambat. Edit tertunda tidak hilang karena memuat snapshot disk lama, dan retry tidak mengembalikan password lama setelah recovery berhasil.
14. Simulasikan penghentian pada tahap tulis/flush/penggantian/pembersihan. Setelah restart, muat generasi terakhir yang valid atau tampilkan error yang tidak menimpa data. Status tersimpan mengikuti commit point, bukan hanya selesainya penulisan buffer.

## Yang diserahkan kepada implementer

Pilih versi dependency dengan dukungan Android/macOS dan lisensi yang sesuai, parameter KDF dan batas input setelah pengukuran, bentuk internal module/file yang paling sederhana, format serialisasi kanonis/AAD, serta detail plugin file picker dan lifecycle. Keputusan ini tidak boleh mengubah kontrak pengguna, menambah fitur, membuat recovery ekspor, atau mengorbankan integritas data.

Belum ada bukti runtime untuk desain ini. Ancaman perangkat yang sudah dikuasai, pembacaan memori proses yang sedang unlock, keylogger, dan screenshot pengguna bukan hal yang dapat dijamin selesai oleh enkripsi file aplikasi.
