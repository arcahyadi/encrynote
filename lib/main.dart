import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'platform/native_bridge.dart';
import 'platform/privacy_lifecycle.dart';
import 'session/note_session.dart';
import 'transfer/transfer_service.dart';
import 'vault/vault_crypto.dart';
import 'vault/vault_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannelNativeBridge();
  final crypto = VaultCrypto();
  final session = NoteSession(
    crypto: crypto,
    store: VaultStore(
      directory: await getApplicationSupportDirectory(),
      native: native,
    ),
  );
  // One service for the whole process: its pending import handle has to outlive
  // the widgets a lock disposes.
  final transfer = TransferService(
    session: session,
    crypto: crypto,
    native: native,
  );
  runApp(
    PrivacyLifecycle(
      session: session,
      native: native,
      child: EnCryNoteApp(session: session, transfer: transfer),
    ),
  );
  // Rendered `loading` until this publishes a phase; a failure surfaces its own
  // retry on the auth screen instead of blocking startup.
  unawaited(session.load().catchError((Object _) {}));
}
