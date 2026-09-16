# Enviar la app a App Review — lo que se hace a mano

Lo automatizado (`scripts/asc.py ficha 0.1 [buildId]` y `scripts/asc.py capturas`) deja
versión, textos, URL de privacidad, capturas y datos del revisor. Lo de abajo son clics en
https://appstoreconnect.apple.com/apps/6810017404 y los hace bliss:

1. **App Information → Category**: Productividad (secundaria: Utilidades).
2. **App Information → Age Rating**: contestar el cuestionario todo en «No» → 4+.
3. **Pricing and Availability**: Gratis, todos los países (o sólo México/LatAm/España).
4. **App Privacy** (cuestionario): igual que `GhostyApp/PrivacyInfo.xcprivacy`:
   - Recopila datos: Sí.
   - Email → vinculado a la identidad, no para tracking, uso: funcionalidad de la app.
   - Contenido de usuario (mensajes, fotos, audio, otros) → vinculado, no tracking, funcionalidad.
   - Tracking: No.
5. **Versión 0.1 → Build**: elegir la última VALID (o pasar el id a `asc.py ficha 0.1 <buildId>`).
6. **App Review Information**: comprobar que aparece la cuenta de demo
   (`~/.appstoreconnect/revisor.txt`) y el teléfono de contacto.
7. **Version Release**: «Manually release» para decidir cuándo sale.
8. **Add for Review → Submit**.

Antes de enviar, entrar UNA vez con la cuenta del revisor desde un teléfono y pedir el PDF
de las notas: el agente y su caja tienen que estar despiertos.
