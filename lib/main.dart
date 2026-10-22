import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'platform/native_bridge.dart';
import 'session/note_session.dart';
import 'vault/vault_crypto.dart';
import 'vault/vault_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = NoteSession(
    crypto: VaultCrypto(),
    store: VaultStore(
      directory: await getApplicationSupportDirectory(),
      native: const MethodChannelNativeBridge(),
    ),
  );
  runApp(EnCryNoteApp(session: session));
  // Rendered `loading` until this publishes a phase; a failure surfaces its own
  // retry on the auth screen instead of blocking startup.
  unawaited(session.load().catchError((Object _) {}));
}
