# KasihKirim — Android Platform

> **Scope note:** this document predates `docs/CLAUDE_IMPLEMENTATION_PLAN.md`
> §0.1's decision to build a native Kotlin app (`KasihKirimAndroid/`)
> instead of the Expo/React Native app described below. The device
> envelope (§1) and platform constraints still apply, but the Expo/RN
> build config (§2's `app.json` snippet, `package: "my.kasihkirim.app"`,
> Hermes/Fabric/TurboModules) does not reflect the real build. The
> production `applicationId` is **`com.ftechsolutions.kasihkirim`** (see
> `docs/RELEASE_SIGNING.md`); actual SDK levels and build settings live in
> `KasihKirimAndroid/app/build.gradle.kts`. This file has not had a
> native-build reconciliation pass — treat it as historical context, not
> current configuration.

**Android only.** No iOS targets, no iOS dependencies, no `ios/` directory.

Target: a 2 GB Redmi in Beluran on 3G, not a Pixel in an office.

---

## 1. Device envelope

| | Floor | Typical | Ceiling |
|---|---|---|---|
| RAM | 2 GB | 3–4 GB | 8 GB |
| Android | 7.0 (API 24) | 11–13 | 16 |
| Storage free | ~1 GB | 4 GB | — |
| Screen | 720 × 1280 | 1080 × 2340 | — |
| Network | 3G, ~400 kbps | 4G intermittent | 4G |
| Chipset | Helio A22, SD 439, Unisoc | SD 6xx, Helio G | — |

Representative devices in this market: Redmi A2/A3, Redmi 9A/10A, Samsung Galaxy A0x, Vivo Y02/Y16, Oppo A17, Infinix Smart, Tecno Spark.

**The floor device is the design target, not the compatibility floor.** Every budget in this document is measured on it.

---

## 2. Build configuration

| Setting | Value | Rationale |
|---|---|---|
| `minSdkVersion` | **24** | Android 7.0 — still in use on the oldest devices in the target market |
| `targetSdkVersion` | **36** | Play requires new apps to target API 36 as of 31 Aug 2026 |
| `compileSdkVersion` | 36 | |
| Expo SDK | 57+ (RN 0.86, React 19.2) | One major behind latest, per `DEPLOYMENT.md` §15 |
| Architecture | New Architecture (Fabric + TurboModules) | Default; lower bridge overhead |
| JS engine | **Hermes** | Precompiled bytecode — faster start, lower memory than JSC |
| Output | **AAB** with per-ABI splits | Keeps the download inside 25 MB |
| ABIs | `arm64-v8a`, `armeabi-v7a` | v7a retained for old budget devices; **no x86** |
| R8 | Full mode, obfuscation + resource shrinking | Size and code protection |
| **16 KB page size** | **Required** | All native libs 16 KB-aligned; CI gate (`DEPLOYMENT.md` §10.2) |

```json
{
  "expo": {
    "name": "KasihKirim",
    "slug": "kasihkirim",
    "platforms": ["android"],
    "android": {
      "package": "my.kasihkirim.app",
      "versionCode": 1,
      "enableProguardInReleaseBuilds": true,
      "enableShrinkResourcesInReleaseBuilds": true,
      "blockedPermissions": [
        "android.permission.ACCESS_BACKGROUND_LOCATION",
        "android.permission.READ_SMS",
        "android.permission.RECEIVE_SMS",
        "android.permission.READ_EXTERNAL_STORAGE",
        "android.permission.QUERY_ALL_PACKAGES",
        "android.permission.READ_PHONE_STATE"
      ]
    },
    "updates": { "fallbackToCacheTimeout": 0 },
    "runtimeVersion": { "policy": "fingerprint" }
  }
}
```

`blockedPermissions` is a defensive measure. Transitive dependencies routinely merge permissions into the manifest that nobody asked for, and an unexplained `READ_SMS` in a financial app is a Play review problem discovered at the worst possible moment.

---

## 3. Permissions

### 3.1 Requested

