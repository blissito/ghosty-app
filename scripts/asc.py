#!/usr/bin/env python3
"""Cliente mínimo de la App Store Connect API.

Firma el JWT ES256 a mano con `cryptography` en vez de traer PyJWT: es una
dependencia menos y son veinte líneas. La llave privada vive en
~/.appstoreconnect/private_keys y NUNCA en el repo.

    ./asc.py builds                      # los builds y su estado de proceso
    ./asc.py groups                      # grupos de prueba
    ./asc.py testers                     # personas invitadas
    ./asc.py asignar <buildId> <grupoId> # manda un build a un grupo
    ./asc.py ficha [0.1] [buildId]       # la ficha de la tienda (metadata/es-MX + cuenta del revisor)
    ./asc.py capturas [carpeta]          # sube las capturas de iPhone 6.9" a la versión en preparación
"""
import base64, json, os, sys, time, urllib.request
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

KEY_ID = os.environ.get("ASC_KEY_ID", "BYJDNZWD5L")
ISSUER = os.environ.get("ASC_ISSUER", "69a6de85-8e77-47e3-e053-5b8c7c11a4d1")
P8 = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
BASE = "https://api.appstoreconnect.apple.com/v1"


def b64(d: bytes) -> str:
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def token() -> str:
    llave = serialization.load_pem_private_key(open(P8, "rb").read(), password=None)
    cabecera = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    cuerpo = {"iss": ISSUER, "iat": int(time.time()),
              "exp": int(time.time()) + 20 * 60, "aud": "appstoreconnect-v1"}
    firmable = f"{b64(json.dumps(cabecera).encode())}.{b64(json.dumps(cuerpo).encode())}"
    der = llave.sign(firmable.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)      # la API quiere r||s, no DER
    return f"{firmable}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def api(ruta, metodo="GET", cuerpo=None):
    req = urllib.request.Request(f"{BASE}{ruta}", method=metodo)
    req.add_header("Authorization", f"Bearer {token()}")
    if cuerpo is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(cuerpo).encode()
    try:
        with urllib.request.urlopen(req) as r:
            texto = r.read().decode()
            return json.loads(texto) if texto else {}
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:600]}", file=sys.stderr)
        sys.exit(1)


def app_id():
    for a in api("/apps?limit=200")["data"]:
        if a["attributes"]["bundleId"] == "com.fixtergeek.ghostyapp":
            return a["id"]
    sys.exit("no encontré la app com.fixtergeek.ghostyapp")


# ── La ficha de App Store (no TestFlight) ────────────────────────────────────────
METADATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "metadata")
LOCALE = "es-MX"
CONTACTO = {
    "contactFirstName": "Hector",
    "contactLastName": "Campos",
    "contactEmail": "rotcehcm@hotmail.com",
    "contactPhone": os.environ.get("ASC_PHONE", ""),
}


def leer(nombre: str) -> str:
    """Un texto de metadata/es-MX/<nombre>.txt. Viven en el repo para poder revisarlos."""
    with open(os.path.join(METADATA, LOCALE, f"{nombre}.txt"), encoding="utf-8") as f:
        return f.read().strip()


def revisor():
    """Usuario y contraseña de la cuenta de demo para App Review. FUERA del repo."""
    ruta = os.path.expanduser("~/.appstoreconnect/revisor.txt")
    try:
        u, c = open(ruta, encoding="utf-8").read().split()
        return u, c
    except (OSError, ValueError):
        sys.exit(f"falta {ruta} con «usuario contraseña» de la cuenta del revisor")


def version_en_preparacion(app):
    """La appStoreVersion que se puede editar, o None. Sólo hay una a la vez."""
    r = api(f"/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=5")["data"]
    for v in r:
        if v["attributes"]["appStoreState"] in (
            "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
            "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_REVIEW",
        ):
            return v
    return None


