# LET IT DIE Custom Launcher — Borderless and Backups

> **No GUI version / Versión sin interfaz gráfica.** The launcher runs in the
> background or in an optional console window. / El launcher funciona en
> segundo plano o, de forma opcional, en una consola.

## English — Quick instructions

### Start the game

1. Download the ZIP from **Releases** and extract the entire folder.
2. Keep LET IT DIE configured in **Windowed** mode.
3. Open `START GAME - HIDDEN (INICIAR OCULTO).vbs`.
4. Wait until the main menu is fully loaded.
5. Press `Ctrl+Alt+F11` once to apply borderless.

If a loading screen returns the game to a normal window, press
`Ctrl+Alt+F11` again. The launcher does not continuously resize the window, so
it does not cause constant flickering.

After the game closes, the launcher waits 15 seconds and creates a verified
backup in:

```text
%USERPROFILE%\Documents\LETITDIE_Backups
```

To see status messages or troubleshoot, use
`START GAME - CONSOLE (INICIAR CON CONSOLA).cmd` instead.

### Optional Google Drive backup

1. Install and sign in to **Google Drive for desktop**.
2. Open `CONFIGURE GOOGLE DRIVE (CONFIGURAR GOOGLE DRIVE).cmd`.
3. Select or create `LETITDIE_Backups` inside **My Drive**.

Google Drive is optional. Local verified backups work without it.

---

## Español — Instrucciones rápidas

### Iniciar el juego

1. Descarga el ZIP desde **Releases** y extrae la carpeta completa.
2. Deja LET IT DIE configurado en modo **Ventana**.
3. Abre `START GAME - HIDDEN (INICIAR OCULTO).vbs`.
4. Espera hasta que el menú principal termine de cargar.
5. Pulsa `Ctrl+Alt+F11` una vez para aplicar borderless.

Si una pantalla de carga devuelve el juego a una ventana normal, pulsa
`Ctrl+Alt+F11` nuevamente. El launcher no cambia el tamaño continuamente, por
lo que no produce parpadeo constante.

Después de cerrar el juego, el launcher espera 15 segundos y crea un backup
verificado en:

```text
%USERPROFILE%\Documents\LETITDIE_Backups
```

Para ver los mensajes o investigar un problema, usa
`START GAME - CONSOLE (INICIAR CON CONSOLA).cmd`.

### Backup opcional en Google Drive

1. Instala e inicia sesión en **Google Drive for desktop**.
2. Abre `CONFIGURE GOOGLE DRIVE (CONFIGURAR GOOGLE DRIVE).cmd`.
3. Selecciona o crea `LETITDIE_Backups` dentro de **Mi unidad**.

Google Drive es opcional. Los backups locales verificados funcionan sin él.

---

## Included features / Funciones incluidas

- Verified local backups using SHA-256 / Backups locales verificados con SHA-256.
- Daily backup history / Historial diario de backups.
- Optional Google Drive mirror / Copia opcional en Google Drive.
- Hidden or visible-console launch / Inicio oculto o con consola visible.
- No administrator rights required / No necesita permisos de administrador.

Advanced files, configuration and diagnostic tools are stored inside
`_Launcher Files`. This community project is not affiliated with SUPERTRICK
GAMES, GungHo Online Entertainment, Steam or Google.
