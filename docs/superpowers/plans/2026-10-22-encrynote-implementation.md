# EnCryNote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task, only after the user approves this plan and chooses the execution method. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Membangun EnCryNote offline untuk Android dan macOS, dengan catatan Markdown terenkripsi, recovery tiga jawaban, dan transfer antarperangkat melalui ekspor berpassword terpisah.

**Architecture:** Satu vault terenkripsi berversi, dengan key data yang dibungkus terpisah oleh password aplikasi dan jawaban recovery. `NoteSession` menjadi pemilik state dan urutan commit; widget Material hanya memakai API sesi, sedangkan bridge native menangani file pilihan pengguna, commit filesystem, dan privacy shield. Ekspor memiliki envelope sendiri tanpa material recovery lokal.

**Tech Stack:** Flutter/Dart yang sudah ada; `cryptography` 2.9.x, `path_provider` 2.1.x, `flutter_markdown_plus` 1.0.x, `characters` yang sudah ada di lockfile, localization ARB Flutter, `ChangeNotifier`, Kotlin/Swift melalui `MethodChannel`. Tidak memakai database, state-management package, atau file-picker package.

**Spec:** `docs/superpowers/specs/2026-10-22-encrynote-design.md` (disetujui untuk perencanaan).

> **Safety supersession (2026-10-23, Task 8 fix round 2):** the commands written
> into this frozen plan predate a known data-loss hazard. Any
> `flutter test integration_test/...` command here is subordinate to the current
> rule: add `--no-uninstall` and use only an owned or disposable device or
> emulator holding no personal vault. The test build reuses the product
> application id (`com.example.hello_flutter`), and the tool uninstalls that
> package by default, deleting its private `vault.enc`/`vault.previous`. Do not
> run the plan's device commands as literally written. The authoritative,
> current commands live in `README.md`, `CONTRIBUTING.md`, and
> `docs/testing/native-checks.md`. The plan text itself is left unchanged as a
> historical record.


**Status:** Rencana belum disetujui untuk dieksekusi. Tidak ada langkah implementasi yang sudah dikerjakan. Contoh kode di dokumen ini adalah rancangan test, bukan perubahan source aplikasi.

## Global Constraints

- Nama aplikasi: **EnCryNote**. Target awal: **Android dan macOS**. iOS nanti, tidak dikerjakan pada versi ini.
- Pekerjaan agent tetap di `/Users/arcahyadi/Works/Code/hello_flutter`; tidak membuat worktree di luar folder ini. Data aplikasi yang benar-benar dipasang memakai direktori privat OS sesuai spec.
- Full offline dan encrypted; tidak ada akun atau cloud. Tidak ada telemetry, aset jaringan, atau pengambilan gambar/file arbitrer dari Markdown.
- Password aplikasi dan ekspor minimal **8 karakter** yang terlihat, peka kapitalisasi, tanpa trim. Pertanyaan/jawaban buatan pengguna tepat tiga, non-kosong; jawaban di-trim di tepi saja.
- Recovery password aplikasi hanya melalui ketiga jawaban. File ekspor **tidak boleh** dipulihkan lewat pertanyaan recovery.
- Auto-lock hanya **Immediately**, **1 minute**, **5 minutes**, **10 minutes**; default **1 minute**. Durasi berbasis aktivitas terakhir; Immediately berarti kehilangan fokus/ditinggalkan. Cold start selalu locked.
- Editor memakai **Write** dan **Preview**. Impor menerima `.md` UTF-8 biasa dan ekspor `.encrynote`; ekspor semua catatan, impor menambah tanpa overwrite/deduplikasi.
- Seluruh UI awal **English**, string UI melalui ARB, tema mengikuti OS, kode aplikasi berlisensi **MIT**. Tidak membuat logo baru atau locale yang belum diterjemahkan.
- Pertahankan `sdk: ^3.13.5`, package Dart `hello_flutter`, namespace native yang sudah ada, dan macOS deployment target 12.0. Android memakai minimum SDK 24 atau nilai Flutter bila lebih tinggi, sesuai dependency direktori privat. Ubah nama tampilan/produk beserta referensinya, bukan rename semua identifier.
- Jangan menurunkan parameter kriptografi diam-diam, menulis plaintext ke cache/temp, menganggap save atomik sudah durable, atau melanjutkan mutasi setelah kegagalan save.
- Jangan mengedit output `build/` atau `.dart_tool/` sebagai source. Test yang butuh file sementara memakai lokasi test di dalam proyek dan hanya membersihkan file yang test itu buat.
- Saat eksekusi nanti: test gagal dahulu, implementasi minimum, test lulus, commit per task. Belum ada Git; inisialisasi lokal menjadi bagian Task 1 setelah izin eksekusi, tanpa remote/push.

## Review Focus

1. Pemilih file Android dapat menyalin `.md` ke cache plaintext; baca URI langsung ke memori secara terbatas, tanpa copy/cache atau grant permanen (Task 7).
2. Callback lama setelah lock/recovery dan retry gagal-simpan dapat mengembalikan data/password lama; satu urutan revisi dan snapshot pending otoritatif harus mencegahnya (Task 3).
3. BOM, UTF-8 rusak, emoji gabungan, spasi password, dan gabungan jawaban ambigu harus diproses konsisten tanpa mengubah Markdown atau melemahkan recovery (Tasks 1 dan 7).
4. Vault utama rusak atau password salah tidak boleh dianggap instalasi baru maupun alasan mencoba wrapper password lama pada backup (Tasks 2 dan 4).
5. Resume setelah timer OS tertunda, rotasi/lifecycle Android, serta dialog file native tidak boleh menampilkan catatan sebelum deadline/unlock diperiksa (Tasks 5 dan 8).

