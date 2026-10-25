# csv-schema-proposer

A toy [Jac](https://www.jaseci.org/) CLI. You give it a CSV, a tiny local model (via Ollama) reads a profile of the data, and the tool writes a [pandera](https://pandera.readthedocs.io/) schema that validates files shaped like it.

```
jac run main.jac samples/people.csv
# -> samples/people_schema.py
python samples/people_schema.py some_other.csv
```

## How it works

1. **Profile** (`profiling.jac`): pandas computes per-column stats: a guessed type, null and unique counts, min/max, and example values.
2. **Propose** (`propose.jac`): a `by llm()` method asks the model to fill in typed `ColumnRule` objects (dtype, nullable, unique, bounds, allowed values, regex). The model never writes code. byLLM parses its answer into those objects and retries if the output is malformed.
3. **Render and fit** (`render.jac`): Jac turns the rules into pandera code, `exec`s it, and validates the sample. Any rule the sample itself breaks is relaxed and reported, so the saved schema always passes on its own sample.

## Setup

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5:1.5b
jac install
```

## Usage

```
jac run main.jac data.csv [-o out.py] [--rows 200] [--model ollama/<model>]
```

The default model is `ollama/qwen2.5:1.5b`. To use another model, set `LLM_MODEL` or pass `--model`, e.g. `--model ollama/qwen2.5:3b` if you have the RAM.

## Web UI

```
jac run web        # then open http://localhost:8000
```

Upload a CSV (or click "Use sample data") to see the model's parsed rules, its raw
reply, the adjustments the pipeline made, and the final pandera schema (copy or
download it). `web/api.jac` exposes `propose_csv` and `sample_csv` as endpoints;
both the CLI and the web app call `pipeline.run_pipeline`.

## Tests

`jac test` runs the whole pipeline against a `MockLLM`, so Ollama isn't needed.