def localizacion(coleccion, padre_ruta, padre_tipo, padre_id, atributos):
    """PATCH si ya hay localización es-MX en esa colección; POST si no."""
    hay = [l for l in api(f"{padre_ruta}/{padre_id}/{coleccion}")["data"]
           if l["attributes"]["locale"] == LOCALE]
    if hay:
        api(f"/{coleccion}/{hay[0]['id']}", "PATCH",
            {"data": {"type": coleccion, "id": hay[0]["id"], "attributes": atributos}})
        return "actualizada"
    api(f"/{coleccion}", "POST", {"data": {
        "type": coleccion,
        "attributes": {**atributos, "locale": LOCALE},
        "relationships": {padre_tipo: {"data": {"type": padre_tipo + "s", "id": padre_id}}}}})
    return "creada"


cmd = sys.argv[1] if len(sys.argv) > 1 else "builds"

if cmd == "builds":
    for b in api(f"/builds?filter[app]={app_id()}&limit=20&sort=-version")["data"]:
        a = b["attributes"]
        print(f"build {a['version']:>4}  {a.get('processingState'):<12} "
              f"expira {str(a.get('expirationDate'))[:10]}  id={b['id']}")

elif cmd == "groups":
    for g in api(f"/apps/{app_id()}/betaGroups?limit=50")["data"]:
        a = g["attributes"]
        tipo = "interno" if a.get("isInternalGroup") else "externo"
        print(f"{a['name']:<28} {tipo:<9} id={g['id']}")

elif cmd == "testers":
    for t in api("/betaTesters?limit=200")["data"]:
        a = t["attributes"]
        print(f"{(a.get('email') or '—'):<34} {a.get('firstName','')} {a.get('lastName','')} "
              f"· {a.get('state')}")

elif cmd == "asignar":
    build, grupo = sys.argv[2], sys.argv[3]
    api(f"/builds/{build}/relationships/betaGroups", "POST",
        {"data": [{"type": "betaGroups", "id": grupo}]})
    print("asignado")

elif cmd == "crear-grupo":
    nombre = sys.argv[2] if len(sys.argv) > 2 else "Taller"
    r = api("/betaGroups", "POST", {"data": {
        "type": "betaGroups",
        "attributes": {"name": nombre, "isInternalGroup": True,
                       "publicLinkEnabled": False},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id()}}}}})
    print("grupo interno:", r["data"]["id"])