## Steps

- [x] Task 1: Model vault dan kriptografi lokal yang dapat diuji.
- [x] Task 2: Penyimpanan ciphertext dengan commit dan pemulihan yang jelas.
- [x] Task 3: Sesi, autosave, recovery, dan pengurutan perubahan.
- [x] Task 4: Setup/unlock English dan integrasi aplikasi bernama EnCryNote.
- [x] Task 5: Inactivity lock, Settings, dan privacy lifecycle.
- [x] Task 6: Daftar catatan dan editor Write/Preview yang benar-benar berfungsi.
- [x] Task 7: Ekspor terenkripsi dan impor Markdown/encrypted export tanpa cache plaintext.
- [x] Task 8: Pemeriksaan lintas platform, offline, lisensi, dan panduan kontribusi.

## File map dan kontrak bersama

- `lib/vault/vault_types.dart`: `Note`, `VaultData`, `RecoveryConfig`, `UnlockedVault`, `AutoLockMode`, `FailureCode`, `VaultException`, serta validasi format. Tidak mengimpor widget.
- `lib/vault/vault_crypto.dart`: `VaultCrypto`, AEAD/KDF, parsing envelope dan AAD, tanpa IO disk.
- `lib/vault/vault_store.dart`: `VaultStore`, baca kandidat file, staging ciphertext, dan commit. Tidak memilih file pengguna atau menyimpan key.
- `lib/session/note_session.dart`: `NoteSession extends ChangeNotifier`, state unlock, data aktif, pending ciphertext, serialisasi perubahan dan error.
- `lib/platform/native_bridge.dart`: `NativeBridge`, satu batas native untuk commit, focus/privacy, dan akses file pilihan pengguna.
- `lib/lock/idle_lock.dart`: `IdleLock`, aturan waktu murni dengan clock yang diinjeksi.
- `lib/app.dart`, `lib/auth/auth_screen.dart`, `lib/settings/settings_screen.dart`: aplikasi, setup/unlock/recovery, dan empat pilihan lock.
- `lib/notes/notes_screen.dart`, `lib/notes/note_editor.dart`: daftar, CRUD dan tampilan source/Preview.
- `lib/transfer/transfer_service.dart`: `TransferService`, import/export melalui sesi dan native bridge.
- `lib/l10n/app_en.arb`, `l10n.yaml`: sumber string dan konfigurasi generator; hasil generator di `lib/l10n/generated/`.
- Test sejajar di `test/vault/`, `test/session/`, `test/lock/`, `test/auth/`, `test/notes/`, `test/transfer/`, dengan fixture sintetis dalam `test/support/fixtures.dart` dan fake bridge dalam `test/support/fake_native_bridge.dart`.
- Native: `android/app/src/main/kotlin/com/example/hello_flutter/MainActivity.kt`, file pendamping `EnCryNoteBridge.kt`, `macos/Runner/MainFlutterWindow.swift`, dan `macos/Runner/EnCryNoteBridge.swift`.

Kontrak tipe: `Note({required String id, required String title, required String markdown, required DateTime createdAt, required DateTime updatedAt})`; `VaultData({required List<Note> notes, AutoLockMode autoLock = AutoLockMode.oneMinute})`; `RecoveryConfig({required List<String> questions, required List<String> answers})`; `UnlockedVault({required Uint8List envelope, required SecretKey dataKey, required VaultData data, required int revision})`. `AutoLockMode` tepat `immediately`, `oneMinute`, `fiveMinutes`, `tenMinutes`. `FailureCode` tepat `credentials`, `format`, `unsupported`, `limit`, `storage`, `busy`; `VaultException` membawa `FailureCode code`, bukan isi/password dalam pesannya. Semua timestamp serialisasi berupa UTC ISO-8601; ID 16-byte random dalam hex.

Format v1: JSON UTF-8 dengan field berurutan secara kanonis dan bytes base64. Envelope lokal bertipe `local`, ekspor `export`; keduanya `version: 1` dan suite `argon2id-aes256gcm`. Payload lokal berisi revisi, notes dan auto-lock; ekspor hanya notes. Header/wrapper lokal tidak disalin ke ekspor. AAD berupa array JSON UTF-8 berurutan: domain, versi, suite, identitas/konteks, lalu parameter terkait. Domain berbeda untuk local payload, password wrap, recovery wrap, dan export; recovery wrap mengikat urutan teks pertanyaan. Jangan mengikat wrapper ke revisi payload sehingga autosave tidak perlu mengetahui password lagi.

Batas awal yang harus sama pada pembaca/penulis kedua platform: payload JSON plaintext maksimum **8 MiB**, envelope maksimum **16 MiB**, satu `.md` maksimum **1 MiB**. Perubahan yang melewati batas ditolak secara eksplisit, tidak dipotong. Argon2id v1: memory **19456 blok KiB (19 MiB)**, iterations **2**, parallelism **1**, hashLength **32**, salt acak **16 byte**; parser hanya menerima profil v1 itu. AES-GCM: key **32 byte**, nonce baru **12 byte**, tag **16 byte**. Parameter ini perlu benchmark native sebelum dianggap siap rilis, bukan klaim performa yang sudah dibuktikan.

---

### Task 1: Model dan kriptografi vault lokal

**Files:** Create `lib/vault/vault_types.dart`, `lib/vault/vault_crypto.dart`, `test/vault/vault_crypto_test.dart`, `test/support/fixtures.dart`, `integration_test/crypto_platform_test.dart`, `docs/security/crypto-profile.md`. Modify `pubspec.yaml`, `pubspec.lock`.

