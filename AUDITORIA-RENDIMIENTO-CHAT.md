# Auditoría de rendimiento del chat (9-nov-2026) — comprobada

Síntoma: la conversación «VVideos» (Ghosty de business, `cmrxuapvu000bg8tn7no9dzt3` /
`5f20e514…`) tarda al abrir y la app se pone pesada a media inferencia.

**Cómo se midió:** simulador iPhone 17 Pro con la conversación REAL (token del CLI,
`GHOSTY_AVISO`), contadores temporales de repintado + cuadros perdidos (`CADisplayLink`), y
Time Profiler (`xctrace`) durante una respuesta falsa local que crece 14 letras cada 50 ms
como el SSE (sin tocar el servidor). Parche de la sonda: `perf-probe.patch` en el scratchpad
de la sesión; el árbol quedó limpio.

## Resultado

| | Cuadros/s | Hilo principal |
|---|---|---|
| En reposo | 60 | libre |
| Abriendo el hilo | 32–48 (tirones de 266, 440 y 199 ms) | — |
| **Mientras llega la respuesta** | **6–10** | **97 % ocupado** |

El simulador corre en el procesador de la Mac; en el iPhone no debería ir mejor.

## En qué se va el hilo principal durante el stream (11 s, 9 800 muestras)

1. **~20 % layout del VStack completo** (`sizeThatFits` de todas las filas) + mucho
   AttributeGraph: 92 filas no perezosas que se vuelven a medir en cada trozo.
2. **13 % `AgentBubble.body` de TODAS las burbujas viejas**: 36 burbujas reevaluadas por
   cada trozo (1 000/s). Lo caro son sus propiedades calculadas, que se repiten:
   `narrated` 6 %, `ConnectOffers.extract` 4 % (compila un `NSRegularExpression` cada vez),
   `fuentes` 3.5 %, `DigestMessage.split` 2 %, `HelpersHeader.split` 1.6 %.
   ⚠️ Corrección a la primera versión: el markdown de las viejas **no** se re-parsea
   (`GhostyMarkdown` sí se salta); lo que se repite es el trabajo de la burbuja.
3. **8 % `reanclar` (scrollTo)**: cada trozo cambia `textoDelUltimo` → `seguir()` → un
   `scrollTo` inmediato + otro 80 ms después. Cada uno fuerza layout.
4. **~6 % `mensajesVisibles` / `mensajesÚnicos` / `imagenDelTurno`**: el O(n²) es real
   (≈40 ms por segundo) pero no es lo principal.
5. **~3 % la lista de Chats** (`ChatsView.rows`, `ChatPreview`) se recalcula con cada trozo
   aunque no se ve.
6. 2 % `SweepRenderer` (el fade de la respuesta viva). Normal.

**Descartado:** «la respuesta viva se re-parsea a 60 fps». `TextoAlRitmo` se evalúa ~13
veces/s y `piezas()` cuesta < 1 ms/s.

## Al abrir

- Se piden los 56 últimos y **en seguida +35 anteriores**: el centinela «cargar anteriores»
  está arriba de un `VStack` no perezoso, así que «aparece» al instante aunque no hayas subido.
  El hilo pasa a 91 filas y se mide todo dos veces. Eso explica los tirones de 0.2–0.4 s.
- Las 14 tarjetas de video no son el cuello: sus portadas salen del caché y su `body` corre
  pocas veces.

## Qué arreglar (para el plan)

1. Burbujas viejas que no se recalculen: memoizar `offers` / `narrated` / `fuentes` por texto
   (o calcularlos una vez al crear el mensaje), regex como `static let`, y `AgentBubble`
   equatable sin closures nuevas.
2. Un solo re-anclaje por cuadro mientras se sigue el final (y no dos por trozo).
3. `mensajesVisibles` calculado una vez por pasada, con mapa id→índice.
4. Que Chats no dependa del texto vivo del hilo (su vista previa, sólo al cerrar el turno o con
   un throttle).
5. El centinela de «anteriores» sólo al llegar arriba de verdad (por posición del scroll).
6. A medio plazo: reducir el layout (filas fuera de pantalla), el arreglo más grande y el más
   delicado por el historial del scroll.

## Hecho (9-nov, mismo día)

| | Antes | Después |
|---|---|---|
| Cuadros/s mientras llega la respuesta | 6–10 | 57–60 (toda la respuesta) |
| `AgentBubble.body` por trozo | 36 (todas) | 1 (la viva) |
| Mensajes al abrir «VVideos» | 56 → 91 solo | 53; lo anterior al subir |

- 1, 2, 3 y 5 como arriba; 4 con `ChatThread.vistaPrevia`.
- **Extra que apareció al medir:** con las viejas resueltas, la respuesta larga volvía a bajar
  a 20 cuadros/s porque `Markdown(texto)` re-parseaba todos sus bloques en cada cuadro del fade.
  Ahora cada bloque es `BloqueMarkdown` comparable y `Theme.ghosty` se construye una vez.
- Verificado: recorrido de UI 50/53 (3 omitidas, 0 fallos), `GhostyCore` 93 (0 fallos), y
  «cargar anteriores» probado subiendo con el dedo en la conversación real.
- Pendiente: el punto 6. Al subir, el hilo crece sin tope (llegó a 413 filas) y sigue sin
  ser perezoso.