| Permission | When | Why | User-facing rationale (BM) |
|---|---|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | Install | Normal permissions | — |
| `CAMERA` | First QR scan or photo | Handover proof, receipts, products, address photos | *"Untuk imbas QR dan ambil gambar bukti penghantaran."* |
| `ACCESS_FINE_LOCATION` | First handover or trip | Handover geo-proof; trip tracking | *"Untuk sahkan lokasi semasa serah dan terima barang."* |
| `ACCESS_COARSE_LOCATION` | With fine | Fallback | — |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION` | Trip start | Tracking during an active trip only | Visible persistent notification |
| `POST_NOTIFICATIONS` (33+) | After first Kirim, in context | Delivery updates | *"Supaya kami boleh beritahu bila barang awak dalam perjalanan."* |
| `VIBRATE` | Install | Critical alerts | — |

### 3.2 Deliberately not requested

| Permission | Why not | Alternative |
|---|---|---|
| **`ACCESS_BACKGROUND_LOCATION`** | Triggers Play's sensitive-permission review: written justification, demo video, ongoing re-justification. Also the single most common cause of user distrust in a delivery app. | Foreground service with a visible notification. Tracking runs while the trip is active, which is the only time it is needed. |
| **`READ_SMS` / `RECEIVE_SMS`** | Restricted permission requiring a Play declaration and an exception grant. Almost never approved for this use case. | **SMS Retriever API** — autofills the OTP with no permission at all |
| `READ_EXTERNAL_STORAGE` / `READ_MEDIA_IMAGES` | Not needed | **Android Photo Picker** via `expo-image-picker` — no permission, no declaration |
| `QUERY_ALL_PACKAGES` | Restricted, unjustifiable here | — |
| `READ_PHONE_STATE` | Privacy-invasive; not needed | `install_id` generated in-app |
| `WRITE_EXTERNAL_STORAGE` | Scoped storage | App-private directories |

Avoiding background location and SMS permissions removes the two most common causes of extended Play review for apps in this category (`DEPLOYMENT.md` §10.4). It is a deliberate architectural constraint, not an oversight.

### 3.3 Request pattern

Never request at cold start. Every permission is preceded by an in-context priming screen explaining the benefit, with a "not now" path that leaves the app usable.

```
Carrier taps "Mula Trip"
        ↓
Priming screen — what location is used for, that it stops when the trip ends
        ↓
System dialog
        ↓
   ┌────┴────┐
Granted   Denied → trip proceeds; handover falls back to OTP;
                    proof_quality WEAK, explained honestly to the user
```

Denial degrades the experience; it never blocks the product. A carrier who refuses location can still complete deliveries using OTP handover.

### 3.4 Foreground service

```xml
<service
  android:name=".TripTrackingService"
  android:foregroundServiceType="location"
  android:exported="false" />
```

- Starts on `DEPARTED`, stops on `ARRIVED` or trip close.
- Persistent notification: *"Trip Beluran → KK sedang berjalan"* with a stop action.
- Location sampled every 60 s, or on 500 m displacement — whichever is less frequent. Battery matters more than precision here; the customer needs "somewhere past Telupid", not metre accuracy.
- Points batched and uploaded every 5 minutes; queued when offline.
- Auto-stops after 12 h as a safety net against a carrier forgetting to close a trip.

---

## 4. Performance on 2 GB devices

### 4.1 Budgets (CI-enforced)

| Metric | Budget |
|---|---|
| APK download (per-ABI) | ≤ 25 MB |
| Installed size | ≤ 90 MB |
| Cold start → interactive | ≤ 3.5 s |
| JS heap steady state | ≤ 180 MB |
| List scroll | ≥ 50 fps |
| App-managed cache | ≤ 150 MB |
| Battery, 4 h active trip | ≤ 12 % |

### 4.2 Startup

```
0ms     Native init (Hermes bytecode)
        ↓
200ms   Splash — brand mark on cream
        ↓
400ms   Root layout: auth state from SecureStore, cached config
        ↓