**Interfaces:** `bool validPassword(String value)`; `VaultCrypto.createVault(String password, RecoveryConfig recovery, VaultData data) -> Future<UnlockedVault>`; `unlock(Uint8List envelope, String password) -> Future<UnlockedVault>`; `recover(Uint8List envelope, List<String> answers) -> Future<UnlockedVault>`; `readRecoveryQuestions(Uint8List envelope) -> List<String>`; `seal(UnlockedVault vault, VaultData data, int revision) -> Future<Uint8List>`; `rewrapPassword(UnlockedVault vault, String newPassword, int revision) -> Future<Uint8List>`. `readRecoveryQuestions` memvalidasi schema/batas header lokal tanpa KDF; prompt baru terbukti autentik saat wrapper berhasil diverifikasi. Fixture file produces `fixtureData` (one synthetic note), `fixtureRecovery` (three custom prompts/answers) and `localPassword = 'local-1234'`. Later tasks use these exact names.

- [x] **Step 1:** Hanya setelah izin eksekusi, periksa isi/ignore proyek lalu, jika folder ini masih belum Git, `git init -b main`; verifikasi root Git sama dengan folder proyek. Jika keadaan checkout sudah berubah, jangan reset/discard atau mengganti branch pengguna. Jangan membuat worktree atau remote.
- [x] **Step 2:** Catat baseline file proyek yang memang ditinjau dengan commit lokal `chore: record Flutter baseline and approved design`; jangan memasukkan build/cache/IDE, local.properties, key, atau secret.
- [x] **Step 3:** Tambah test gagal `password and recovery unlock the same note`, `export profile cannot be parsed as local`, `wrong answers reveal no partial success`, `tampered header or tag is rejected`, `writer never exceeds reader limits`, dan assertions berikut:

```dart
expect(validPassword('1234567'), isFalse);
expect(validPassword('12345678'), isTrue);
expect(validPassword('👨‍👩‍👧‍👦1234567'), isTrue);
final created = await crypto.createVault(localPassword, fixtureRecovery, fixtureData);
final reopened = await crypto.unlock(created.envelope, localPassword);
expect(reopened.data.notes.single.markdown, fixtureData.notes.single.markdown);
final recovered = await crypto.recover(created.envelope, fixtureRecovery.answers);
expect(await recovered.dataKey.extractBytes(), await reopened.dataKey.extractBytes());
await expectLater(crypto.unlock(created.envelope, 'wrong-1234'), throwsA(isA<VaultException>()));
```

  Tambahkan assertions password tidak di-trim, jawaban hanya trim tepi dan tetap case-sensitive, serta pasangan jawaban yang bisa bertabrakan jika di-concat tidak menghasilkan key sama. Gunakan JSON array untuk gabungan jawaban. Uji ciphertext tidak memuat marker judul/isi/plaintext fixture, nonce berbeda setiap seal, dan penolakan profil KDF/header oversized sebelum derivasi.
- [x] **Step 4:** Jalankan `flutter test test/vault/vault_crypto_test.dart`; pastikan gagal karena kontrak yang belum diimplementasikan, bukan masalah environment yang tidak berkaitan.
- [x] **Step 5:** Implementasikan tipe dan API minimum, tambah `cryptography: ^2.9.0` serta deklarasi langsung `characters: ^1.4.1` berdasarkan lockfile yang sudah ada. Jalankan KDF di isolate agar UI tidak terblokir; jangan mengimplementasikan primitif kriptografi sendiri. Tambah `integration_test` dari Flutter SDK untuk test native.
- [x] **Step 6:** Jalankan ulang unit test sampai lulus. Sesudah device tersedia, jalankan `flutter test integration_test/crypto_platform_test.dart -d macos` dan `-d <android-device-id>`; catat hasil round-trip/profil nyata di `docs/security/crypto-profile.md`. Jika dukungan/profil gagal, berhenti dan laporkan, bukan menurunkan keamanan diam-diam.
- [x] **Step 7:** Commit hanya file Task 1 yang sudah lolos pemeriksaan: `feat: add authenticated local vault encryption`.

### Task 2: Commit ciphertext dan pemulihan disk

**Files:** Create `lib/vault/vault_store.dart`, `lib/platform/native_bridge.dart`, `test/vault/vault_store_test.dart`, `test/support/fake_native_bridge.dart`, `integration_test/storage_platform_test.dart`, kedua file native `EnCryNoteBridge` pada file map. Modify kedua entrypoint native pada file map, `macos/Runner.xcodeproj/project.pbxproj` untuk mendaftarkan file Swift, `android/app/build.gradle.kts` untuk `minSdk = maxOf(flutter.minSdkVersion, 24)`, `pubspec.yaml`, `pubspec.lock` untuk `path_provider: ^2.1.6`.

**Interfaces:** `VaultStore({required Directory directory, required NativeBridge native})`; `read() -> Future<Uint8List?>`; `commit(Uint8List ciphertext) -> Future<void>`. `NativeBridge` memakai channel `encrynote/platform`, menghasilkan `commitVault({required String stagedPath, required String activePath, required String previousPath}) -> Future<void>`. Fake bridge meniru kontrak commit dan dapat menggagalkan satu tahap untuk test.

- [x] **Step 1:** Tulis test gagal `staged bytes are encrypted`, `failure keeps last committed vault`, `missing primary with previous restores a candidate`, `truncated primary is not a new install`, `wrong password never tries previous wrappers`, serta pengujian putus pada tiap tahap:

```dart
await store.commit(created.envelope);
native.failNextCommit = true;
await expectLater(store.commit(updatedEnvelope), throwsA(isA<VaultException>()));
expect(await store.read(), orderedEquals(created.envelope));
```

