# Navegador de la persona (extensión «Ghosty» para Chrome) — qué toca en la app

Escrito el 2026-10-04. Lo que hay del lado del servidor está en gs: `docs/claude/navegador-del-agente.md`.

## Qué es
La extensión «Ghosty» para Chrome deja que el agente de la persona maneje el Chrome de su computadora: navega, da clic, llena formularios, toma capturas y graba GIF. La conversación vive en gs (/c, esta app o la terminal) y la extensión sólo ejecuta. Si la extensión está conectada, gs agrega las tools `browser_*` al turno.

## Hoy la app NO necesita nada para que funcione
Ya se probó por la API de la app con el bearer `ghosty-app-ios` en `/api/v2/me/agents/…/conversations/…/messages`. Desde un hilo de la app el agente maneja el Chrome, guarda y corre atajos, y deja el GIF como archivo del hilo. El GIF llega como cualquier entrega y las capturas sólo las ve el agente.

## Lo que conviene sumar ahora que Chrome Web Store la publicó (1.0.4, pública desde el 16-oct)

Hecho el 28-oct: puntos 1 y 2 como la fila «Tu Chrome» de Integraciones (`chromeRow` en `ConectoresView.swift`, `GhostyAPI.browserStatus`, prueba `testChromeRowSharesLink`). En vez de abrir la liga en el iPhone, la comparte: la extensión se instala en la compu. Faltan 3, 4 y 5.

1. **Tarjeta «Conecta tu Chrome»** en Ajustes → Conectores, o en el vacío del chat: un texto corto y una liga a `https://www.ghosty.studio/chrome`. Esa ruta redirige a la ficha de la tienda, que se configura con `CHROME_EXTENSION_URL` en PlatformSetting, sin deploy. La app sólo abre la liga.
2. **Estado de la conexión.** `GET https://www.ghosty.studio/api/browser/call` con el mismo bearer OAuth de la app regresa `{connected, email, connectedAt, lastStep}`. Un punto verde «Chrome conectado» junto al agente, o «no conectado» con la liga del punto 1.
3. **Sugerencias en el composer** sólo si `connected`, por ejemplo «Llena este formulario en mi Chrome» o «Publica esto en mi página».
4. **Respuesta «no conectado».** Si la persona pide algo del navegador sin extensión, el agente ya contesta «tu navegador no está conectado» con la liga. Que la liga abra la hoja del punto 1, no Safari.
5. **Atajos guardados.** Si la persona guardó atajos desde /c (`/publicar`, etc.), a futuro se pueden listar en el composer. El endpoint de atajos está en gs (ver la ficha).

## Trampas
- Durante un deploy blue/green de gs, el estado puede decir «no conectado» unos segundos. Reintenta una vez antes de mostrarlo.
- El navegador maneja el Chrome de la COMPUTADORA, no el del iPhone. El copy debe decirlo («en tu Chrome de la compu»).
- Nada de esto se compila hasta que la tienda publique la extensión; mientras tanto la tarjeta no tendría a dónde mandar.
