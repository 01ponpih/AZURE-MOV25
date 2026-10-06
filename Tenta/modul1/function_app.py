import azure.functions as func
import logging
import requests
import json
import os

app = func.FunctionApp()

@app.blob_trigger(arg_name="myblob", path="felanmalningar/{name}", connection="ARENDE_STORAGE")
def process_anmalan(myblob: func.InputStream):
    logging.info(f"Ny felanmälan: {myblob.name}")
    try:
        content = json.loads(myblob.read().decode('utf-8'))
        webhook_url = os.getenv("POWER_AUTOMATE_WEBHOOK_URL")

        if webhook_url:
            r = requests.post(webhook_url, json=content, timeout=10)
            r.raise_for_status()
            logging.info(f"Power Automate-notis skickad. Status: {r.status_code}")
        else:
            logging.warning("POWER_AUTOMATE_WEBHOOK_URL saknas.")
    except Exception as e:
        logging.error(f"Fel vid behandling av felanmälan: {e}")
        raise