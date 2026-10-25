"""Stability eval: run the model on the same CSV N times and classify how answers vary.

    jac run evals/stability.jac [--runs 5] [--csv samples/people.csv]

Variation is reported at three levels, from trivial to material:
  - formatting: raw reply text differs, parsed JSON is identical
  - cosmetic:   JSON differs but the rules are equivalent (column/list order,
                1 vs 1.0, regexes that accept/reject the same probe strings)
  - material:   a rule differs in a way that changes what validates
Each level is checked on the model's raw proposal and on the final schema after
`reconcile` + `fit_to_sample`, so you can see what the pipeline absorbs. Each
final schema also validates single-defect probe files; different catches
across runs are material by definition.
"""

import argparse;
import hashlib;
import json;
import re;
import sys;
import time;
import from collections { Counter }
import from datetime { datetime }
import from pathlib { Path }
import pandas as pd;
import pandera.pandas as pa;
import from jaclang.byllm.lib { register_llm_call_hook }
import from propose { ColumnRule, CsvSample }
import from profiling { TableProfile, load_csv, profile_df }
import from render { reconcile, fit_to_sample, load_schema }

glob replies: list[str] = [];

def capture(rec: dict[str, any]) {
    reply = rec.get("reply") or {};
    replies.append(str(reply.get("content") or ""));
}

def canon_num(v: float | None) -> float | None {
    return None if v is None else round(float(v), 6);
}

def canon_rule(r: ColumnRule) -> dict[str, any] {
    return {
        "dtype": r.dtype.name,
        "nullable": r.nullable,
        "unique": r.unique,
        "min_value": canon_num(r.min_value),
        "max_value": canon_num(r.max_value),
        # [] and null both mean "no category check" to the pipeline.
        "allowed_values": sorted({str(v) for v in r.allowed_values})
            if r.allowed_values
            else None,
        "regex": r.regex,
    };
}

def canon_rules(rules: list[ColumnRule]) -> dict[str, dict[str, any]] {
    return {r.name: canon_rule(r) for r in rules};
}

def digest(value: any) -> str {
    return hashlib.sha1(json.dumps(value, sort_keys=True).encode()).hexdigest()[:8];
}

"""Single-defect copies of the sample: (label, column, frame)."""
def make_probes(df: pd.DataFrame) -> list[tuple[str, str, pd.DataFrame]] {
    edits: list[tuple[str, str, any]] = [
        ("negative age", "age", -5),
        ("age 150", "age", 150),
        ("bad email", "email", "not-an-email"),
        ("unknown plan", "plan", "platinum"),
        ("bad date", "signup_date", "not-a-date"),
        ("non-bool active", "is_active", "maybe"),
        ("zero height", "height_m", 0.0),
        ("missing name", "name", None),
        ("missing signup", "signup_date", None),
    ];
    probes: list[tuple[str, str, pd.DataFrame]] = [];
    for (label, col, value) in edits {
        if col in df.columns {
            bad = df.copy().astype({col: "object"});
            bad.loc[0, col] = value;
            probes.append((label, col, bad));
        }
    }
    dup = pd.concat([df, df.iloc[[0]]], ignore_index=True);
    probes.append(("duplicate row", "*", dup));
    return probes;
}

def caught(schema: any, frame: pd.DataFrame) -> bool {
    try {
        _ = schema.validate(frame.copy(), lazy=True);
        return False;
    } except (pa.errors.SchemaErrors, pa.errors.SchemaError, ValueError, TypeError) {
        return True;
    }
}

"""Regex probe strings: the column's sample values plus a few junk strings."""
def regex_probes(table: TableProfile, col: str) -> list[str] {
    values = [str(v) for v in table.df[col].dropna().tolist()];
    return values + ["", "x", "not-an-email", "a@b", "123", "ab cd", "@@"];
}

def regex_signature(rx: str | None, strings: list[str]) -> str {
    if rx is None {
        return "none";
    }
    try {
        pat = re.compile(rx);
    } except re.error {
        return "invalid";
    }
    return "".join(["1" if pat.fullmatch(s) else "0" for s in strings]);
}

"""Rules with regexes replaced by their behaviour on probe strings."""
def behavioural(rules: dict[str, dict[str, any]], table: TableProfile) -> dict[str, any] {
    out: dict[str, any] = {};
    for (col, rule) in rules.items() {
        r = dict(rule);
        if col in table.df.columns {
            r["regex"] = regex_signature(rule["regex"], regex_probes(table, col));
        }
        out[col] = r;
    }
    return out;
}

def parsed_json(text: str) -> any {
    try {
        return json.loads(text);
    } except ValueError {
        return None;
    }
}

def run_once(table: TableProfile, source: str, probes: list[tuple[str, str, pd.DataFrame]]) -> dict[str, any] {
    replies.clear();
    started = time.monotonic();
    sample = CsvSample(column_profile=table.to_prompt(), sample_rows=table.sample_rows());
    proposal = sample.propose_schema();
    elapsed = round(time.monotonic() - started, 1);
    raw_order = [r.name for r in proposal.columns];
    raw = canon_rules(proposal.columns);   # snapshot: reconcile/fit mutate rules
    notes: list[str] = [];
    fresh = profile_df(table.df);
    rules = reconcile(proposal, fresh, notes);
    code = fit_to_sample(rules, fresh, source, notes);
    schema = load_schema(code);
    return {
        "elapsed_s": elapsed,
        "attempts": len(replies),
        "replies": list(replies),
        "raw_order": raw_order,
        "raw_rules": raw,
        "final_rules": canon_rules(rules),
        "notes": notes,
        "code_hash": digest(code),
        "caught": [label for (label, _col, frame) in probes if caught(schema, frame)],
    };
}