- [x] **Step 2:** Jalankan `flutter test test/vault/vault_store_test.dart` dan periksa kegagalan yang diharapkan.
- [x] **Step 3:** Implementasikan `vault.enc`, `vault.previous`, `vault.next`. Staging hanya ciphertext dan di-flush sebelum bridge melakukan backup/penggantian atomik serta sync metadata sesuai OS. Backup dipertahankan sampai commit baru selesai. Saat primary ada, kegagalan autentikasi bukan izin mencoba generasi credential lama. File rusak menghasilkan error; `null` hanya berarti belum ada file vault/calon pemulihan sama sekali.
- [x] **Step 4:** Implementasikan handler commit native menggunakan operasi filesystem bawaan, di luar main thread. Ketiga path harus canonical, memiliki parent sama dalam direktori privat aplikasi yang dihitung OS, dan basename tepat `vault.next`, `vault.enc`, `vault.previous`; jangan menerima path impor sebagai tujuan commit. Pisahkan hasil penulisan buffer dari commit point. Uji tahap native pada kedua platform dan dokumentasikan keterbatasan durability yang benar-benar teramati.
- [x] **Step 5:** Jalankan unit test dan `flutter test integration_test/storage_platform_test.dart -d macos` serta Android saat tersedia; hasilnya harus mempertahankan vault lama atau memberi error non-destruktif, tidak pernah membuat vault kosong.
- [x] **Step 6:** Commit: `feat: persist encrypted vault snapshots safely`.

### Task 3: Sesi dan urutan perubahan

**Files:** Create `lib/session/note_session.dart`, `test/session/note_session_test.dart`. Extend fake/fixture test Task 1 dan 2, bukan membuat backend paralel.

**Interfaces:** `NoteSession({required VaultCrypto crypto, required VaultStore store})`. Enum `SessionPhase { loading, needsSetup, locked, recovering, unlocked, storageError }`; getters `phase`, `data` (`VaultData?`, null ketika locked/recovering), `recoveryQuestions` (`List<String>` tanpa jawaban), `canMutate`, `isBusy`, `failure` (`FailureCode?`). Methods `load()`, `setup(String password, RecoveryConfig recovery)`, `unlock(String password)`, `beginRecovery(List<String> answers)`, `completeRecovery(String newPassword)`, `saveNote(Note note)`, `deleteNote(String id)`, `setAutoLock(AutoLockMode mode)`, `retrySave()`, `lock()`, semuanya `Future<void>`. `saveNote` menerima dan memvalidasi draft sebelum await/debounce, dengan Future selesai setelah commit yang mencakup revisi itu; jangan meninggalkan satu-satunya salinan edit di controller widget. `beginRecovery` memverifikasi jawaban dan merekonsiliasi pending data, lalu menyimpan key hanya sebagai state recovery privat; tidak membuka catatan. `completeRecovery` baru mengaktifkan credential/sesi setelah commit. Membatalkan recovery memanggil `lock()`, yang menyembunyikan data sebelum await penyegelan. `readNotesForExport() -> List<Note>` mengembalikan salinan immutable hanya jika sesi boleh beroperasi; `appendImported(List<Note> notes) -> Future<void>` memberi ID lokal baru dan commit satu batch.

- [x] **Step 1:** Tulis test gagal untuk setup hanya selesai sesudah commit, lock membuang data dari state UI, recovery mengganti password tanpa mengubah isi, full-snapshot limit, dan snapshot pending otoritatif:

```dart
native.failNextCommit = true;
await expectLater(session.saveNote(editedNote), throwsA(isA<VaultException>()));
expect(session.canMutate, isFalse);
await session.lock();
expect(session.data, isNull);
await session.unlock(localPassword);
await session.retrySave();
expect(session.data!.notes.single.markdown, editedNote.markdown);
```

  Tambahkan controlled-Future tests `late save cannot revive locked state`, `retry cannot restore old password after recovery`, `failed recovery commit keeps original credentials`, dan `lock flushes the last keystroke before the debounce fires`. Revisi/credential lama tidak boleh memenangkan commit yang lebih baru.
- [x] **Step 2:** Jalankan `flutter test test/session/note_session_test.dart` hingga kegagalan menunjuk perilaku yang belum tersedia.
- [x] **Step 3:** Implementasikan satu antrean perubahan dengan revisi dan epoch sesi. Debounce penyegelan/penulisan autosave 500 ms berada di sesi, bukan di widget; semua edit yang sudah diterima harus ikut flush saat lock/berpindah catatan. Snapshot gagal-simpan tetap ciphertext otoritatif; blokir semua mutasi/ekspor sampai rekonsiliasi. Recovery merekonsiliasi data dulu dan baru mengganti wrapper setelah commit berhasil. Jangan membuat antrean retry credential independen. Validasi snapshot penuh sebelum diterima; input yang ditolak harus ditandai dan editor dikembalikan ke nilai terakhir yang diterima, bukan dipotong diam-diam atau diklaim tersimpan.
- [x] **Step 4:** Jalankan semua test `flutter test test/vault test/session`; lulus termasuk credential baru diterima dan credential lama ditolak tanpa fallback ke backup.
- [x] **Step 5:** Commit: `feat: coordinate note sessions recovery and pending saves`.

### Task 4: Setup, unlock, localization, dan nama aplikasi

**Files:** Create `lib/app.dart`, `lib/auth/auth_screen.dart`, `lib/l10n/app_en.arb`, `l10n.yaml`, `test/auth/auth_screen_test.dart`. Modify `lib/main.dart`, `test/widget_test.dart`, `pubspec.yaml`, `pubspec.lock`, `android/app/src/main/AndroidManifest.xml`, `macos/Runner/Configs/AppInfo.xcconfig`, `macos/Runner.xcodeproj/project.pbxproj`, `macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`.

