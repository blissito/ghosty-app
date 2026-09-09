#!/usr/bin/env python3
"""Cliente mínimo de la App Store Connect API.

Firma el JWT ES256 a mano con `cryptography` en vez de traer PyJWT: es una
dependencia menos y son veinte líneas. La llave privada vive en
~/.appstoreconnect/private_keys y NUNCA en el repo.

    ./asc.py builds                      # los builds y su estado de proceso
    ./asc.py groups                      # grupos de prueba
    ./asc.py testers                     # personas invitadas
    ./asc.py asignar <buildId> <grupoId> # manda un build a un grupo
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

else:
    sys.exit(__doc__)