"""For each column/field, the distinct values across runs (only fields that vary)."""
def field_variants(rule_sets: list[dict[str, dict[str, any]]]) -> dict[str, dict[str, Counter]] {
    out: dict[str, dict[str, Counter]] = {};
    cols: list[str] = [];
    for rs in rule_sets {
        for c in rs {
            if c not in cols {
                cols.append(c);
            }
        }
    }
    for col in cols {
        fields = ["present", "dtype", "nullable", "unique", "min_value", "max_value", "allowed_values", "regex"];
        for f in fields {
            counts: Counter = Counter();
            for rs in rule_sets {
                val = (col in rs) if f == "present" else rs.get(col, {}).get(f, "<absent>");
                counts[json.dumps(val)] += 1;
            }
            if len(counts) > 1 {
                out.setdefault(col, {})[f] = counts;
            }
        }
    }
    return out;
}

def show_variants(title: str, variants: dict[str, dict[str, Counter]]) {
    if not variants {
        print(f"  {title}: none");
        return;
    }
    print(f"  {title}:");
    for (col, fields) in variants.items() {
        for (f, counts) in fields.items() {
            spread = ", ".join([f"{v} x{n}" for (v, n) in counts.most_common()]);
            print(f"    {col}.{f}: {spread}");
        }
    }
}

def level_report(label: str, runs: list[dict[str, any]], key: str, table: TableProfile) {
    rule_sets: list[dict[str, dict[str, any]]] = [r[key] for r in runs];
    n_canon = len({digest(rs) for rs in rule_sets});
    n_behave = len({digest(behavioural(rs, table)) for rs in rule_sets});
    print(f"\n[{label}]");
    print(f"  distinct rule sets: {n_canon}  (by behaviour, regexes probed: {n_behave})");
    # Regex text that differs but behaves the same is cosmetic nuance.
    variants = field_variants(rule_sets);
    behave_variants = field_variants([behavioural(rs, table) for rs in rule_sets]);
    cosmetic: dict[str, dict[str, Counter]] = {};
    for (col, fields) in variants.items() {
        if "regex" in fields and "regex" not in behave_variants.get(col, {}) {
            cosmetic.setdefault(col, {})["regex"] = fields["regex"];
            del fields["regex"];
        }
    }
    material = {c: f for (c, f) in variants.items() if f};
    show_variants("MATERIAL variation", material);
    show_variants("cosmetic regex wording (same behaviour)", cosmetic);
}

def main(argv: list[str] | None = None) -> int {
    parser = argparse.ArgumentParser(prog="stability");
    parser.add_argument("--runs", type=int, `default=5);
    parser.add_argument("--csv", `default="samples/people.csv");
    args = parser.parse_args(argv);

    register_llm_call_hook(capture);
    table = profile_df(load_csv(args.csv, 200));
    probes = make_probes(table.df);
    source = Path(args.csv).name;
    runs: list[dict[str, any]] = [];
    for i in range(args.runs) {
        try {
            result = run_once(table, source, probes);
        } except Exception as err {
            result = {"error": f"{type(err).__name__}: {err}", "replies": list(replies)};
        }
        result["run"] = i + 1;
        runs.append(result);
        status = result.get("error") or f"{result['elapsed_s']}s, {result['attempts']} call(s), schema {result['code_hash']}";
        print(f"run {i + 1}/{args.runs}: {status}", flush=True);
    }

    out_dir = Path("evals/runs");
    out_dir.mkdir(parents=True, exist_ok=True);
    out = out_dir / f"stability-{datetime.now().strftime('%Y%m%d-%H%M%S')}.jsonl";
    _ = out.write_text("\n".join([json.dumps(r, `default=str) for r in runs]) + "\n");

    ok = [r for r in runs if "error" not in r];
    print(f"\n=== {len(ok)}/{len(runs)} runs succeeded; raw log: {out}");
    if len(ok) < 2 {
        return 1;
    }

    # Trivial levels, judged on the final reply of each run.
    texts = [r["replies"][-1] for r in ok];
    parsed = [parsed_json(t) for t in texts];
    print("\n[reply text]");
    print(f"  distinct raw texts: {len(set(texts))}");
    print(f"  distinct parsed JSON: {len({json.dumps(p, sort_keys=True) for p in parsed})}");
    print(f"  distinct column orders: {len({tuple(r['raw_order']) for r in ok})}");
    print(f"  calls per run (1 = no retry): {Counter([r['attempts'] for r in ok])}");
    print(f"  reply lengths (chars): {sorted([len(t) for t in texts])}");

    level_report("model proposal, before pipeline", ok, "raw_rules", table);
    level_report("final schema, after pipeline", ok, "final_rules", table);

    print("\n[probe catches per run]  (differences here are material)");
    labels = [label for (label, _c, _f) in probes];
    for label in labels {
        hits = sum([1 for r in ok if label in r["caught"]]);
        marker = "" if hits in [0, len(ok)] else "   <-- varies";
        print(f"  {label:18} caught {hits}/{len(ok)}{marker}");
    }
    print(f"\n  distinct final schema files: {len({r['code_hash'] for r in ok})}");
    return 0;
}

with entry:__main__ {
    sys.`exit(main());
}
