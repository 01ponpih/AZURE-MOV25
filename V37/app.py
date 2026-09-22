# -*- coding: ascii -*-
# Novatrix arende backend (V37 Utokad).
# Receives a support ticket from the web form and stores it in Blob Storage
# using the web VM's system-assigned managed identity. No account key is used.
#
# Students change STORAGE_ACCOUNT below to their own globally unique account
# name (the same account the provisioning script created). Nothing else needs
# to change for the base to work.

import json
import uuid
from datetime import datetime, timezone

from flask import Flask, request, Response
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

# --- Settings students may change -------------------------------------------
# Your globally unique storage account name (no https, no .blob..., just name).
STORAGE_ACCOUNT = "stnovatrixXXXX"
# Container that receives the tickets (created by the provisioning script).
CONTAINER = "arenden"
# ----------------------------------------------------------------------------

ACCOUNT_URL = "https://{0}.blob.core.windows.net".format(STORAGE_ACCOUNT)

app = Flask(__name__)

# One credential and one client for the whole app.
# DefaultAzureCredential automatically picks up the VM's system-assigned
# managed identity through IMDS, so there is no secret anywhere in the code.
_credential = DefaultAzureCredential()
_blob_service = BlobServiceClient(account_url=ACCOUNT_URL, credential=_credential)


def _container():
    return _blob_service.get_container_client(CONTAINER)


@app.post("/submit")
def submit():
    # Read the fields from the form. The names here must match index.html.
    name = request.form.get("name", "").strip()
    mail = request.form.get("mail", "").strip()
    msg = request.form.get("msg", "").strip()
    image = request.files.get("bild")

    # A unique id per ticket: UTC timestamp plus a short random suffix.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    ticket_id = "{0}-{1}".format(stamp, uuid.uuid4().hex[:8])

    ticket = {
        "id": ticket_id,
        "name": name,
        "mail": mail,
        "message": msg,
        "created": stamp,
    }

    container = _container()

    # 1) Store the ticket itself as a JSON blob under its own folder.
    container.upload_blob(
        name="{0}/arende.json".format(ticket_id),
        data=json.dumps(ticket, ensure_ascii=False).encode("utf-8"),
        overwrite=True,
        content_settings=ContentSettings(content_type="application/json"),
    )

    # 2) Store the attached image next to it, if the user sent one.
    if image is not None and image.filename:
        container.upload_blob(
            name="{0}/{1}".format(ticket_id, image.filename),
            data=image.stream,
            overwrite=True,
        )

    # A plain confirmation page. ASCII only, so the file survives cloud-init.
    body = (
        "<!DOCTYPE html><html lang='sv'><head><meta charset='UTF-8'>"
        "<title>Tack</title></head>"
        "<body style='font-family:Arial;max-width:640px;margin:40px auto'>"
        "<h1>Tack!</h1>"
        "<p>Ditt arende ar sparat med id <code>{0}</code>.</p>"
        "<p><a href='/'>Skicka in ett till</a></p>"
        "</body></html>"
    ).format(ticket_id)
    return Response(body, mimetype="text/html")


@app.get("/health")
def health():
    # Handy for a quick check that the backend is up and reading its config.
    return {"status": "ok", "account": STORAGE_ACCOUNT, "container": CONTAINER}


if __name__ == "__main__":
    # Bind to localhost only. nginx sits in front and proxies /submit to here.
    app.run(host="127.0.0.1", port=5000)
