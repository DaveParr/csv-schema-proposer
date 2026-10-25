"""Client UI: upload a CSV, then show the model's raw answer and the pandera schema."""

import from api { ProposalResult, propose_csv, sample_csv }
import from propose { ColumnRule }

def show_num(v: float | None) -> str {
    return "—" if v is None else str(v);
}

def pretty_json(text: str) -> str {
    if not text {
        return "(no reply captured)";
    }
    try {
        return JSON.stringify(JSON.parse(text), None, 2);
    } except Exception {
        return text;
    }
}

def schema_filename(source: str) -> str {
    return source.replace(".csv", "") + "_schema.py";
}

def download_text(text: str, filename: str) {
    link: any = document.createElement("a");
    link.href = "data:text/x-python;charset=utf-8," + encodeURIComponent(text);
    link.download = filename;
    link.click();
}

def RulesTable(rules: list[ColumnRule]) -> JsxElement {
    <div className="table-wrap">
        <table className="rules">
            <thead>
                <tr>
                    <th>Column</th>
                    <th>Type</th>
                    <th>Nullable</th>
                    <th>Unique</th>
                    <th>Min</th>
                    <th>Max</th>
                    <th>Allowed values</th>
                    <th>Regex</th>
                </tr>
            </thead>
            <tbody>
                {for (i, r) in enumerate(rules) {
                    <tr key={str(i)}>
                        <td className="mono">{r.name}</td>
                        <td><span className="pill">{str(r.dtype)}</span></td>
                        <td>{"yes" if r.nullable else "no"}</td>
                        <td>{"yes" if r.unique else "no"}</td>
                        <td className="mono">{show_num(r.min_value)}</td>
                        <td className="mono">{show_num(r.max_value)}</td>
                        <td>{", ".join(r.allowed_values) if r.allowed_values else "—"}</td>
                        <td className="mono">{r.regex if r.regex else "—"}</td>
                    </tr>
                }}
            </tbody>
        </table>
    </div>
}

def:pub app -> JsxElement {
    has result: ProposalResult | None = None,
        busy: bool = False,
        status: str = "",
        copied: bool = False;

    async def analyse(text: str, name: str) {
        busy = True;
        result = None;
        copied = False;
        status = "Asking the model about " + name + " (about a minute on CPU)…";
        try {
            result = await propose_csv(text, name);
            status = "";
        } except Exception as err {
            status = "Request failed: " + str(err);
        }
        busy = False;
    }

    async def on_file(e: ChangeEvent) {
        # FileList/File are untyped browser objects.
        files: any = e.target.files;
        if not files or len(files) == 0 {
            return;
        }
        chosen: any = files[0];
        e.target.value = "";
        text: str = await chosen.text();
        name: str = chosen.name;
        await analyse(text, name);
    }

    async def load_sample {
        sample = await sample_csv();
        await analyse(sample["text"], sample["filename"]);
    }

    async def copy_code {
        if result {
            await navigator.clipboard.writeText(result.schema_code);
            copied = True;
        }
    }

    def save_code {
        if result {
            download_text(result.schema_code, schema_filename(result.source));
        }
    }

    <div className="page">
        <header className="header">
            <h1>CSV → pandera schema</h1>
            <p className="muted">
                Upload a CSV. A small local model proposes validation rules, then the
                pipeline fits them to your sample and writes a pandera schema.
            </p>
        </header>

        <section className="card controls">
            <label className={"upload disabled" if busy else "upload"}>
                <input
                    type="file"
                    accept=".csv,text/csv"
                    disabled={busy}
                    onChange={on_file}
                />
                <span>Choose a CSV file…</span>
            </label>
            <button className="secondary" disabled={busy} onClick={load_sample}>
                Use sample data (people.csv)
            </button>
        </section>

        {if status {
            <p className={"status busy" if busy else "status error"}>
                {busy and <span className="spinner"/>}
                {status}
            </p>
        }}

        {if result {
            <div className="results">
                <section className="card summary">
                    <div><span className="label">File</span>{result.source}</div>
                    <div><span className="label">Model</span>{result.model_name}</div>
                    <div><span className="label">Model time</span>{str(result.elapsed_s) + " s"}</div>
                    <div><span className="label">Columns</span>{str(len(result.final_rules))}</div>
                </section>

                {if result.error {
                    <p className="status error">{result.error}</p>
                }}

                {if result.model_reply {
                    <section className="card">
                        <h2>LLM response</h2>
                        <p className="muted">The model's rules, as parsed by byLLM, before the pipeline touches them.</p>
                        <RulesTable rules={result.model_rules}/>
                        <details>
                            <summary>Raw reply text</summary>
                            <pre className="code">{pretty_json(result.model_reply)}</pre>
                        </details>
                    </section>
                }}

                {if result.schema_code {
                    <section className="card">
                        <h2>Adjustments</h2>
                        <p className="muted">What the pipeline changed so the schema is sane and your sample passes it.</p>
                        {if len(result.notes) == 0 {
                            <p>None needed.</p>
                        } else {
                            <ul className="notes">
                                {for (i, note) in enumerate(result.notes) {
                                    <li key={str(i)}>{note}</li>
                                }}
                            </ul>
                        }}
                    </section>
                }}

                {if result.schema_code {
                    <section className="card">
                        <div className="section-head">
                            <h2>Pandera schema</h2>
                            <div className="actions">
                                <button className="secondary" onClick={copy_code}>
                                    {"Copied" if copied else "Copy"}
                                </button>
                                <button onClick={save_code}>
                                    {"Download " + schema_filename(result.source)}
                                </button>
                            </div>
                        </div>
                        <p className="muted">Final rules. The sample validates against this schema.</p>
                        <RulesTable rules={result.final_rules}/>
                        <pre className="code">{result.schema_code}</pre>
                    </section>
                }}

                <section className="card">
                    <details>
                        <summary>What the model was shown</summary>
                        <h3>Column profile</h3>
                        <pre className="code">{result.profile}</pre>
                        <h3>Sample rows</h3>
                        <pre className="code">{result.sample_rows}</pre>
                    </details>
                </section>
            </div>
        }}
    </div>
}