elif cmd == "invitar":
    # Un tester INTERNO tiene que ser un usuario de App Store Connect que ya
    # aceptó su invitación. Si no la aceptó, esto falla y hay que esperar.
    grupo, correo = sys.argv[2], sys.argv[3]
    nombre = sys.argv[4] if len(sys.argv) > 4 else ""
    r = api("/betaTesters", "POST", {"data": {
        "type": "betaTesters",
        "attributes": {"email": correo, "firstName": nombre, "lastName": ""},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": grupo}]}}}})
    print("invitado:", r["data"]["id"])

elif cmd == "usuarios":
    for u in api("/users?limit=100")["data"]:
        a = u["attributes"]
        print(f"{a.get('username',''):<34} {a.get('firstName','')} {a.get('lastName','')} "
              f"· roles {','.join(a.get('roles',[]))} · id={u['id']}")

elif cmd == "invitar-usuario":
    # Un tester INTERNO tiene que ser usuario de App Store Connect. Esto le manda la
    # invitación; hasta que la acepte no se le puede meter al grupo de pruebas.
    correo = sys.argv[2]
    nombre = sys.argv[3] if len(sys.argv) > 3 else "Tester"
    apellido = sys.argv[4] if len(sys.argv) > 4 else "-"
    r = api("/userInvitations", "POST", {"data": {
        "type": "userInvitations",
        "attributes": {"email": correo, "firstName": nombre, "lastName": apellido,
                       "roles": ["DEVELOPER"], "allAppsVisible": False,
                       "provisioningAllowed": False},
        "relationships": {"visibleApps": {"data": [{"type": "apps", "id": app_id()}]}}}})
    print("invitación mandada a", r["data"]["attributes"]["email"])

elif cmd == "invitaciones":
    for i in api("/userInvitations?limit=100")["data"]:
        a = i["attributes"]
        print(f"{a['email']:<34} {a.get('firstName','')} · roles {','.join(a.get('roles',[]))} · PENDIENTE")

elif cmd == "cancelar-invitacion":
    correo = sys.argv[2]
    for i in api("/userInvitations?limit=100")["data"]:
        if i["attributes"]["email"].lower() == correo.lower():
            api(f"/userInvitations/{i['id']}", "DELETE")
            print("cancelada:", correo); break
    else:
        print("no encontré esa invitación")

elif cmd == "preparar-externo":
    # Beta App Review exige dos bloques de metadatos antes de aceptar el envío:
    # la localización (qué es la app y a dónde va la retroalimentación) y los datos
    # de contacto del responsable.
    app = app_id()

    # 1) Localización
    locs = api(f"/apps/{app}/betaAppLocalizations")["data"]
    cuerpo_loc = {
        "description": ("Ghosty es la app para hablar con tu agente de ghosty.studio. "
                        "Le pides cosas por texto o voz, le mandas fotos y archivos, y "
                        "recibes lo que produce (PDF, hojas, imágenes) en la conversación. "
                        "Hace falta una cuenta de ghosty.studio (Apple, Google o correo)."),
        "feedbackEmail": "rotcehcm@hotmail.com",
    }
    if locs:
        api(f"/betaAppLocalizations/{locs[0]['id']}", "PATCH",
            {"data": {"type": "betaAppLocalizations", "id": locs[0]["id"],
                      "attributes": cuerpo_loc}})
        print("localización actualizada")
    else:
        api("/betaAppLocalizations", "POST",
            {"data": {"type": "betaAppLocalizations",
                      "attributes": {**cuerpo_loc, "locale": "es-MX"},
                      "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
        print("localización creada")

    # 2) Datos de contacto y la cuenta de demo del revisor (ver `revisor()`).
    det = api(f"/apps/{app}/betaAppReviewDetail")["data"]
    usuario, clave = revisor()
    cuerpo_det = {
        **CONTACTO,
        "demoAccountRequired": True,
        "demoAccountName": usuario,
        "demoAccountPassword": clave,
        "notes": leer("review_notes"),
    }
    api(f"/betaAppReviewDetails/{det['id']}", "PATCH",
        {"data": {"type": "betaAppReviewDetails", "id": det["id"], "attributes": cuerpo_det}})
    print("datos de contacto listos")

elif cmd == "grupo-externo":
    nombre = sys.argv[2] if len(sys.argv) > 2 else "Beta"
    r = api("/betaGroups", "POST", {"data": {
        "type": "betaGroups",
        "attributes": {"name": nombre, "isInternalGroup": False,
                       "publicLinkEnabled": True, "publicLinkLimitEnabled": False},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id()}}}}})
    a = r["data"]["attributes"]
    print("grupo externo:", r["data"]["id"])
    print("liga pública:", a.get("publicLink") or "(aparece tras la revisión)")

elif cmd == "enviar-revision":
    build = sys.argv[2]
    r = api("/betaAppReviewSubmissions", "POST", {"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
    print("enviado a revisión ·", r["data"]["attributes"].get("betaReviewState"))

elif cmd == "revision":
    for s_ in api(f"/apps/{app_id()}/builds?limit=5&sort=-version")["data"]:
        d = api(f"/builds/{s_['id']}/betaAppReviewSubmission")["data"]
        estado = d["attributes"]["betaReviewState"] if d else "sin enviar"
        print(f"build {s_['attributes']['version']}: {estado}")

elif cmd == "ficha":
    # La ficha de la tienda: versión, textos, URL de privacidad y datos para el revisor.
    # Lo que no cubre (categoría, edad, precio, cuestionario de privacidad, ENVIAR) va a
    # mano en la web: ver metadata/CHECKLIST.md.
    app = app_id()
    version = sys.argv[2] if len(sys.argv) > 2 else "0.1"

    v = version_en_preparacion(app)
    if v is None:
        v = api("/appStoreVersions", "POST", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": version},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
        print("versión creada:", version)
    elif v["attributes"]["versionString"] != version:
        api(f"/appStoreVersions/{v['id']}", "PATCH", {"data": {
            "type": "appStoreVersions", "id": v["id"],
            "attributes": {"versionString": version}}})
        print("versión renombrada a", version)
    else:
        print("versión en preparación:", version, "·", v["attributes"]["appStoreState"])

    # Textos de la versión.
    estado = localizacion("appStoreVersionLocalizations", "/appStoreVersions",
                          "appStoreVersion", v["id"], {
        "description": leer("description"),
        "keywords": leer("keywords"),
        "promotionalText": leer("promotional_text"),
        "supportUrl": leer("support_url"),
        "marketingUrl": leer("support_url"),
    })
    print("textos de la versión:", estado)

    # Nombre, subtítulo y política de privacidad viven en appInfo, no en la versión.
    info = api(f"/apps/{app}/appInfos")["data"][0]
    estado = localizacion("appInfoLocalizations", "/appInfos", "appInfo", info["id"], {
        "name": leer("name"),
        "subtitle": leer("subtitle"),
        "privacyPolicyUrl": leer("privacy_url"),
    })
    print("nombre y privacidad:", estado)

    # Lo que ve el revisor: contacto, cuenta de demo y notas.
    usuario, clave = revisor()
    det = api(f"/appStoreVersions/{v['id']}/appStoreReviewDetail")["data"]
    atributos = {**CONTACTO, "demoAccountRequired": True,
                 "demoAccountName": usuario, "demoAccountPassword": clave,
                 "notes": leer("review_notes")}
    if det:
        api(f"/appStoreReviewDetails/{det['id']}", "PATCH", {"data": {
            "type": "appStoreReviewDetails", "id": det["id"], "attributes": atributos}})
    else:
        api("/appStoreReviewDetails", "POST", {"data": {
            "type": "appStoreReviewDetails", "attributes": atributos,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
    print("datos para el revisor listos (cuenta de demo:", usuario + ")")

    # El build, si se pidió: ./asc.py ficha 0.1 <buildId>
    if len(sys.argv) > 3:
        api(f"/appStoreVersions/{v['id']}/relationships/build", "PATCH",
            {"data": {"type": "builds", "id": sys.argv[3]}})
        print("build atada a la versión:", sys.argv[3])

elif cmd == "capturas":
    # Sube los PNG de una carpeta como capturas de iPhone 6.9" (1320×2868) a la versión
    # en preparación, en orden alfabético. Reemplaza las que hubiera.
    import hashlib
    carpeta = sys.argv[2] if len(sys.argv) > 2 else os.path.join(METADATA, "capturas")
    tipo = os.environ.get("ASC_DISPLAY", "APP_IPHONE_67")
    app = app_id()
    v = version_en_preparacion(app)
    if v is None:
        sys.exit("no hay versión en preparación: corre `ficha` primero")
    loc = [l for l in api(f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
           if l["attributes"]["locale"] == LOCALE]
    if not loc:
        sys.exit("no hay localización es-MX: corre `ficha` primero")
    loc = loc[0]["id"]
    sets = api(f"/appStoreVersionLocalizations/{loc}/appScreenshotSets")["data"]
    conjunto = next((s_ for s_ in sets if s_["attributes"]["screenshotDisplayType"] == tipo), None)
    if conjunto:
        for c in api(f"/appScreenshotSets/{conjunto['id']}/appScreenshots")["data"]:
            api(f"/appScreenshots/{c['id']}", "DELETE")
    else:
        conjunto = api("/appScreenshotSets", "POST", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": tipo},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": loc}}}}})["data"]
    archivos = sorted(f for f in os.listdir(carpeta) if f.lower().endswith(".png"))
    for nombre in archivos:
        datos = open(os.path.join(carpeta, nombre), "rb").read()
        # 1) reservar, 2) subir por partes a donde diga Apple, 3) confirmar con el md5.
        r = api("/appScreenshots", "POST", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": nombre, "fileSize": len(datos)},
            "relationships": {"appScreenshotSet": {
                "data": {"type": "appScreenshotSets", "id": conjunto["id"]}}}}})["data"]
        for op in r["attributes"]["uploadOperations"]:
            trozo = datos[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=trozo, method=op["method"])
            for h in op["requestHeaders"]:
                req.add_header(h["name"], h["value"])
            urllib.request.urlopen(req).read()
        api(f"/appScreenshots/{r['id']}", "PATCH", {"data": {
            "type": "appScreenshots", "id": r["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(datos).hexdigest()}}})
        print("subida:", nombre)
    print(f"{len(archivos)} capturas en {tipo}")

else:
    sys.exit(__doc__)
