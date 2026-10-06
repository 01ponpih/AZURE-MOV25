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
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024  # 10 MB
logging.basicConfig(level=logging.INFO)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="sv">
<head>
    <meta charset="UTF-8">
    <title>Nordvik Fastigheter - Felanmälan</title>
    <style>
        body { font-family: sans-serif; background-color: #f0f2f5; margin: 0; padding: 20px; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .container { background: #ffffff; padding: 40px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 100%; max-width: 500px; box-sizing: border-box; }
        h1 { text-align: center; color: #1a3d5c; margin-top: 0; }
        p { text-align: center; color: #555; margin-bottom: 25px; }
        label { display: block; margin-top: 15px; font-weight: bold; color: #333; }
        input, textarea, select { width: 100%; padding: 10px; margin-top: 5px; box-sizing: border-box; border: 1px solid #ccc; border-radius: 5px; font-size: 1rem; }
        button { margin-top: 25px; width: 100%; padding: 12px 20px; background-color: #1a3d5c; color: white; border: none; border-radius: 5px; font-size: 1.1rem; cursor: pointer; transition: 0.2s; }
        button:hover { background-color: #12293d; }
        button:disabled { background-color: #8ba3b8; cursor: wait; }
        .error { color: #d13438; margin-top: 15px; font-weight: bold; text-align: center; }
        .jour-info { display: none; background: #fff4e5; border-left: 4px solid #ff8c00; padding: 12px 15px; margin-top: 15px; border-radius: 5px; font-size: 0.95rem; line-height: 1.5; }
        .jour-info strong { color: #b85c00; }
        .jour-info a { color: #1a3d5c; font-weight: bold; text-decoration: underline; }
        .success-box { background: #ffffff; padding: 40px; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.1); text-align: center; max-width: 500px; width: 100%; box-sizing: border-box; }
        .success-box h1 { color: #107c10; font-size: 2.5rem; margin-top: 0; margin-bottom: 10px; }
        .ref-box { background: #f3f2f1; padding: 15px; border-radius: 6px; font-family: monospace; font-size: 1.1rem; color: #000; word-break: break-all; margin-top: 15px; }
    </style>
</head>
<body>
    {% if success_id %}
    <div class="success-box">
        <h1>Tack!</h1>
        <p>Din felanmälan har sparats och behandlas under dagen.</p>
        <div class="ref-box">
            <strong>Referensnummer:</strong><br>{{ success_id }}
        </div>
    </div>
    {% else %}
    <div class="container">
        <h1>Nordvik Fastigheter</h1>
        <p>Felanmälan</p>
        {% if error_msg %}<p class="error">{{ error_msg }}</p>{% endif %}
        <form method="POST" enctype="multipart/form-data" id="felanmalan-form">
            <label for="titel">Rubrik</label>
            <input type="text" id="titel" name="titel" required>

            <label for="namn">Namn</label>
            <input type="text" id="namn" name="namn" required>

            <label for="epost">E-post</label>
            <input type="email" id="epost" name="epost" required>

            <label for="kategori">Kategori</label>
            <select id="kategori" name="kategori" required>
                <option value="">Välj kategori</option>
                <option value="Värme">Värme</option>
                <option value="Vatten">Vatten</option>
                <option value="Lås">Lås</option>
                <option value="El">El</option>
                <option value="Övrigt">Övrigt</option>
            </select>

            <div id="jour-info" class="jour-info">
                <strong>Akut?</strong> Ring jouren direkt på
                <a href="tel:Nordviks Journummer">Nordviks Journummer</a> för snabbast hantering.
                Använd formuläret som komplement.
            </div>

            <label for="fastighet">Fastighet / Lägenhet</label>
            <input type="text" id="fastighet" name="fastighet" required>

            <label for="beskrivning">Beskrivning</label>
            <textarea id="beskrivning" name="beskrivning" rows="5" required></textarea>

            <label for="bild">Bild på felet (om möjligt)</label>
            <input type="file" id="bild" name="bild" accept="image/*">

            <button type="submit" id="submit-btn">Skicka felanmälan</button>
        </form>
    </div>
    {% endif %}

    <script>
    document.addEventListener('DOMContentLoaded', function () {
        const form = document.getElementById('felanmalan-form');
        if (!form) return;

        const kategoriSelect = document.getElementById('kategori');
        const jourInfo = document.getElementById('jour-info');
        const akutaKategorier = ['Värme', 'Vatten', 'Lås'];

        kategoriSelect.addEventListener('change', function () {
            jourInfo.style.display = akutaKategorier.includes(this.value) ? 'block' : 'none';
        });

        form.addEventListener('submit', async function (e) {
            const fileInput = document.getElementById('bild');
            const file = fileInput.files[0];

            if (!file || file.size < 3 * 1024 * 1024) return;

            e.preventDefault();
            const submitBtn = document.getElementById('submit-btn');
            submitBtn.disabled = true;
            submitBtn.textContent = 'Komprimerar bild...';

            try {
                const compressed = await komprimeraBild(file);
                const dataTransfer = new DataTransfer();
                dataTransfer.items.add(compressed);
                fileInput.files = dataTransfer.files;
            } catch (err) {
                console.error('Kunde inte komprimera bilden:', err);
            }

            form.submit();
        });
    });

    function komprimeraBild(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onerror = reject;
            reader.onload = function (ev) {
                const img = new Image();
                img.onerror = reject;
                img.onload = function () {
                    const MAX_DIM = 2000;
                    let width = img.width;
                    let height = img.height;

                    if (width > MAX_DIM || height > MAX_DIM) {
                        if (width > height) {
                            height = Math.round(height * MAX_DIM / width);
                            width = MAX_DIM;
                        } else {
                            width = Math.round(width * MAX_DIM / height);
                            height = MAX_DIM;
                        }
                    }

                    const canvas = document.createElement('canvas');
                    canvas.width = width;
                    canvas.height = height;
                    canvas.getContext('2d').drawImage(img, 0, 0, width, height);

                    canvas.toBlob(
                        function (blob) {
                            if (!blob) return reject(new Error('toBlob returnerade null'));
                            const nyttNamn = file.name.replace(/\.[^.]+$/, '') + '.jpg';
                            resolve(new File([blob], nyttNamn, { type: 'image/jpeg' }));
                        },
                        'image/jpeg',
                        0.75
                    );
                };
                img.src = ev.target.result;
            };
            reader.readAsDataURL(file);
        });
    }
    </script>
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
        titel = request.form.get("titel")
        namn = request.form.get("namn")
        epost = request.form.get("epost")
        kategori = request.form.get("kategori")
        fastighet = request.form.get("fastighet")
        beskrivning = request.form.get("beskrivning")

        has_attachment = False
        attachment_name = ""
        attachment_base64 = ""

        fil = request.files.get("bild")
        if fil and fil.filename != "":
            has_attachment = True
            attachment_name = fil.filename
            file_bytes = fil.read()
            attachment_base64 = base64.b64encode(file_bytes).decode('utf-8')

        payload = {
            "id": arende_id,
            "titel": titel,
            "namn": namn,
            "epost": epost,
            "kategori": kategori,
            "fastighet": fastighet,
            "beskrivning": beskrivning,
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

                blob_client = blob_service_client.get_blob_client(
                    container="felanmalningar",
                    blob=f"anmalan-{arende_id}.json"
                )
                blob_client.upload_blob(json.dumps(payload), overwrite=True)

                return render_template_string(HTML_TEMPLATE, success_id=arende_id)
            else:
                return render_template_string(HTML_TEMPLATE, error_msg="Systemfel: Lagrings-URL saknas.")
        except Exception as e:
            app.logger.error(f"Kunde inte spara felanmälan: {e}")
            return render_template_string(HTML_TEMPLATE, error_msg="Ett fel uppstod när felanmälan skulle sparas. Försök igen.")

    return render_template_string(HTML_TEMPLATE)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)