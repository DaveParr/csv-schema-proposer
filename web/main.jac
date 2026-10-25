"""web - entry point for the CSV -> pandera schema UI.

Server: the `def:pub` endpoints in `api.jac`. Client: the page in `frontend.jac`.
"""

import from api { propose_csv, sample_csv }

import "./global.css";
import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    <ClientApp/>
}