**Interfaces:** `EnCryNoteApp({required NoteSession session})`; `AuthScreen({required NoteSession session})`. `main() -> Future<void>` menginisialisasi Flutter, direktori support privat, bridge/store/crypto/session, lalu menjalankan aplikasi. Localization dihasilkan menjadi `lib/l10n/generated/app_localizations.dart`, dipakai melalui `AppLocalizations.of(context)!`.

- [x] **Step 1:** Ganti smoke test counter dengan test gagal English setup, validasi 7/8 grapheme, tepat tiga pasangan pertanyaan/jawaban bebas, konfirmasi password, credential salah, recovery ke password baru, setup gagal-save yang tetap bisa dicoba, dan corrupt vault yang tidak menampilkan form instalasi baru:

```dart
await tester.pumpWidget(EnCryNoteApp(session: session));
await tester.pumpAndSettle();
expect(find.text('Create your password'), findsOneWidget);
expect(find.text('Recovery question 1'), findsOneWidget);
expect(find.text('Recovery question 3'), findsOneWidget);
expect(find.text('Recovery question 4'), findsNothing);
```

- [x] **Step 2:** Jalankan `flutter test test/auth/auth_screen_test.dart test/widget_test.dart` untuk hasil RED yang relevan.
- [x] **Step 3:** Implementasikan alur sesuai phase sesi, termasuk loading/error/retry. Tambah `flutter_localizations` dari SDK dan `intl: any` yang mengikuti pin SDK; aktifkan `generate: true` dan ARB. Label English di atas adalah key `createPasswordTitle`, `recoveryQuestionLabel(index)`; tambahkan keterangan bahwa teks pertanyaan dapat dibaca saat locked, jawaban case-sensitive setelah trim tepi, dan recovery tidak dapat membuka ekspor. Phase recovering menampilkan pembuatan password baru, bukan catatan. Jangan menyimpan controller password setelah selesai.
- [x] **Step 4:** Tampilkan nama EnCryNote, tema Material dari seed yang sudah ada dengan pasangan light/dark mengikuti OS. Untuk rename produk macOS, ubah juga semua BuildableName dan TEST_HOST yang masih menunjuk `hello_flutter.app/hello_flutter`; jangan mengganti namespace/bundle ID tanpa alasan tambahan.
- [x] **Step 5:** Jalankan `flutter gen-l10n`, test Task 4, `flutter analyze`, serta build macOS; pastikan label English tetap muncul pada locale OS yang belum didukung, dan referensi test host produk baru konsisten.
- [x] **Step 6:** Commit: `feat: add localized EnCryNote setup and unlock flows`.

### Task 5: Inactivity lock dan privacy lifecycle

**Files:** Create `lib/lock/idle_lock.dart`, `lib/settings/settings_screen.dart`, `lib/platform/privacy_lifecycle.dart`, `test/lock/idle_lock_test.dart`, `test/lock/privacy_lifecycle_test.dart`, `test/lock/settings_screen_test.dart`. Modify `lib/main.dart`, `lib/app.dart`, `lib/l10n/app_en.arb`, `lib/platform/native_bridge.dart`, dan kedua bridge/entrypoint native pada file map.

**Interfaces:** `IdleLock({required DateTime Function() now, required Duration Function() elapsed, required Future<void> Function() onLock})`; methods `setMode(AutoLockMode mode) -> void`, `activity() -> void`, `focusChanged(bool focused) -> Future<void>`, `checkDeadline() -> Future<void>`, `dispose() -> void`, getter `DateTime? deadline`. `elapsed` memakai Stopwatch milik lifecycle selama proses hidup; test menginjeksi durasi yang dapat dikontrol. `PrivacyLifecycle({required NoteSession session, required NativeBridge native, required Widget child})`; `SettingsScreen({required NoteSession session})`. Bridge menambahkan `Stream<bool> get focusChanges` dan `setPrivacyShield(bool visible) -> Future<void>`.

- [x] **Step 1:** Tulis test gagal clock terkontrol untuk 1/5/10 menit tepat pada batas, aktivitas scrolling/keyboard/tap yang me-reset timer, pekerjaan background yang tidak me-reset, serta Immediately saat fokus hilang:

```dart
lock.setMode(AutoLockMode.oneMinute);
lock.activity();
now = now.add(const Duration(seconds: 59));
elapsed += const Duration(seconds: 59);
await lock.checkDeadline();
expect(lockCalls, 0);
now = now.add(const Duration(seconds: 1));
elapsed += const Duration(seconds: 1);
await lock.checkDeadline();
expect(lockCalls, 1);
```

  Test widget memastikan pilihan tepat `['Immediately', '1 minute', '5 minutes', '10 minutes']`, nilai default oneMinute, serta tidak ada Never. Key ARB berturut-turut `autoLockImmediately`, `autoLockOneMinute`, `autoLockFiveMinutes`, `autoLockTenMinutes`. Test resume melewati deadline harus tetap locked sebelum event input/focus dapat meresetnya; pergeseran jam sistem ke belakang tidak boleh memperpanjang sesi (lock saat anomali terdeteksi).
