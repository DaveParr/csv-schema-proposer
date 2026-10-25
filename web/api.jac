"""Server endpoints for the web UI: thin wrappers around `pipeline.run_pipeline`."""

import io;
import pandas as pd;
import from pathlib { Path }
import from pipeline { ProposalResult, run_pipeline }
import from propose { current_model_name }

glob MAX_CSV_BYTES: int = 2_000_000,
     MAX_ROWS: int = 200,
     SAMPLE_PATH: Path = Path(__file__).resolve().parent.parent / "samples" / "people.csv";

def failed(source: str, message: str) -> ProposalResult {
    return ProposalResult(source=source, model_name=current_model_name(), error=message);
}

"""Profile the uploaded CSV text, ask the model, and return every stage's output."""
def:pub propose_csv(csv_text: str, filename: str) -> ProposalResult {
    source = filename or "upload.csv";
    if len(csv_text.encode("utf-8")) > MAX_CSV_BYTES {
        return failed(source, f"File is over {MAX_CSV_BYTES // 1_000_000} MB; upload a smaller sample.");
    }
    try {
        df = pd.read_csv(io.StringIO(csv_text), nrows=MAX_ROWS);
    } except (pd.errors.ParserError, pd.errors.EmptyDataError, UnicodeError, ValueError) as err {
        return failed(source, f"Couldn't read this as CSV: {err}");
    }
    if len(df) == 0 or len(df.columns) == 0 {
        return failed(source, "The CSV has no data rows (a header and at least one row are needed).");
    }
    return run_pipeline(df, source);
}

"""The bundled demo CSV, so the UI can run without an upload."""
def:pub sample_csv -> dict[str, str] {
    return {"filename": SAMPLE_PATH.name, "text": SAMPLE_PATH.read_text()};
}
