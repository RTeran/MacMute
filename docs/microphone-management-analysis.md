# MacMute: Análisis de la gestión del micrófono

## Resumen

MacMute controla el micrófono en Google Meet mediante un shortcut de teclado global en macOS. La app no silencia el micrófono del sistema directamente — en su lugar, envía un comando a la extensión de Chrome, que hace click en el botón de silencio dentro de la interfaz de Google Meet. El estado de silencio es siempre confirmado por la extensión (no lo decide la app).

---

## Arquitectura general

```
┌────────────────────────────────────────────────────────────────┐
│                      macOS (MacMute App)                       │
│                                                                │
│  Teclado global  →  GlobalShortcutManager                     │
│  (CGEvent tap)       ↓                                        │
│                  MuteStateManager  ←──── estado confirmado    │
│                      ↓                                        │
│                  SocketServer (Unix domain socket)             │
└──────────────────────┬─────────────────────────────────────────┘
                       │  ~/Library/Application Support/MacMute/macmute.sock
                       │  Protocolo: JSON + newline
┌──────────────────────┴─────────────────────────────────────────┐
│                     MacMuteHelper (ejecutable)                 │
│  - Lee del socket de la app (JSON + newline)                  │
│  - Escribe a Chrome via stdin/stdout (Native Messaging)       │
│  - Traduce entre ambos protocolos                             │
└──────────────────────┬─────────────────────────────────────────┘
                       │  Protocolo Native Messaging:
                       │  [4 bytes longitud little-endian] + [JSON]
┌──────────────────────┴─────────────────────────────────────────┐
│                    Chrome Browser                              │
│                                                                │
│  background.js (Service Worker)                               │
│  - Conecta con el helper via chrome.runtime.connectNative()   │
│  - Enruta mensajes a las pestañas de Meet                     │
│      ↓ chrome.tabs.sendMessage()                              │
│  content-script.js (inyectado en meet.google.com)             │
│  - Hace click en el botón de micrófono de Meet                │
│  - Detecta cambios de estado via MutationObserver             │
│  - Reporta el estado actual de vuelta al helper               │
└────────────────────────────────────────────────────────────────┘
```

---

## Componentes

### App macOS

#### `GlobalShortcutManager.swift`
Intercepta eventos de teclado a nivel global usando `CGEvent.tapCreate()`:

- **Nivel de tap:** `cgSessionEventTap` — intercepta en toda la sesión de usuario
- **Posición:** `headInsertEventTap` — máxima prioridad
- **Permiso requerido:** Accesibilidad (`AXIsProcessTrusted()`)
- Cuando la combinación configurada coincide, llama a `onShortcutTriggered` y **consume el evento** (devuelve `nil` en lugar del evento original)

Configuración almacenada en `UserDefaults`:
| Clave | Tipo | Descripción |
|---|---|---|
| `shortcutKeyCode` | `Int` | Key code de la tecla principal |
| `shortcutModifiers` | `Int` | `NSEvent.ModifierFlags.rawValue` |
| `globalShortcut` | `String` | Representación visual (ej. `⌘⌃M`) |

#### `MuteStateManager.swift`
Orquestador central. Gestiona `@Published var isMuted: Bool` (Combine).

- Cuando recibe el shortcut → `toggleMute()` → envía `{"type": "toggle"}` al socket
- **No cambia el estado directamente** — espera la confirmación de la extensión
- Cuando recibe `state_update` del socket → `updateState(muted:)` → actualiza UI y overlay

#### `SocketServer.swift`
Servidor Unix domain socket en `~/Library/Application Support/MacMute/macmute.sock`:

- Protocolo: mensajes JSON terminados en `\n` (byte `0x0A`)
- Acepta una conexión a la vez (del helper)
- Bidireccional: la app envía comandos y recibe confirmaciones de estado

#### `AudioManager.swift`
Disponible pero **no se usa para silenciar** (ver commit `fix: do not mute system mic`). Expone:
- `setSystemMicMute(_ muted: Bool)` — CoreAudio `kAudioDevicePropertyMute`
- `isSystemMicMuted() -> Bool` — lectura del estado actual

#### `MenuBarOverlayManager.swift`
Muestra una barra roja translúcida en la parte superior de todos los monitores cuando el micrófono está silenciado. Usa `NSWindow` a nivel `statusWindow - 1` con animaciones de fade.

#### `StatusBarController.swift`
Icono en la barra de menú (`mic.fill` / `mic.slash.fill`) con un popover que contiene `ShortcutConfigView`.

#### `ShortcutConfigView.swift`
UI SwiftUI para:
- Ver el estado actual del micrófono
- Configurar el shortcut global (graba la combinación de teclas)
- Botón manual de toggle