- [x] **Step 2:** Jalankan `flutter test test/lock` dan periksa hasil RED.
- [x] **Step 3:** Implementasikan timer selama sesi unlocked/recovering dan recheck tenggat saat resume. Root listener menghitung aktivitas nyata, bukan rebuild/autosave; lifecycle/native-focus bukan aktivitas yang memperpanjang deadline. Pakai waktu elapsed monotonic selama proses hidup ditambah pemeriksaan resume/clock anomaly, bukan semata timer OS. Di `main`, bungkus `EnCryNoteApp(session: session)` dengan `PrivacyLifecycle(session: session, native: native, child: ...)`; tidak mengubah constructor app hanya untuk lifecycle.
- [x] **Step 4:** Native bridge memasang privacy shield sebelum tampilan inactive masuk snapshot; Flutter hanya menghapus shield sesudah focus aktif, deadline diperiksa, dan state sesi aman. Dialog Flutter tidak dianggap blur; dialog file OS tetap dapat mengunci. Jangan menambah larangan screenshot pengguna yang sedang unlock sebagai fitur baru.
- [ ] **Step 5:** Jalankan `flutter test test/lock test/session`, lalu verifikasi manual macOS/Android: app switcher, minimize, berpindah jendela, sleep/resume dan keyboard layar tidak mengekspos frame catatan sebelum pengecekan. Catat keterbatasan platform, bukan klaim tanpa bukti.
- [x] **Step 6:** Commit: `feat: enforce inactivity locking and private lifecycle views`.

### Task 6: Catatan dan editor Markdown

**Files:** Create `lib/notes/notes_screen.dart`, `lib/notes/note_editor.dart`, `test/notes/notes_screen_test.dart`, `test/notes/note_editor_test.dart`. Modify `lib/app.dart`, `lib/l10n/app_en.arb`, `pubspec.yaml`, `pubspec.lock`.

**Interfaces:** `NotesScreen({required NoteSession session})`; `NoteEditor({required NoteSession session, required Note note})`. Gunakan `saveNote`, `deleteNote`, dan state sesi Task 3; tidak membuat penyimpanan lokal kedua atau key di widget.

- [x] **Step 1:** Tulis test gagal create/edit/delete-cancel/delete-confirm, urutan updatedAt, autosave, source tidak berubah setelah Preview, state kosong/loading/save error, dan layout pada lebar 360/720/1100 logical pixels. Assertions utama:

```dart
await tester.tap(find.text('Preview'));
await tester.pump();
expect(find.text('A heading'), findsOneWidget);
await tester.tap(find.text('Write'));
await tester.pump();
expect(tester.widget<TextField>(find.byKey(const ValueKey('markdownInput'))).controller!.text,
    '# A heading\n\n**Important**');
```

  Uji Markdown berisi URL gambar, `file://`, path absolut/relatif dan asset reference dengan IO/network spies: tidak ada request atau pembacaan file. Link adalah teks selectable tanpa callback peluncuran. Test bahwa error save membekukan aksi mutasi dan tidak menampilkan Saved.
- [x] **Step 2:** Jalankan `flutter test test/notes` dan periksa kegagalan yang tepat.
- [x] **Step 3:** Implementasikan widget Material dan tambah `flutter_markdown_plus: ^1.0.12`. Pakai builder `img` yang selalu menampilkan string ARB `imageUnavailableOffline`; builder `a` menghasilkan teks selectable, bukan recognizer aktif. Tidak memakai WebView, `url_launcher`, `Image.network`, `Image.file`, atau default image loader. Setiap perubahan controller langsung diteruskan ke `saveNote`; debounce 500 ms dimiliki sesi Task 3. Lock/berpindah catatan harus menyimpan keystroke terakhir walaupun debounce belum berjalan.
- [x] **Step 4:** Daftar/editor berdampingan mulai lebar 720 logical pixels; di bawahnya gunakan navigasi daftar/detail. Gunakan scroll untuk teks panjang, focus yang terlihat, target sentuh >=44 logical pixels, serta test text scale 2x pada light/dark. Dispose controller saat lock; jangan mempertahankan judul/cuplikan pada layar terkunci.
- [ ] **Step 5:** Jalankan `flutter test test/notes test/auth test/lock`, `flutter analyze`, dan klik seluruh aksi editor pada kedua platform yang tersedia. Pastikan error/empty state juga teruji, bukan hanya catatan contoh.
- [x] **Step 6:** Commit: `feat: add offline Markdown note editing and preview`.

### Task 7: Transfer tanpa plaintext cache

**Files:** Create `lib/transfer/transfer_service.dart`, `lib/transfer/transfer_dialogs.dart`, `test/transfer/transfer_service_test.dart`, `test/transfer/transfer_dialogs_test.dart`, `integration_test/transfer_platform_test.dart`, `test/fixtures/plain_note.md`. Modify `lib/vault/vault_crypto.dart`, `lib/platform/native_bridge.dart`, kedua bridge native, `lib/main.dart`, `lib/app.dart`, `lib/notes/notes_screen.dart`, caller tests di `test/widget_test.dart`, `test/auth/auth_screen_test.dart`, `test/notes/notes_screen_test.dart`, `lib/l10n/app_en.arb`, serta `macos/Runner/DebugProfile.entitlements` dan `macos/Runner/Release.entitlements`.

**Interfaces:** Tambah `VaultCrypto.exportNotes(List<Note> notes, String exportPassword) -> Future<Uint8List>` dan `importExport(Uint8List bytes, String exportPassword) -> Future<List<Note>>`. `PickedImport({required String token, required String name, int? length})` didefinisikan di `native_bridge.dart`; bridge menambah `pickImport() -> Future<PickedImport?>`, `readImport(String token, {required int maxBytes}) -> Future<Uint8List>`, `releaseImport(String token) -> Future<void>`, `saveExport(Uint8List bytes, {required String fileName}) -> Future<bool>`. `TransferService extends ChangeNotifier`, constructor `({required NoteSession session, required VaultCrypto crypto, required NativeBridge native})`, getter `PickedImport? pendingImport`, methods `exportNotes(String password) -> Future<bool>`, `pickImport() -> Future<PickedImport?>`, `importPicked(PickedImport picked, {String? exportPassword}) -> Future<void>`, `cancelImport() -> Future<void>`. `pickImport` menyimpan handle pending di service, bukan widget yang dapat ter-dispose saat lock; `cancelImport` me-release handle. Pembatalan picker adalah null/false, bukan error data. Dialog file menghasilkan `showExportDialog(BuildContext context, TransferService service) -> Future<void>` dan `showImportDialog(BuildContext context, TransferService service) -> Future<void>`.

