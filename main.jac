"""csv-schema-proposer: ask a tiny local model to propose a pandera schema for a CSV.

    jac run main.jac data.csv [-o data_schema.py] [--rows 200] [--model ollama/qwen2.5:1.5b]
"""

import argparse;
import sys;
import from pathlib { Path }
import from jaclang.byllm.lib { Model }
import from propose { ColumnRule, DEFAULT_MODEL, set_model }
import from profiling { load_csv }
import from pipeline { run_pipeline }

def build_parser -> argparse.ArgumentParser {
    parser = argparse.ArgumentParser(
        prog="csv-schema-proposer",
        description="Propose a pandera schema for a CSV using a tiny local model.",
    );
    parser.add_argument("csv", help="Path to the sample CSV");
    parser.add_argument(
        "-o", "--output", help="Where to write the schema (default: <csv>_schema.py)"
    );
    parser.add_argument(
        "--rows", type=int, `default=200, help="Rows to read from the CSV (default 200)"
    );
    parser.add_argument(
        "--model", help=f"byLLM model name (default $LLM_MODEL or {DEFAULT_MODEL})"
    );
    return parser;
}

def describe(rule: ColumnRule) -> str {
    bits = [rule.dtype.name, "nullable" if rule.nullable else "required"];
    if rule.unique {
        bits.append("unique");
    }
    if rule.min_value is not None {
        bits.append(f">= {rule.min_value:g}");
    }
    if rule.max_value is not None {
        bits.append(f"<= {rule.max_value:g}");
    }
    if rule.allowed_values is not None {
        bits.append(f"in {rule.allowed_values}");
    }
    if rule.regex is not None {
        bits.append(f"matches {rule.regex!r}");
    }
    return f"  {rule.name}: " + ", ".join(bits);
}

def main(argv: list[str] | None = None) -> int {
    args = build_parser().parse_args(argv);
    csv_path = Path(args.csv);
    if not csv_path.is_file() {
        print(f"error: {csv_path} is not a file", file=sys.stderr);
        return 2;
    }
    out_path = Path(args.output)
        if args.output
        else csv_path.with_name(f"{csv_path.stem}_schema.py");
    if args.model {
        set_model(Model(model_name=args.model));
    }

    df = load_csv(str(csv_path), args.rows);
    print(f"Profiling {len(df)} rows x {len(df.columns)} columns and asking the model...");
    result = run_pipeline(df, csv_path.name);
    print(result.profile);
    if result.error {
        print(f"\nerror: {result.error}", file=sys.stderr);
        if result.error.startswith("Model call failed") {
            print(
                "Is Ollama running with the model pulled?  Try: ollama pull qwen2.5:1.5b",
                file=sys.stderr,
            );
        }
        return 1;
    }

    print(f"\nProposed rules ({result.model_name}, {result.elapsed_s}s):");
    for rule in result.final_rules {
        print(describe(rule));
    }
    if result.notes {
        print("\nAdjusted so the sample passes:");
        for note in result.notes {
            print(f"  - {note}");
        }
    }
    _ = out_path.write_text(result.schema_code);
    print(f"\nWrote {out_path}  (validate a file: python {out_path} data.csv)");
    return 0;
}

with entry:__main__ {
    sys.`exit(main());
}