---

### MacMuteHelper (ejecutable independiente)

Puente entre Chrome y la app macOS. Se instala como host de Native Messaging.

**Protocolo de lectura desde Chrome (stdin):**
```
[4 bytes: longitud en little-endian UInt32] [N bytes: JSON]
```

**Protocolo de escritura a Chrome (stdout):**
```
[4 bytes: longitud en little-endian UInt32] [N bytes: JSON]
```

**Protocolo con la app:** Unix domain socket (mismo que SocketServer)

**Instalación:** `AppDelegate` crea automáticamente el manifest JSON en
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.macmute.helper.json`
detectando el ID de la extensión MacMute en el perfil de Chrome.

---

### Extensión de Chrome

#### `background.js`
Service Worker que:
- Conecta con el helper via `chrome.runtime.connectNative("com.macmute.helper")`
- Reenvía mensajes `toggle` y `get_state` a todas las pestañas de `meet.google.com`
- Recibe `state_update` de los content scripts y los reenvía al helper (y a la app)
- Gestiona reconexión automática (3 seg tras desconexión)
- Envía `state_update: {muted: false}` cuando no quedan pestañas de Meet activas (pestaña cerrada o suspendida por extensiones de tab manager)

#### `content-script.js`
Inyectado en `https://meet.google.com/*`. Responsabilidades:
- Busca el botón de micrófono de Meet con múltiples selectores (multiidioma):
  ```js
  '[data-is-muted]'
  'button[aria-label*="microphone" i]'
  'button[aria-label*="micrófono" i]'
  'button[aria-label*="mikrofon" i]'
  'button[data-tooltip*="microphone" i]'
  ```
- Detecta estado muted leyendo `data-is-muted` o `aria-label` del botón
- `toggleMute()` → `button.click()` + lee nuevo estado tras 200ms
- `MutationObserver` detecta cambios externos (click manual del usuario en Meet)
- Envía `{type: "state_update", muted: bool}` al background script

---

## Flujos de datos

### Flujo 1: Usuario presiona el shortcut global

```
1. CGEvent tap intercepta keyDown
2. GlobalShortcutManager verifica keyCode + modifiers
3. onShortcutTriggered() → MuteStateManager.toggleMute()
4. socketServer.sendMessage({"type": "toggle"})
5. MacMuteHelper lee del socket → NativeMessaging.writeMessage()
6. background.js recibe → sendToMeetTabs({type: "toggle"})
7. content-script.js recibe → toggleMute()
8. button.click() en el botón de micrófono de Meet
9. Tras 200ms: getMuteState() lee el nuevo estado
10. sendStateUpdate(newState) → chrome.runtime.sendMessage()
11. background.js recibe state_update → port.postMessage()
12. MacMuteHelper recibe → socketClient.sendMessage()
13. MuteStateManager.handleMessage() → updateState(muted:)
14. overlayManager.updateOverlay() + NotificationCenter
15. StatusBarController actualiza icono
```

### Flujo 2: Usuario hace click directamente en Meet

```
1. MutationObserver detecta cambio en [data-is-muted] o aria-label
2. getMuteState() → nuevo estado
3. sendStateUpdate(newState)
4. [continúa desde paso 11 del Flujo 1]
```

### Flujo 3: Pestaña de Meet se cierra o suspende

```
1. chrome.tabs.onRemoved / onUpdated dispara
2. checkNoMeetTabsLeft() verifica que no queden pestañas de Meet
3. Si lastKnownMuted == true y no hay tabs:
   - port.postMessage({type: "state_update", muted: false})
4. App desactiva overlay y actualiza icono
```

---

## Tipos de mensaje JSON

| Dirección | Tipo | Payload | Descripción |
|---|---|---|---|
| App → Extensión | `toggle` | — | Alterna estado del micrófono |
| App → Extensión | `get_state` | — | Solicita estado actual |
| Extensión → App | `state_update` | `{muted: bool}` | Confirma estado actual |

---

## Permisos requeridos

### macOS
| Permiso | Para qué |
|---|---|
| Accessibility | Crear CGEvent tap para shortcuts globales |
| Microphone | Declarado en Info.plist (AudioManager, aunque no se use actualmente para mute) |

### Chrome Extension
| Permiso | Para qué |
|---|---|
| `nativeMessaging` | Comunicar con MacMuteHelper |
| `scripting` | Inyectar content-script en Meet |
| `tabs` | Query de pestañas de Meet |
| Host: `https://meet.google.com/*` | Acceso a las pestañas de Meet |