Task ini sengaja memperluas constructor app menjadi `EnCryNoteApp({required NoteSession session, required TransferService transfer})` dan daftar menjadi `NotesScreen({required NoteSession session, required TransferService transfer})`. Buat service sekali di main, teruskan ke app/daftar, grep seluruh caller dan sesuaikan fixtures/test pada task ini; constructor `AuthScreen`, `NoteEditor`, dan `PrivacyLifecycle` tidak berubah.

- [x] **Step 1:** Tulis test gagal export/import round-trip, export menolak password salah/tamper, tidak ada wrapper/recovery dalam struktur ekspor, dan Markdown vanilla tanpa front matter. Assertions inti:

```dart
final bytes = await crypto.exportNotes(fixtureData.notes, 'export-1234');
final notes = await crypto.importExport(bytes, 'export-1234');
expect(notes.single.markdown, fixtureData.notes.single.markdown);
await expectLater(crypto.importExport(bytes, localPassword), throwsA(isA<VaultException>()));
await expectLater(crypto.recover(bytes, fixtureRecovery.answers), throwsA(isA<VaultException>()));
```

  Tambahkan test BOM/CRLF/emoji, UTF-8 rusak, file kosong, panjang yang tidak diketahui, stream melebihi limit, filename traversal yang hanya boleh menjadi basename judul, duplikat menambah ID baru, limit keseluruhan setelah batch, serta cancel/failure tanpa mutasi. Pastikan nilai password aplikasi dan ekspor yang kebetulan sama tetap melalui jalur ekspor saja.
- [x] **Step 2:** Jalankan `flutter test test/transfer` dan pastikan RED sesuai perilaku yang belum tersedia.
- [x] **Step 3:** Implementasikan envelope export tanpa data key/wrapper/pertanyaan lokal, AEAD dengan salt/nonce baru, tipe/version/AAD yang membedakannya dari vault. `.md` dibaca UTF-8 dengan BOM opsional; isi termasuk CRLF dipertahankan, judul basename tanpa ekstensi, fallback Untitled. `appendImported` menyimpan satu batch dengan ID baru dan tidak menimpa.
- [x] **Step 4:** Implementasikan native picker tanpa plugin caching: Android memakai ACTION_OPEN_DOCUMENT dan ContentResolver bounded stream, grant sementara/read-only, local-only hint; macOS memakai NSOpenPanel dan security-scoped URL sementara. Pick mengembalikan handle saja, pembacaan baru setelah sesi unlock; selalu release handle. Jumlah byte dibatasi saat streaming meskipun length tidak tersedia. Jangan mengandalkan cleanup cache plaintext sesudahnya.
- [x] **Step 5:** Export menyiapkan ciphertext lebih dahulu; Android ACTION_CREATE_DOCUMENT dan macOS NSSavePanel hanya menerima ciphertext. Native bridge tidak membaca path arbitrer dari Markdown dan tidak menulis plaintext sementara. Tambahkan `com.apple.security.files.user-selected.read-write` pada kedua entitlements macOS, tanpa mematikan sandbox atau mengaktifkan network.
- [x] **Step 6:** Hubungkan dialog English `Export notes`, konfirmasi password, warning file ekspor tidak punya recovery, dan warning `.md` asli tetap plaintext. Root app mengamati service, menutup dialog produk serta membuang controller rahasia saat lock, dan mempertahankan hanya handle impor pending. Native dialog blur tetap mengunci mode Immediately; setelah unlock, root menawarkan kelanjutan impor handle tersebut tanpa mengulang picker. Siapkan ciphertext dan lepaskan referensi plaintext/password sebelum dialog ekspor native. Cancel pada tahap mana pun me-release handle, tidak mengubah catatan atau menghapus file sumber.
- [ ] **Step 7:** Jalankan unit/widget tests transfer dan integration test native; periksa direktori cache/support aplikasi sesudah raw import menggunakan marker yang baru dibuat saat runtime (agar tidak salah membaca literal dari bundle test): tidak ada salinan plaintext marker. File `.md` sumber yang sengaja dipilih tidak ikut dianggap cache aplikasi. Uji transfer Android-ke-macOS dan sebaliknya, bukan hanya export/import pada mesin yang sama.
- [x] **Step 8:** Commit: `feat: add password-isolated encrypted note transfer`.

### Task 8: Verifikasi rilis lokal dan kontribusi open source

**Files:** Create `integration_test/encrynote_flow_test.dart`, `test/project_contract_test.dart`, `CONTRIBUTING.md`, `LICENSE`, `docs/testing/native-checks.md`. Modify `README.md`, `android/app/src/main/AndroidManifest.xml`, dan konfigurasi backup Android yang diperlukan (`android/app/src/main/res/xml/backup_rules.xml`, `android/app/src/main/res/xml/data_extraction_rules.xml` bila dirujuk manifest).

**Interfaces:** Tidak menambah API produk. Test integrasi memakai `NoteSession`, `VaultStore`, `VaultCrypto` dan bridge yang sama dengan produk; test native dicatat per device, OS, build mode, aksi dan hasilnya.