900ms   First screen from SQLite cache (renders WITHOUT network)
        ↓
        Background: config refresh (500ms timeout), sync pull, token refresh
```

**The first screen renders from cache before any network call completes.** A user opening the app in a dead spot sees their deliveries, not a spinner. Network results reconcile in when they arrive.

Deferred until after first paint: Sentry full init, push registration, analytics, image prefetch, Realtime subscriptions.

### 4.3 Memory

| Technique | Detail |
|---|---|
| Virtualised lists | FlashList everywhere; `estimatedItemSize` tuned per list |
| Image cache cap | `expo-image` disk 100 MB, memory 40 MB |
| Image sizing | Storage transforms at fixed widths: `w=160` thumb, `w=480` card, `w=1080` detail. The app never downloads an original. |
| Route unmounting | Expo Router lazy groups; unused role routes never mount |
| Map | Only on the trip screen; unmounted on blur |
| Pagination | 20 rows default, **10 when `total_ram_mb < 3000`** — server decides |
| Large payloads | Streamed to SQLite, never held whole in JS |
| Leaks | Every subscription, timer and listener cleaned in `useEffect` teardown; soak test asserts flat heap |

### 4.4 Bundle size

| Technique | Saving |
|---|---|
| Hermes bytecode | ~30 % vs JSC |
| R8 full mode + resource shrinking | ~20 % |
| Per-ABI splits (AAB) | ~35 % of download |
| No `moment`, no full `lodash` | ~2 MB |
| `date-fns` subpath imports / `Intl` | ~500 KB |
| SVG icons, no icon font | ~400 KB |
| WebP assets | ~40 % of image weight |
| Lazy route groups | Deferred parse cost |

Measured per PR with `expo-atlas`; a regression over budget fails the build.

**Rejected dependencies:** Reanimated-heavy motion systems (jank on the floor device), Redux Toolkit (weight for no benefit at this scale), any library that pulls a full ICU dataset, any library that is iOS-first with Android as an afterthought.

---

## 5. Offline implementation

### 5.1 Local storage

```
expo-sqlite (WAL mode)
├── cache_*        entities, TTL + LRU, 30 MB budget
├── outbox         pending mutations — durable across kill and reboot
├── media_queue    pending uploads, 20 MB, NEVER evicted
└── sync_cursors   per-table delta position
```

### 5.2 Outbox behaviour

- Idempotency key generated **when the user acts**, not when the request is sent (`API.md` §7). A confirmation retried eleven times over three days carries one key and produces one effect.
- Backoff `2^attempts` seconds, capped at 5 min, ±20 % jitter.
- `Retry-After` from a `429` is honoured exactly, overriding local backoff — otherwise a village reconnecting produces a synchronised retry storm.
- Per-entity ordering via `depends_on`; different deliveries never block each other.
- Give up after 10 attempts or 7 days → surfaced in a "Perlu Perhatian" list. **Never silently discarded.**
- Processed on: app foreground, connectivity regained, every 60 s while foregrounded, and via `expo-background-task` when the OS permits.

### 5.3 Media handling

```
Capture → resize (long edge ≤ 1280) → JPEG q0.6 → target ≤ 200 KB
        → write to media_queue → upload resumably when connected
