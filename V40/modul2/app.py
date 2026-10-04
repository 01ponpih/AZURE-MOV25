import os
import json
import uuid
import datetime
import logging
import base64
from flask import Flask, request, render_template_string
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="sv">
<head>
    <meta charset="UTF-8">
    <title>Novatrix AB - Support</title>
    <style>
        body { font-family: sans-serif; background-color: #f0f2f5; margin: 0; padding: 20px; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .container { background: #ffffff; padding: 40px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 100%; max-width: 500px; box-sizing: border-box; }
        h1 { text-align: center; color: #333; margin-top: 0; }
        p { text-align: center; color: #555; margin-bottom: 25px; }
        label { display: block; margin-top: 15px; font-weight: bold; color: #333; }
        input, textarea { width: 100%; padding: 10px; margin-top: 5px; box-sizing: border-box; border: 1px solid #ccc; border-radius: 5px; font-size: 1rem; }
        button { margin-top: 25px; width: 100%; padding: 12px 20px; background-color: #0078d4; color: white; border: none; border-radius: 5px; font-size: 1.1rem; cursor: pointer; transition: 0.2s; }
        button:hover { background-color: #005a9e; }
        .error { color: #d13438; margin-top: 15px; font-weight: bold; text-align: center; }
        .success-box { background: #ffffff; padding: 40px; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.1); text-align: center; max-width: 500px; width: 100%; box-sizing: border-box; }
        .success-box h1 { color: #107c10; font-size: 2.5rem; margin-top: 0; margin-bottom: 10px; }
        .ref-box { background: #f3f2f1; padding: 15px; border-radius: 6px; font-family: monospace; font-size: 1.1rem; color: #000; word-break: break-all; margin-top: 15px; }
    </style>
</head>
<body>
    {% if success_id %}
    <div class="success-box">
        <h1>Tack!</h1>
        <p>Ditt ärende har sparats och behandlas nu.</p>
        <div class="ref-box">
            <strong>Referensnummer:</strong><br>{{ success_id }}
        </div>
    </div>
    {% else %}
    <div class="container">
        <h1>Novatrix AB</h1>
        <p>Hej! Fyll i uppgifterna nedan, vi svarar inom 24h.</p>
        {% if error_msg %}<p class="error">{{ error_msg }}</p>{% endif %}
        <form method="POST" enctype="multipart/form-data">
            <label for="namn">Namn</label>
            <input type="text" id="namn" name="namn" required>
            
            <label for="epost">E-post</label>
            <input type="email" id="epost" name="epost" required>
            
            <label for="meddelande">Meddelande</label>
            <textarea id="meddelande" name="meddelande" rows="5" required></textarea>
            
            <label for="bilaga">Bifoga fil (om du vill)</label>
            <input type="file" id="bilaga" name="bilaga">
            
            <button type="submit">Skicka</button>
        </form>
    </div>
    {% endif %}
</body>
</html>
"""

@app.route("/health", methods=["GET"])
def health():
    return "OK", 200

@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST":
        arende_id = str(uuid.uuid4())
        namn = request.form.get("namn")
        epost = request.form.get("epost")
        meddelande = request.form.get("meddelande")

        has_attachment = False
        attachment_name = ""
        attachment_base64 = ""

        fil = request.files.get("bilaga")
        if fil and fil.filename != "":
            has_attachment = True
            attachment_name = fil.filename
            file_bytes = fil.read()
            attachment_base64 = base64.b64encode(file_bytes).decode('utf-8')

        payload = {
            "id": arende_id,
            "name": namn,
            "mail": epost,
            "message": meddelande,
            "created": datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
            "has_attachment": has_attachment,
            "attachment_name": attachment_name,
            "attachment_content_base64": attachment_base64
        }

        blob_url = os.getenv("AZURE_STORAGE_BLOB_URL")

        try:
            if blob_url:
                credential = DefaultAzureCredential()
                blob_service_client = BlobServiceClient(account_url=blob_url, credential=credential)
                
                blob_client = blob_service_client.get_blob_client(container="arenden", blob=f"arende-{arende_id}.json")
                blob_client.upload_blob(json.dumps(payload, ensure_ascii=False), overwrite=True)
                
                return render_template_string(HTML_TEMPLATE, success_id=arende_id)
            else:
                return render_template_string(HTML_TEMPLATE, error_msg="Systemfel: Lagrings-URL saknas.")
        except Exception as e:
            app.logger.error(f"Kunde inte spara ärende: {e}")
            return render_template_string(HTML_TEMPLATE, error_msg="Ett fel uppstod när ärendet skulle sparas. Försök igen.")

    return render_template_string(HTML_TEMPLATE)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)