- [x] **Step 1:** Tambahkan test kontrak gagal yang memeriksa ARB English, empat label auto-lock tepat, tidak ada runtime service/permission network pada release, serta backup exclusion vault. Tambahkan integration flow setup -> tulis -> restart locked -> unlock -> recovery -> export -> import ke vault kedua, memakai dependency nyata untuk crypto/disk dan hanya mengganti UI dialog OS pada jalur otomatis.

```dart
expect([englishArb['autoLockImmediately'], englishArb['autoLockOneMinute'],
  englishArb['autoLockFiveMinutes'], englishArb['autoLockTenMinutes']],
  ['Immediately', '1 minute', '5 minutes', '10 minutes']);
expect(mainManifest.contains('android.permission.INTERNET'), isFalse);
expect(releaseEntitlements.contains('com.apple.security.network.client'), isFalse);
```

  `englishArb`, `mainManifest`, dan `releaseEntitlements` dibaca dari file source masing-masing oleh test. Ini memeriksa konfigurasi source, bukan bukti permission artefak yang sudah digabung; pemeriksaan artefak tetap wajib pada Step 4.
- [x] **Step 2:** Jalankan `flutter test test/project_contract_test.dart` untuk RED, lalu lengkapi konfigurasi backup dan dokumentasi. Lisensi aplikasi MIT dengan attribution EnCryNote contributors; dokumentasikan lisensi dependency masing-masing tanpa mengubahnya menjadi MIT.
- [x] **Step 3:** Dokumentasikan di README: cara menjalankan, cold-start lock, pertanyaan recovery terbaca/risiko jawaban lemah, ekspor tanpa recovery, `.md` asli tetap plaintext, batas ukuran, profil KDF dan batas memori/OS. CONTRIBUTING menjelaskan menambah ARB, placeholder ICU dan tes locale. Jangan mengklaim audit keamanan formal, zeroization sempurna, atau tahan seluruh power loss.
- [x] **Step 4:** Jalankan terpisah `flutter gen-l10n`, `dart format --output=none --set-exit-if-changed lib test integration_test`, `flutter analyze`, `flutter test`, `flutter build apk --release`, `flutter build macos --release`, dan `flutter test integration_test/encrynote_flow_test.dart -d <device-id>` untuk kedua platform. Periksa permission artefak Android dengan `apkanalyzer manifest permissions build/app/outputs/flutter-apk/app-release.apk` dan entitlement macOS dengan `codesign -d --entitlements :- build/macos/Build/Products/Release/EnCryNote.app`; release tidak boleh memiliki network permission/entitlement. Keberhasilan build lokal bukan penandatanganan/publikasi store; konfigurasi signing yang belum production harus disebutkan.
- [ ] **Step 5:** Jalankan checklist native dengan jaringan dimatikan: setup/recovery, dialog file cancel/error, transfer dua arah, semua durasi lock, sleep/resume, inactive snapshot, text scale, keyboard/focus, serta light/dark. Uji pencarian marker plaintext pada data/cache/log fixture. Laporan menyebut Not run beserta alasan untuk perangkat atau pemeriksaan yang tidak tersedia, bukan PASS.
- [ ] **Step 6:** Sesuai metode eksekusi yang dipilih pengguna, lakukan review akhir atas semua perubahan dan seluruh checklist spec, perbaiki temuan, lalu commit `docs: document offline security and community contributions`. Tidak membuat remote, push, upload release, atau iOS scaffolding.

## Sumber yang diperiksa saat perencanaan

- Argon2id API dan profil OWASP yang dirujuk package: <https://pub.dev/documentation/cryptography/latest/cryptography/Argon2id-class.html>.
- Renderer dan custom element builders, termasuk default gambar jaringan/file: <https://pub.dev/packages/flutter_markdown_plus>.
- Direktori privat yang didukung Android/macOS: <https://pub.dev/packages/path_provider>.
- ARB/generator/localization Flutter: <https://docs.flutter.dev/ui/internationalization>.
- Native file picker macOS memerlukan user-selected read-write entitlement: <https://pub.dev/packages/file_picker_darwin>. Pemakaian package ini tidak direncanakan; rujukannya menjelaskan batas sandbox.
- Android file_picker saat diperiksa mempunyai jalur `openFileStream` yang menyalin isi ke app cache: <https://github.com/vicajilau/flutter_file_picker/blob/main/packages/file_picker_android/android/src/main/kotlin/com/mr/flutter/plugin/filepicker/FileUtils.kt>. Bridge native langsung dipilih agar impor plaintext tidak bergantung pada copy/cache library. Jangan menganggap temuan pada source ini sebagai klaim audit seluruh package atau versi lain.

## Self-review dan handoff

- Cakupan spec: setup/recovery/local encryption (1, 3, 4), persistence/limits/crash (1, 2, 3), editor (6), timer/privacy (5), transfer/offline (7, 8), localization/MIT/contribution (4, 8), Android/macOS native (2, 5, 7, 8).
- Tidak ada type/API rujukan task yang boleh didefinisikan ulang dengan nama berbeda; gunakan kontrak file map dan Interfaces. Implementer membaca spec dan plan, bukan hanya task tunggal.
- Self-review plan dilakukan penulis, tanpa dispatch implementer atau reviewer baru. Semua checkbox tetap kosong sampai eksekusi benar-benar disetujui.
- Pilihan metode: **Native** (disarankan untuk delapan task yang saling bergantung; satu implementer di sesi ini dan review terpisah di akhir) atau **Subagent-driven** (implementer dan reviewer fresh per task, lebih banyak context/cost). Pengguna belum memilih metode.
- Tunggu pengguna membaca/menyetujui plan dan memilih metode. Menyimpan rencana ini bukan izin mulai coding, menambahkan dependency, menginisialisasi Git, atau menjalankan test aplikasi.