```

The delivery event references the media by local id. **The event syncs first; the photo follows.** A large photo must never delay the state transition it accompanies — and on a 3G link it certainly would.

Pending media is never evicted from the cache. If storage is exhausted, the app refuses new capture with a clear message rather than discarding evidence.

### 5.4 What works with zero signal

| Works offline | Requires network |
|---|---|
| View active deliveries and full trip manifest | Papan Kirim refresh |
| **Display handover QR** (cached at match time) | New quotes |
| **Scan QR** | Payment |
| **Enter and verify OTP** (hash cached for the current leg) | Matching |
| Capture POD photo and receipt | Chat send/receive |
| Draft a Kirim | Product browse (beyond cache) |
| Read cached board and orders | Price variance response |
| See earnings snapshot | Payout request |

### 5.5 Sync state UI

Always visible, always in plain Bahasa Malaysia:

| State | Copy |
|---|---|
| Synced | *"Semua sudah dihantar"* |
| Pending | *"3 perkara menunggu talian"* |
| Syncing | *"Sedang hantar… 2/3"* |
| Failed | *"1 perkara perlu perhatian"* → tappable |
| Offline | *"Tiada talian — kerja awak disimpan"* |

Optimistic UI is used for state changes, **never for money**. A payment shows its true status or "pending", never a premature success.

---

## 6. Push notifications

### 6.1 Channels (Android 8+)

| Channel ID | Name (BM) | Importance | Behaviour |
|---|---|---|---|
| `delivery_critical` | Penghantaran Penting | HIGH | Sound + vibrate + heads-up |
| `handover_codes` | Kod Serahan | HIGH | Sound + vibrate |
| `payments` | Pembayaran | HIGH | Sound |
| `orders` | Pesanan | DEFAULT | Sound |
| `chat` | Mesej | DEFAULT | Sound |
| `promotions` | Promosi & Baucar | LOW | Silent |

Separate channels let a user mute promos without muting the code they need to receive a parcel — which is exactly what happens when everything shares one channel.

### 6.2 The OEM problem

This is the single largest reliability risk in the mobile client, and it is not a bug we can fix.

Xiaomi/MIUI, Oppo/ColorOS, Vivo/FuntouchOS, Realme, Infinix and Tecno — which together dominate this market segment — ship aggressive battery managers that kill background processes and silently suppress FCM delivery. An app can be perfectly implemented and still never show a notification.

**Mitigations, in order of importance:**

1. **The in-app inbox is the source of truth** (`ARCHITECTURE.md` §10). Push is an accelerator, never the record. Nothing is lost if a push never arrives.
2. **SMS fallback for critical events** — new match, handover code, COD amount — if unacknowledged after 5 minutes.
3. **An OEM-specific onboarding screen**, shown once, detecting the manufacturer and giving exact steps: MIUI → Autostart + "No restrictions"; ColorOS → Allow background activity; FuntouchOS → High background power consumption.
4. **Notification health check** in Settings: a diagnostic that reports whether notifications are enabled, whether the channel is muted, and whether battery optimisation is active, with a deep link to the relevant system screen.

### 6.3 Token lifecycle

Registered on login and on rotation; deactivated on `DeviceNotRegistered` receipts; pruned after 60 days idle. Receipts are polled and recorded — that record is also what decides whether the SMS fallback fires.

---

## 7. Camera, QR and photos

| Aspect | Implementation |
|---|---|
| Library | `expo-camera` — one module for QR scan and photo capture |
| QR scan | Continuous, `barcodeScannerSettings: { barcodeTypes: ['qr'] }` |
| Torch | **Prominent toggle.** Handovers happen at dusk and in vehicle shade. |
| Feedback | Haptic + sound on successful scan — the user may not be looking at the screen |
| QR display | Max brightness forced while shown; high error-correction level so it scans off a cracked screen |
| Manual fallback | *"Tak boleh imbas? Masuk kod"* always visible on the scan screen |
| Photo | Resized on-device before it ever touches the queue |
| Screenshots | `FLAG_SECURE` on KYC capture, handover QR and payout screens |

High QR error correction plus forced brightness is not a detail. A meaningful proportion of these scans happen off a scratched Redmi screen held at arm's length in tropical daylight.

---

## 8. Localisation and accessibility

| Aspect | Implementation |
|---|---|
| Default | **Bahasa Malaysia (`ms`)**, always. English is opt-in. |
| Library | `i18next` + `expo-localization` |
| Coverage | CI fails on a missing `ms` key |
| Server errors | Client prefers `message_ms` from the error envelope |
| Numbers | `Intl.NumberFormat('ms-MY')`; currency always `RM 12.50`, never `12.5` |
| Dates | Relative in BM: *"esok pagi"*, *"2 hari lagi"* |
| Font scaling | Layouts survive 200 % without truncation |
| Touch targets | ≥ 48 dp, verified by an automated layout test |
| Contrast | ≥ 4.5:1 against the brand palette |
| TalkBack | Every interactive element labelled in BM; core flows completable with TalkBack alone |
| Critical numerics | COD amount, OTP and budget cap rendered large, high-contrast, mono-spaced digits |

Copy is written for a reader who is not technical and may not be a confident reader at all. *"Menunggu talian"*, not *"Sync pending"*.

---

## 9. Data usage

| Mode | Behaviour | Monthly budget |
|---|---|---|
| Normal | Thumbnails on board and lists; detail images on demand | ≤ 40 MB |
| **Jimat Data** | No image prefetch, thumbnails only on tap, 10-row pages, sync only on foreground | ≤ 15 MB |

`X-Data-Saver: 1` tells the server to omit image URLs and trim page sizes, so the saving is real rather than cosmetic. Auto-suggested when `NetInfo` reports 2G/3G or when Android's system data saver is on.

A live counter in Settings shows data used this month. Users on prepaid credit care about this number, and showing it builds the trust the product is selling.

---

## 10. Android-specific edge cases

| Case | Handling |
|---|---|
| Process death during a handover | State written to SQLite before the network call; resumes on relaunch |
| Doze / App Standby | Foreground service exempt during a trip; outbox drains on foreground |
| Clock wrong by hours | `client_captured_at` + server skew correction; server time is authoritative for ordering |
| Storage full | Refuse new capture with a clear message; never evict pending proof |
| Low memory kill | Full state restore from SQLite; no in-memory-only state |
| Split screen / multi-window | Supported; layouts responsive |
| Back gesture | Predictive back supported; unsaved Kirim drafts prompt |
| Dark mode | Supported; brand palette has verified dark variants |
| Rooted device | Recorded as a risk signal, **not blocked** (`SECURITY.md` §10) |
| No Google Play Services | Rare but real on grey-market devices; push unavailable → SMS fallback becomes primary, app remains fully functional |

That last row matters more than it sounds. A device without Play Services in this market is not a hypothetical, and the app must degrade to a working state rather than a broken one.

---

## 11. Device test matrix

| Tier | Device | Android | RAM | Purpose |
|---|---|---|---|---|
| **Floor** | Redmi A2 / Galaxy A03 | 7–11 | 2 GB | **All budgets measured here** |
| Low | Redmi 10A / Vivo Y16 | 12 | 3 GB | Common case |
| Mid | Galaxy A15 / Redmi Note 12 | 13–14 | 4–6 GB | Typical town user |
| High | Pixel 8 | 15–16 | 8 GB | Latest API behaviour |
| OEM | Oppo, Vivo, Infinix, Tecno | Various | — | **Battery manager and notification behaviour** |

Firebase Test Lab for breadth; two physical floor devices kept on the team for the things emulators do not reproduce — thermal throttling, real GPS drift under canopy, and how the screen actually behaves in Sabah daylight.

---

## 12. Android release checklist

- [ ] `targetSdkVersion` 36; `minSdkVersion` 24
- [ ] 16 KB page alignment verified on all native libraries
- [ ] Only the permissions in §3.1 present in the merged manifest
- [ ] `blockedPermissions` effective — verified against the built AAB, not the source
- [ ] APK ≤ 25 MB per ABI; installed ≤ 90 MB
- [ ] Cold start ≤ 3.5 s on the floor device
- [ ] 30-minute soak: no OOM, flat heap
- [ ] Offline E2E (E21) green under `flapping` network
- [ ] Notification channels created and individually mutable
- [ ] OEM onboarding screen verified on MIUI, ColorOS and FuntouchOS
- [ ] SMS Retriever OTP autofill working
- [ ] Photo Picker in use — no media permission requested
- [ ] Foreground service notification correct; auto-stop verified
- [ ] `FLAG_SECURE` on KYC, QR and payout screens
- [ ] BM complete; 200 % font scale renders correctly
- [ ] TalkBack pass on core flows
- [ ] Jimat Data mode verified under `rural-3g`
- [ ] Play pre-launch report clean
